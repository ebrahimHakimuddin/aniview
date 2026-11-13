import 'dart:convert';

import 'package:aniview/exo.dart';
import 'package:aniview/platform.dart';
import 'package:aniview/player.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/tv.dart';
import 'package:aniview/ui.dart';
import 'package:aniview/upscale.dart';
import 'package:aniview/upscaler.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Android's two players as fakes: Media3 ([VideoBackend.exoPlayer], no shaders) or mpv, which with [fails] can't
/// open the video (an error and no duration, as mpv reports it) and then falls back to [next]. With [startFails] it
/// can't even start (libmpv failing to load), and then can't be disposed either.
class _Backend extends PlayerBackend {
  _Backend(this.kind, {this.fails = false, this.startFails = false, this.next});

  @override
  final VideoBackend kind;
  final bool fails, startFails;
  final _Backend? next;
  late void Function(Map) emit;
  final calls = <String>[];
  final opened = <Map<String, Object?>>[];
  final sent = <List<String>>[];
  bool started = false, disposed = false;

  @override
  PlayerBackend Function()? get fallback => next == null ? null : () => next!;

  @override
  bool get supportsShaders => kind == VideoBackend.mediaKit;

  @override
  Future<void> start(void Function(Map) on) async {
    if (startFails) throw StateError('libmpv failed to load');
    started = true;
    emit = on;
  }

  @override
  Future<void> call(String method, Map<String, Object?> args) async {
    calls.add(method);
    if (method == 'shaders') sent.add((args['paths']! as List).cast());
    if (method != 'open') return;
    opened.add(args);
    if (fails) return emit({'error': 'Failed to open the video'});
    emit({
      'position': args['start'],
      'buffer': 0,
      'duration': 1440000,
      'playing': true,
      'buffering': false,
      'width': 1280,
      'height': 720,
    });
  }

  @override
  Future<void> setVolume(double level) async {}

  @override
  Future<void> dispose() async {
    disposed = true;
    if (startFails) throw StateError('never started');
  }
}

class _Source extends Source {
  _Source() : super('Fixture', 'https://fixture.test');
  @override
  Future<String?> match(Map media) async => 'fixture';
  @override
  Future<List<Episode>> episodesOf(String id) async => [Episode(1, ref: '1')];
  @override
  Future<List<SearchResult>> search(String query) async => [];
  @override
  Future<List<VideoStream>> streams(
    Map media,
    Episode episode, {
    required bool dub,
  }) async => [VideoStream('Fixture', 'https://live.test/video.mp4', {})];
}

const _media = {
  'id': 5050506,
  'title': {'romaji': 'Fixture'},
};

/// A sheet opening or closing: the player always has something moving, so it never settles.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// Taps the sheet's option [label], scrolled into view first: a landscape phone's sheet is short.
Future<void> _pickOption(WidgetTester tester, String label) async {
  final option = find.text(label).last;
  await tester.ensureVisible(option);
  await tester.pump();
  await tester.tap(option);
}

/// The files a chain installs to, by name.
List<String> _paths(List<String> chain) => [
  for (final name in chain) '/support/shaders/$name',
];

void main() {
  late List<String> qualityChecks;
  setUp(() {
    final os = playbackOs, tv = isTv, deviceTv = deviceIsTv;
    playbackOs = 'android';
    addTearDown(() {
      playbackOs = os;
      isTv = tv;
      deviceIsTv = deviceTv;
    });
    final install = installUpscaleShaders;
    installUpscaleShaders = (chain) async => _paths(chain);
    addTearDown(() => installUpscaleShaders = install);
    qualityChecks = [];
    final quality = configureQuality;
    configureQuality = (url, _) async {
      qualityChecks.add(url);
      return const [];
    };
    addTearDown(() => configureQuality = quality);
  });

  /// Opens the player on a 1080p phone in landscape (or a TV), upscaling saved as [saved]; with [resume], episode 1
  /// resumes at 5:00.
  ///
  /// Only a file's first test may resume: the history's writes are chained through one static future, and a player
  /// closed in an earlier test leaves that chain in the earlier test's fake-async zone, where nothing completes it.
  Future<void> open(
    WidgetTester tester, {
    PlayerBackend? backend,
    Upscale saved = Upscale.off,
    bool tv = false,
    bool resume = false,
  }) async {
    SharedPreferences.setMockInitialValues({
      'resume': resume,
      'upscale': saved.name,
      'watch_history': jsonEncode([
        {
          'media': _media,
          'source': 'Fixture',
          'episode': 1,
          'position': 300000,
          'duration': 1440000,
          'dub': false,
          'at': 0,
        },
      ]),
    });
    await Settings.load();
    isTv = deviceIsTv = tv;
    tester.view.physicalSize = const Size(2400, 1080);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: PlayerScreen(
          media: _media,
          source: _Source(),
          episodes: [Episode(1, ref: '1')],
          index: 0,
          dub: false,
          backend: backend,
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  }

  final upscaleButton = find.widgetWithIcon(
    TextButton,
    Icons.auto_awesome_outlined,
  );

  /// The labels of the Upscaling picker's options: a sheet on a phone, a panel on TV.
  List<String> options(WidgetTester tester) => [
    for (final tile in tester.widgetList<ListTile>(find.byType(ListTile)))
      if (tile.title case Text(:final data?)) data,
  ];

  testWidgets(
    'mpv that can\'t open the video falls back to Media3 where it was, and says so',
    (tester) async {
      final media3 = _Backend(VideoBackend.exoPlayer);
      final mpv = _Backend(VideoBackend.mediaKit, fails: true, next: media3);
      // The first test: it resumes (see open).
      await open(tester, backend: mpv, saved: Upscale.quality, resume: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.text("Upscaling isn't available for this video"),
        findsOneWidget,
      );
      expect(mpv.opened.single['start'], 300000);
      expect(mpv.disposed, isTrue);
      expect(media3.started, isTrue);
      // The same episode, from the same place, on Media3.
      expect(media3.opened, hasLength(1));
      expect(media3.opened.single['url'], mpv.opened.single['url']);
      expect(media3.opened.single['start'], 300000);
      expect(media3.calls, isNot(contains('shaders')));
      // No error shown, and no other server tried: the video plays.
      expect(find.textContaining('failed'), findsNothing);
      // The setting stays; this player is Media3 from here on.
      expect(Settings.upscale, Upscale.quality);
      await tester.pump(const Duration(seconds: 2));
      expect(upscaleButton, findsOneWidget);
      await close(tester);
    },
  );

  testWidgets('mpv that can\'t start plays on Media3, and says so', (
    tester,
  ) async {
    final media3 = _Backend(VideoBackend.exoPlayer);
    final mpv = _Backend(VideoBackend.mediaKit, startFails: true, next: media3);
    await open(tester, backend: mpv, saved: Upscale.quality);
    expect(
      find.text("Upscaling isn't available for this video"),
      findsOneWidget,
    );
    expect(mpv.disposed, isTrue);
    expect(media3.started, isTrue);
    expect(media3.opened.single['url'], 'https://live.test/video.mp4');
    expect(media3.calls, isNot(contains('shaders')));
    expect(find.textContaining('failed'), findsNothing);
    await close(tester);
    expect(media3.disposed, isTrue);
  });

  testWidgets('with upscaling off, Android plays through Media3 as before', (
    tester,
  ) async {
    // The real Media3 backend over its channel, recording what the player sends.
    final exo = <MethodCall>[];
    final mpvSession = <MethodCall>[];
    MockStreamHandlerEventSink? events;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('aniview/exo'), (
      call,
    ) async {
      exo.add(call);
      if (call.method == 'create') return {'id': 7, 'texture': 7};
      if (call.method == 'open') {
        events?.success({
          'position': 300000,
          'buffer': 0,
          'duration': 1440000,
          'playing': true,
          'buffering': false,
          'width': 1920,
          'height': 1080,
        });
      }
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('aniview/mpv'), (
      call,
    ) async {
      mpvSession.add(call);
      return null;
    });
    messenger.setMockStreamHandler(
      const EventChannel('aniview/exo/7'),
      MockStreamHandler.inline(
        onListen: (_, sink) {
          events = sink;
        },
      ),
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(
        const MethodChannel('aniview/exo'),
        null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('aniview/mpv'),
        null,
      );
      messenger.setMockStreamHandler(const EventChannel('aniview/exo/7'), null);
    });

    await open(tester);
    expect(exo.map((c) => c.method).take(4), [
      'create',
      'quality',
      'stop',
      'open',
    ]);
    final opened = exo.firstWhere((c) => c.method == 'open').arguments as Map;
    expect(opened['url'], 'https://live.test/video.mp4');
    expect(opened['start'], 0);
    expect(opened['hls'], isFalse);
    expect(exo.map((c) => c.method), isNot(contains('shaders')));
    // Media3 picks its own variants: the relay isn't narrowed for mpv.
    expect(qualityChecks, isEmpty);
    expect(mpvSession, isEmpty);
    // The picture is Media3's texture, not media_kit's.
    expect(find.byType(Texture), findsOneWidget);

    // Media3 stops on an error mid-episode: reloaded there, as before.
    exo.clear();
    events?.success({'error': 'Source error'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Playback failed · reloading'), findsOneWidget);
    expect(exo.map((c) => c.method), contains('open'));
    await close(tester);
  });

  testWidgets('a phone offers upscaling for the next video while on Media3', (
    tester,
  ) async {
    final media3 = _Backend(VideoBackend.exoPlayer);
    await open(tester, backend: media3);
    expect(upscaleButton, findsOneWidget);
    await tester.tap(upscaleButton);
    await _settle(tester);
    expect(options(tester), [
      'Off',
      'Fast · from the next video',
      'Quality · from the next video',
    ]);
    await _pickOption(tester, 'Fast · from the next video');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(Settings.upscale, Upscale.fast);
    expect(find.text('Upscaling starts with the next video'), findsOneWidget);
    // This player stays on Media3, and Media3 runs no shaders.
    expect(media3.calls, isNot(contains('shaders')));
    expect(media3.disposed, isFalse);
    await close(tester);
  });

  testWidgets('a TV box offers Off and Fast in its controls', (tester) async {
    final semantics = tester.ensureSemantics();
    await open(tester, backend: _Backend(VideoBackend.exoPlayer), tv: true);
    expect(find.bySemanticsLabel('Upscaling · Off'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.auto_awesome_outlined));
    await _settle(tester);
    expect(options(tester), ['Off', 'Fast · from the next video']);
    await _pickOption(tester, 'Fast · from the next video');
    await _settle(tester);
    expect(Settings.upscale, Upscale.fast);
    await close(tester);
    semantics.dispose();
  });

  testWidgets('on mpv, Fast and Quality apply at once with the phone chains', (
    tester,
  ) async {
    final mpv = _Backend(
      VideoBackend.mediaKit,
      next: _Backend(VideoBackend.exoPlayer),
    );
    await open(tester, backend: mpv, saved: Upscale.fast);
    await tester.pump(const Duration(milliseconds: 400));
    // A 720p video on the 1080p screen.
    expect(mpv.sent, [
      _paths(shaderChain(Upscale.fast, sourceHeight: 720, mobile: true)),
    ]);
    // mpv narrows HLS to one variant through the relay, so it asks for the cap.
    expect(qualityChecks, ['https://live.test/video.mp4']);
    expect(find.text('Fast'), findsOneWidget);
    await tester.tap(upscaleButton);
    await _settle(tester);
    expect(options(tester), ['Off', 'Fast', 'Quality']);
    await _pickOption(tester, 'Quality');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(Settings.upscale, Upscale.quality);
    expect(
      mpv.sent.last,
      _paths(shaderChain(Upscale.quality, sourceHeight: 720, mobile: true)),
    );
    expect(mpv.disposed, isFalse);
    await close(tester);
  });

  testWidgets('Media3 that can\'t open the video moves on as before', (
    tester,
  ) async {
    final media3 = _Backend(VideoBackend.exoPlayer, fails: true);
    await open(tester, backend: media3);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text("Upscaling isn't available for this video"), findsNothing);
    expect(media3.disposed, isFalse);
    await close(tester);
  });
}

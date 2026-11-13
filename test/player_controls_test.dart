import 'dart:convert';
import 'dart:io';

import 'package:aniview/exo.dart';
import 'package:aniview/history.dart';
import 'package:aniview/player.dart';
import 'package:aniview/platform.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Backend extends PlayerBackend {
  late void Function(Map) emit;
  final opened = <String>[];
  @override
  Future<void> start(void Function(Map) on) async => emit = on;
  @override
  Future<void> call(String method, Map<String, Object?> args) async {
    if (method == 'open') {
      opened.add(args['url']! as String);
      emit({
        'position': 0,
        'buffer': 0,
        'duration': 100000,
        'playing': true,
        'buffering': false,
      });
    }
  }

  @override
  Future<void> setVolume(double level) async {}
  @override
  Future<void> dispose() async {}
}

class SourceFixture extends Source {
  SourceFixture() : super('Fixture', 'https://fixture.test');
  final requested = <num>[];
  final requestedRefs = <Object>[];
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
  }) async {
    requested.add(episode.number);
    requestedRefs.add(episode.ref);
    return [VideoStream('Fixture', '/tmp/fixture.mp4', {})];
  }
}

class FallbackSource extends SourceFixture {
  final audioRequests = <bool>[];
  @override
  Future<List<VideoStream>> streams(
    Map media,
    Episode episode, {
    required bool dub,
  }) async {
    audioRequests.add(dub);
    if (dub) return [];
    return super.streams(media, episode, dub: dub);
  }
}

/// Servers in order; an HLS one on dead.test fails its quality pre-fetch.
class ServersSource extends SourceFixture {
  ServersSource(this.servers);
  final List<VideoStream> servers;
  @override
  Future<List<VideoStream>> streams(
    Map media,
    Episode episode, {
    required bool dub,
  }) async => servers;
}

void main() {
  testWidgets('player announces sub fallback and records the actual audio', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'fallback_to_sub': true,
      'prefer_dub': true,
      'resume': false,
    });
    await Settings.load();
    final source = FallbackSource();
    final backend = Backend();
    final media = {
      'id': 8192837,
      'title': {'romaji': 'Fixture'},
    };
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: PlayerScreen(
          media: media,
          source: source,
          episodes: [Episode(1, ref: '1')],
          index: 0,
          dub: true,
          backend: backend,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(source.audioRequests, [true, false]);
    expect(find.text('Dub unavailable · playing Sub'), findsOneWidget);
    backend.emit({
      'position': 30000,
      'buffer': 30000,
      'duration': 100000,
      'playing': true,
    });
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    final record = await WatchHistory.of(media);
    expect(record?.dub, isFalse);
    expect(Settings.preferDub, isTrue);
  });

  testWidgets(
    'offline entry streams an unsaved episode from its saved source',
    (tester) async {
      SharedPreferences.setMockInitialValues({'resume': false});
      await Settings.load();
      final source = SourceFixture();
      final previousLoad = Sites.load;
      Sites.load = () async => [source];
      Sites.reload();
      addTearDown(() {
        Sites.load = previousLoad;
        Sites.reload();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: PlayerScreen(
            media: {
              'id': 1234567,
              'title': {'romaji': 'Fixture'},
            },
            source: null,
            sourceName: source.name,
            episodes: [Episode(1, ref: 'obsolete-offline-reference')],
            index: 0,
            dub: false,
            backend: Backend(),
          ),
        ),
      );
      for (var i = 0; i < 20 && source.requested.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(source.requested, [1]);
      expect(source.requestedRefs, ['1']);
      expect(find.textContaining("isn't downloaded"), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  for (final skip in [true, false]) {
    for (final action in ['click', 'keyboard', 'automatic']) {
      testWidgets('$action Next respects skip filler=$skip', (tester) async {
        final id =
            9898 +
            ['click', 'keyboard', 'automatic'].indexOf(action) +
            (skip ? 0 : 10);
        SharedPreferences.setMockInitialValues({
          'skip_filler': skip,
          'resume': false,
          'auto_next': true,
          'filler:$id': jsonEncode({
            'at': DateTime.now().millisecondsSinceEpoch,
            'kinds': {'2': 'filler'},
          }),
        });
        await Settings.load();
        final oldDesktop = isDesktop;
        isDesktop = true;
        addTearDown(() => isDesktop = oldDesktop);
        tester.view.physicalSize = const Size(1400, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final source = SourceFixture();
        final backend = Backend();
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: PlayerScreen(
              media: {
                'id': id,
                'title': {'romaji': 'Fixture'},
              },
              source: source,
              episodes: [
                Episode(1, ref: '1'),
                Episode(2, ref: '2'),
                Episode(3, ref: '3'),
              ],
              index: 0,
              dub: false,
              backend: backend,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(source.requested, [1]);
        expect(find.byTooltip('Open in another app'), findsNothing);
        if (action == 'click') {
          await tester.tap(find.byTooltip('Next episode  (N)'));
        } else if (action == 'keyboard') {
          await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
        } else {
          backend.emit({'completed': true});
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(source.requested, [1, skip ? 3 : 2]);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
    }
  }

  group('a server failing before it loads', () {
    setUp(() {
      final previous = configureQuality;
      configureQuality = (url, _) async => url.contains('dead.test')
          ? throw const HttpException('HTTP 404')
          : const [];
      addTearDown(() => configureQuality = previous);
    });

    Future<void> open(
      WidgetTester tester,
      List<VideoStream> servers,
      Backend backend,
    ) async {
      SharedPreferences.setMockInitialValues({'resume': false});
      await Settings.load();
      expect(usesMediaKit, isTrue); // tests run on desktop: the pre-fetch path
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: PlayerScreen(
            media: {
              'id': 7007007,
              'title': {'romaji': 'Fixture'},
            },
            source: ServersSource(servers),
            episodes: [Episode(1, ref: '1')],
            index: 0,
            dub: false,
            backend: backend,
          ),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('falls back to the next server', (tester) async {
      final backend = Backend();
      await open(tester, [
        VideoStream('Dead', 'https://dead.test/video.mp4', {}),
        VideoStream('Live', 'https://live.test/video.mp4', {}),
      ], backend);
      expect(find.text('Dead failed · trying Live'), findsOneWidget);
      expect(backend.opened, ['https://live.test/video.mp4']);
      expect(find.text("Couldn't play this episode"), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('shows the error when no server is left', (tester) async {
      final backend = Backend();
      await open(tester, [
        VideoStream('Dead', 'https://dead.test/video.mp4', {}),
      ], backend);
      expect(backend.opened, isEmpty);
      expect(find.text("Couldn't play this episode"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    });
  });

  testWidgets('media_kit ignores an error once the video has loaded', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'resume': false});
    await Settings.load();
    expect(usesMediaKit, isTrue);
    final previous = configureQuality;
    configureQuality = (_, _) async => const [];
    addTearDown(() => configureQuality = previous);
    final backend = Backend();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: PlayerScreen(
          media: {
            'id': 7007008,
            'title': {'romaji': 'Fixture'},
          },
          source: ServersSource([
            VideoStream('Live', 'https://live.test/video.mp4', {}),
            VideoStream('Other', 'https://other.test/video.mp4', {}),
          ]),
          episodes: [Episode(1, ref: '1')],
          index: 0,
          dub: false,
          backend: backend,
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(backend.opened, ['https://live.test/video.mp4']);
    backend.emit({'error': 'demuxer: some log line'});
    await tester.pump(const Duration(milliseconds: 50));
    expect(backend.opened, ['https://live.test/video.mp4']);
    expect(find.text("Couldn't play this episode"), findsNothing);
    expect(find.textContaining('reloading'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('subtitles rise over the controls while they show', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'resume': false});
    await Settings.load();
    final previous = configureQuality;
    configureQuality = (_, _) async => const [];
    addTearDown(() => configureQuality = previous);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: PlayerScreen(
          media: {
            'id': 7007009,
            'title': {'romaji': 'Fixture'},
          },
          source: SourceFixture(),
          episodes: [Episode(1, ref: '1')],
          index: 0,
          dub: false,
          backend: Backend(),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    double bottom() =>
        tester.widget<ExoVideo>(find.byType(ExoVideo)).subtitleBottom;
    final setting = Settings.subtitleAppearance.bottom;
    expect(bottom(), greaterThan(setting)); // controls up
    await tester.pump(const Duration(seconds: 4)); // they hide while playing
    expect(bottom(), setting);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });
}

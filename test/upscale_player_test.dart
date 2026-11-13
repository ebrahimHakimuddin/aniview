import 'package:aniview/exo.dart';
import 'package:aniview/platform.dart';
import 'package:aniview/player.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/ui.dart';
import 'package:aniview/upscale.dart';
import 'package:aniview/upscaler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A player that plays a video [source] big, recording the `shaders` it's sent. [shaders] false answers like
/// Android's Media3, which has none.
class _Backend extends PlayerBackend {
  _Backend({this.source = const Size(640, 360), this.shaders = true});
  final Size source;
  final bool shaders;
  late void Function(Map) emit;
  final sent = <({List<String> paths, int? width, int? height})>[];
  final calls = <String>[];

  /// What `frame-drop-count` reads, in turn; the last one sticks.
  List<int> drops = [0];
  int _read = 0;

  @override
  bool get supportsShaders => shaders;

  @override
  Future<String?> property(String name) async => switch (name) {
    'frame-drop-count' => '${drops[(_read++).clamp(0, drops.length - 1)]}',
    'estimated-vf-fps' => '24.000000',
    _ => null,
  };

  @override
  Future<void> start(void Function(Map) on) async => emit = on;

  @override
  Future<void> call(String method, Map<String, Object?> args) async {
    calls.add(method);
    if (method == 'shaders') {
      sent.add((
        paths: (args['paths']! as List).cast<String>(),
        width: args['width'] as int?,
        height: args['height'] as int?,
      ));
    }
    if (method == 'open') {
      emit({
        'position': 0,
        'buffer': 0,
        'duration': 100000,
        'playing': true,
        'buffering': false,
        'width': source.width,
        'height': source.height,
      });
    }
  }

  @override
  Future<void> setVolume(double level) async {}
  @override
  Future<void> dispose() async {}
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

/// The Upscaling menu's entry for [label].
Finder _item(String label) =>
    find.widgetWithText(CheckedPopupMenuItem<Upscale>, label);

/// The files a chain installs to, by name.
List<String> _paths(List<String> chain) => [
  for (final name in chain) '/support/shaders/$name',
];

void main() {
  setUp(() {
    final install = installUpscaleShaders;
    installUpscaleShaders = (chain) async => _paths(chain);
    addTearDown(() => installUpscaleShaders = install);
    final quality = configureQuality;
    configureQuality = (_, _) async => const [];
    addTearDown(() => configureQuality = quality);
  });

  group('mpv gets the shaders one file at a time', () {
    late List<String> log;
    late MediaKitShaders shaders;
    setUp(() {
      log = [];
      shaders = MediaKitShaders(
        command: (args) async => log.add(args.join(' ')),
        setSize: ({width, height}) async => log.add('size $width×$height'),
      );
    });

    test(
      'apply clears, sizes the picture to the target, then appends in order',
      () async {
        await shaders.apply([
          '/s/A.glsl',
          '/s/B.glsl',
        ], target: const Size(2560, 1440));
        expect(log, [
          'change-list glsl-shaders clr ',
          'size null×null',
          'size 2560×1440',
          'change-list glsl-shaders append /s/A.glsl',
          'change-list glsl-shaders append /s/B.glsl',
        ]);
      },
    );

    test('replacing a chain clears the old one first', () async {
      await shaders.apply(['/s/A.glsl'], target: const Size(1920, 1080));
      log.clear();
      await shaders.apply(['/s/C.glsl'], target: const Size(3840, 2160));
      expect(log, [
        'change-list glsl-shaders clr ',
        'size null×null',
        'size 3840×2160',
        'change-list glsl-shaders append /s/C.glsl',
      ]);
    });

    test('an empty list just clears, at the video\'s own size', () async {
      await shaders.apply(const []);
      expect(log, ['change-list glsl-shaders clr ', 'size null×null']);
    });

    test('a restore with no target keeps the video\'s own size', () async {
      await shaders.apply(['/s/R.glsl']);
      expect(log, [
        'change-list glsl-shaders clr ',
        'size null×null',
        'change-list glsl-shaders append /s/R.glsl',
      ]);
    });
  });

  group('upscalePlan', () {
    test('upscales a 720p video in a 1440p box at the fitted size', () {
      final plan = upscalePlan(
        Upscale.fast,
        source: const Size(1280, 720),
        box: const Size(1280, 800),
        devicePixelRatio: 2,
        mobile: false,
      );
      expect(plan.target, const Size(2560, 1440));
      expect(
        plan.chain,
        shaderChain(Upscale.fast, sourceHeight: 720, mobile: false),
      );
    });

    test('runs nothing on a desktop when the video is as large as its box', () {
      final plan = upscalePlan(
        Upscale.quality,
        source: const Size(1920, 1080),
        box: const Size(1400, 900),
        devicePixelRatio: 1,
        mobile: false,
      );
      expect(plan.chain, isEmpty);
      expect(plan.target, isNull);
    });

    test('off runs nothing', () {
      final plan = upscalePlan(
        Upscale.off,
        source: const Size(640, 360),
        box: const Size(1920, 1080),
        devicePixelRatio: 1,
        mobile: false,
      );
      expect(plan, (chain: const <String>[], target: null));
    });
  });

  group('the watchdog', () {
    // Readings 2 s apart at 24 fps: 48 frames each.
    bool feed(UpscaleWatchdog w, List<int> drops, {int startS = 0}) {
      var slow = false;
      for (final (i, d) in drops.indexed) {
        slow = w.sample(
          dropped: d,
          position: Duration(seconds: startS + i * 2),
          fps: 24,
        );
      }
      return slow;
    }

    test('steps down when more than 10% of 6 s of frames dropped', () {
      // 15 of 144 frames over 6 s: over 10%.
      expect(feed(UpscaleWatchdog(), [0, 5, 10, 15]), isTrue);
    });

    test('keeps going at 10% or fewer', () {
      // 14 of 144: under.
      expect(feed(UpscaleWatchdog(), [0, 4, 9, 14]), isFalse);
      expect(feed(UpscaleWatchdog(), [100, 100, 100, 100, 100]), isFalse);
    });

    test('needs a whole window first', () {
      expect(feed(UpscaleWatchdog(), [0, 40, 80]), isFalse);
    });

    test('a seek starts the window over', () {
      final w = UpscaleWatchdog();
      expect(feed(w, [0, 30, 60], startS: 100), isFalse);
      // Back to 0:10: the drops before the seek don't count against the frames after it.
      expect(feed(w, [60, 61, 62, 63], startS: 10), isFalse);
      // Forward a minute, then slow: a whole window after the seek is needed again.
      expect(feed(w, [63, 80, 100], startS: 80), isFalse);
      expect(feed(w, [120], startS: 86), isTrue);
    });
  });

  testWidgets('steps down for the session when frames drop, and says so', (
    tester,
  ) async {
    final backend = _Backend()..drops = [0, 0, 40, 80, 120];
    final player = ExoPlayer(backend);
    final slowed = <Upscale>[];
    final upscaler = Upscaler(
      player,
      tier: Upscale.quality,
      mobile: false,
      onSlow: slowed.add,
    );
    upscaler.layout(const Size(1920, 1080), 1);
    await player.open('video');
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      backend.sent.single.paths,
      _paths(shaderChain(Upscale.quality, sourceHeight: 360, mobile: false)),
    );
    expect(upscaler.upscaling, isTrue);
    for (var s = 2; s <= 10; s += 2) {
      backend.emit({'position': s * 1000, 'buffer': 0, 'duration': 100000});
      await tester.pump(const Duration(seconds: 2));
    }
    expect(slowed, [Upscale.fast]);
    expect(upscaler.tier, Upscale.fast);
    expect(
      backend.sent.last.paths,
      _paths(shaderChain(Upscale.fast, sourceHeight: 360, mobile: false)),
    );
    upscaler.dispose();
  });

  testWidgets('reads no drops while paused or buffering', (tester) async {
    final backend = _Backend()..drops = [0, 100, 200, 300, 400, 500];
    final player = ExoPlayer(backend);
    final slowed = <Upscale>[];
    final upscaler = Upscaler(
      player,
      tier: Upscale.fast,
      mobile: false,
      onSlow: slowed.add,
    );
    upscaler.layout(const Size(1920, 1080), 1);
    await player.open('video');
    await tester.pump(const Duration(milliseconds: 400));
    backend.emit({'buffering': true});
    for (var s = 2; s <= 10; s += 2) {
      await tester.pump(const Duration(seconds: 2));
    }
    expect(slowed, isEmpty);
    upscaler.dispose();
  });

  group('the player', () {
    Future<void> open(
      WidgetTester tester,
      _Backend backend, {
      Upscale saved = Upscale.off,
    }) async {
      SharedPreferences.setMockInitialValues({
        'resume': false,
        'upscale': saved.name,
      });
      await Settings.load();
      final desktop = isDesktop;
      isDesktop = true;
      addTearDown(() => isDesktop = desktop);
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: PlayerScreen(
            media: {
              'id': 5050505,
              'title': {'romaji': 'Fixture'},
            },
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

    testWidgets(
      'offers Upscaling beside the speed; a pick saves it and applies',
      (tester) async {
        expect(usesMediaKit, isTrue); // tests run on a desktop OS
        final backend = _Backend();
        await open(tester, backend);
        expect(backend.calls, contains('open'));
        expect(backend.sent, isEmpty); // off, and mpv starts with none
        await tester.tap(find.byTooltip('Upscaling · Off'));
        await tester.pumpAndSettle();
        await tester.tap(_item('Quality'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(Settings.upscale, Upscale.quality);
        // A 640×360 video fitted in the 1400×900 window.
        expect(backend.sent, hasLength(1));
        expect(
          backend.sent.single.paths,
          _paths(
            shaderChain(Upscale.quality, sourceHeight: 360, mobile: false),
          ),
        );
        expect(
          (backend.sent.single.width, backend.sent.single.height),
          (1400, 788),
        );
        expect(find.byTooltip('Upscaling · Quality'), findsOneWidget);

        // The window grows (fullscreen): sent again once it settles, not for every size on the way.
        tester.view.physicalSize = const Size(1600, 1000);
        await tester.pump();
        tester.view.physicalSize = const Size(1920, 1080);
        await tester.pump();
        expect(backend.sent, hasLength(1));
        await tester.pump(const Duration(milliseconds: 350));
        expect(backend.sent, hasLength(2));
        expect(
          (backend.sent.last.width, backend.sent.last.height),
          (1920, 1080),
        );
        // The same chain and size aren't sent twice.
        tester.view.physicalSize = const Size(1920, 1080);
        await tester.pump(const Duration(milliseconds: 350));
        expect(backend.sent, hasLength(2));

        // Off clears them.
        await tester.tap(find.byTooltip('Upscaling · Quality'));
        await tester.pumpAndSettle();
        await tester.tap(_item('Off'));
        await tester.pump(const Duration(milliseconds: 100));
        expect(backend.sent.last.paths, isEmpty);
        expect((backend.sent.last.width, backend.sent.last.height), (
          null,
          null,
        ));
        expect(Settings.upscale, Upscale.off);
        await close(tester);
      },
    );

    testWidgets('sends nothing when the video is already as large as its box', (
      tester,
    ) async {
      final backend = _Backend(source: const Size(1920, 1080));
      await open(tester, backend, saved: Upscale.quality);
      await tester.pump(const Duration(milliseconds: 400));
      expect(backend.calls, contains('open'));
      expect(backend.calls, isNot(contains('shaders')));
      await close(tester);
    });

    testWidgets('upscales on open with the saved tier', (tester) async {
      final backend = _Backend();
      await open(tester, backend, saved: Upscale.fast);
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        backend.sent.single.paths,
        _paths(shaderChain(Upscale.fast, sourceHeight: 360, mobile: false)),
      );
      await close(tester);
    });

    testWidgets('never sends shaders to Android\'s player', (tester) async {
      final backend = _Backend(shaders: false);
      await open(tester, backend, saved: Upscale.quality);
      await tester.pump(const Duration(milliseconds: 400));
      tester.view.physicalSize = const Size(1920, 1080);
      await tester.pump(const Duration(milliseconds: 400));
      expect(backend.calls, contains('open'));
      expect(backend.calls, isNot(contains('shaders')));
      // Nor does ExoPlayer pass one on when asked straight.
      final android = _Backend(shaders: false);
      await ExoPlayer(android)
          .setShaders(['/s/A.glsl'], target: const Size(1920, 1080));
      expect(android.calls, isEmpty);
      await close(tester);
    });
  });
}

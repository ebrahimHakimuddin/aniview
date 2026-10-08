import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aniview/anilist.dart';
import 'package:aniview/changelog.dart';
import 'package:aniview/details.dart';
import 'package:aniview/downloads.dart';
import 'package:aniview/exo.dart';
import 'package:aniview/main.dart' as app;
import 'package:aniview/platform.dart';
import 'package:aniview/player.dart';
import 'package:aniview/search.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/tracker.dart';
import 'package:aniview/tv.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Only catalogue/stream discovery is replaced. Storage, HTTP video requests,
// remuxing, playback, preferences, windows and input use the native plugins.
const origin = String.fromEnvironment(
  'NATIVE_FIXTURE_URL',
  defaultValue: 'http://127.0.0.1:8765',
);
const fixture = <String, dynamic>{
  'id': 9000001,
  'title': {'userPreferred': 'Japanese fixture', 'english': 'English fixture'},
  'description': 'A small local video used to verify native playback.',
  'averageScore': 86,
  'genres': ['Action', 'Fantasy'],
  'episodes': 4,
  'format': 'TV',
  'status': 'FINISHED',
};
const episodes = [
  Episode(1, ref: 'plain', title: 'Plain video'),
  Episode(2, ref: 'encrypted', title: 'Encrypted video'),
  Episode(3, ref: 'direct', title: 'Direct MP4'),
  Episode(4, ref: 'retry', title: 'Retry with another source'),
];

class _Catalog implements Catalog {
  @override
  bool get usable => true;
  @override
  Future<List> trending() async => [fixture];
  @override
  Future<List> season() async => [fixture];
  @override
  Future<(List, bool)> search(
    String text,
    SearchFilters filters,
    int page,
  ) async => (
    [
      fixture,
      {...fixture, 'id': 9000002},
    ],
    false,
  );
  @override
  Future<List<(String, Map)>> relations(Map media) async => [];
}

class _Source extends Source {
  _Source(String name, {this.unavailable = false}) : super(name, origin);
  final bool unavailable;
  @override
  Future<List<SearchResult>> search(String query) async => [];
  @override
  Future<String?> match(Map media) async => 'fixture';
  @override
  Future<List<Episode>> episodesOf(String id) async => episodes;
  @override
  Future<List<VideoStream>> streams(
    Map media,
    Episode episode, {
    required bool dub,
  }) async {
    if (unavailable) {
      return [VideoStream('Unsupported', '$origin/video.mpd', const {})];
    }
    final path = switch (episode.ref) {
      'encrypted' => 'encrypted/index.m3u8',
      'direct' => 'direct.mp4',
      _ => 'plain/index.m3u8',
    };
    return [VideoStream('Fixture', '$origin/$path', const {})];
  }
}

class _Client extends http.BaseClient {
  final inner = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      request.url.host == 'api.ani.zip' || request.url.host == 'api.aniskip.com'
      ? Future.value(http.StreamedResponse(Stream.value('{}'.codeUnits), 200))
      : inner.send(request);
  @override
  void close() => inner.close();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  final capture = GlobalKey();
  late Directory reports;

  Future<void> waitFor(
    WidgetTester tester,
    bool Function() ready,
    String reason, {
    Duration timeout = const Duration(
      seconds: int.fromEnvironment('NATIVE_WAIT_SECONDS', defaultValue: 45),
    ),
  }) async {
    final end = DateTime.now().add(timeout);
    while (!ready() && DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!ready()) {
      for (final item in Downloads.instance.items) {
        debugPrint(
          'NATIVE_WAIT_FAILURE source=${item.source} status=${item.status} error=${item.error}',
        );
      }
    }
    expect(ready(), isTrue, reason: reason);
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    await tester.pump();
    final boundary =
        capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('${reports.path}/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      final scrollable = find
          .descendant(
            of: find.byType(CustomScrollView).first,
            matching: find.byType(Scrollable),
          )
          .first;
      for (var i = 0; i < 20 && finder.evaluate().isEmpty; i++) {
        await tester.drag(scrollable, const Offset(0, -180));
        await tester.pumpAndSettle();
      }
    }
    await Scrollable.ensureVisible(tester.element(finder.first), alignment: .5);
    await tester.pumpAndSettle();
  }

  Future<void> page(WidgetTester tester, Widget child) async {
    // Changing screens through the harness must dismiss the real Android IME,
    // just as navigating away from the search field does in the application.
    FocusManager.instance.primaryFocus?.unfocus();
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    debugPrint('NATIVE_STAGE screen ${child.runtimeType}');
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          key: UniqueKey(),
          theme: buildTheme(),
          builder: (_, child) => isTv ? TvInput(child: child!) : child!,
          home: child,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> downloadEpisode(
    WidgetTester tester,
    Episode episode, {
    bool retry = false,
  }) async {
    if (isTv) {
      final number = episode.number == episode.number.round()
          ? episode.number.toInt().toString()
          : episode.number.toString();
      final card = find.byWidgetPredicate(
        (widget) =>
            widget is FocusCard && widget.semanticLabel == 'Episode $number',
      );
      await reveal(tester, card);
      await tester.longPress(card);
      await tester.pumpAndSettle();
      await tester.tap(find.text(retry ? 'Retry download' : 'Download sub'));
    } else {
      final button = retry
          ? find.widgetWithIcon(IconButton, Icons.error_outline_rounded)
          : find.byTooltip('Download');
      await reveal(tester, button);
      await tester.tap(button.first);
    }
    await tester.pumpAndSettle();
  }

  late SharedPreferences prefs;
  late bool checkpoint;
  var initialized = false;
  var discoveryCompleted = false;

  testWidgets('native theme, sign-in choices and discovery', (tester) async {
    prefs = await SharedPreferences.getInstance();
    checkpoint = prefs.getBool('native_test_checkpoint') ?? false;
    if (const bool.fromEnvironment('NATIVE_REQUIRE_RESTART')) {
      expect(
        checkpoint,
        isTrue,
        reason:
            'The preceding process must have saved its completion checkpoint',
      );
    }
    await prefs.setBool('native_test_checkpoint', false);
    if (checkpoint) {
      expect(prefs.getString('preferred_source'), 'Working source');
      expect(prefs.getString('theme_selection'), 'materialLight');
    } else {
      // Run this suite only in a disposable installation: it resets preferences.
      await prefs.clear();
    }
    await prefs.setString('changelog_seen', changelogVersion);
    await prefs.setString('theme_selection', 'materialDark');
    await prefs.setBool('follow_system_theme', false);
    await prefs.setBool('analytics', false);
    Tracker.primary = _Catalog();
    Sites.load = () async => [
      _Source('Unsupported source', unavailable: true),
      _Source('Working source'),
    ];
    Sites.reload();
    httpClient = _Client();
    AniList.transport = (_, _) async => {
      'Page': {
        'media': [],
        'airingSchedules': [],
        'mediaList': [],
        'pageInfo': {'hasNextPage': false},
      },
    };
    await app.main();
    await tester.pumpAndSettle();
    final logoData = await rootBundle.load('assets/icon/aniview_wordmark.png');
    var logoHash = 2166136261;
    for (final byte in logoData.buffer.asUint8List(
      logoData.offsetInBytes,
      logoData.lengthInBytes,
    )) {
      logoHash = ((logoHash ^ byte) * 16777619) & 0xffffffff;
    }
    debugPrint(
      'NATIVE_LOGO_BYTES length=${logoData.lengthInBytes} fnv=$logoHash',
    );
    // A known one-pixel PNG distinguishes a general native codec failure from
    // the application's logo data. A failed probe remains a failed UI case.
    final tinyPng = Uint8List.fromList([
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
      0,
      0,
      0,
      13,
      73,
      72,
      68,
      82,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      1,
      8,
      6,
      0,
      0,
      0,
      31,
      21,
      196,
      137,
      0,
      0,
      0,
      13,
      73,
      68,
      65,
      84,
      120,
      156,
      99,
      248,
      207,
      192,
      240,
      31,
      0,
      5,
      0,
      1,
      255,
      137,
      153,
      61,
      29,
      0,
      0,
      0,
      0,
      73,
      69,
      78,
      68,
      174,
      66,
      96,
      130,
    ]);
    try {
      final codec = await ui.instantiateImageCodec(tinyPng);
      try {
        final frame = await codec.getNextFrame();
        debugPrint(
          'NATIVE_TINY_PNG decoded ${frame.image.width}x${frame.image.height}',
        );
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
    } catch (error) {
      debugPrint('NATIVE_TINY_PNG failed $error');
    }
    if (checkpoint) {
      expect(Settings.preferredSource, 'Working source');
      for (final episode in episodes) {
        expect(
          Downloads.instance.find(fixture, episode.number),
          isNotNull,
          reason: 'Completed download survives a process restart',
        );
      }
      debugPrint('NATIVE_COLD_RESTART preferences and downloads restored');
    }
    reports = await Directory(
      '${Directory(Downloads.instance.folder).parent.path}/native-reports',
    ).create(recursive: true);
    debugPrint(
      'NATIVE_PLATFORM desktop=$isDesktop tv=$deviceIsTv os=${Platform.operatingSystem}',
    );
    initialized = true;

    // Actual root app: both logos and the header must change without restarting.
    await tester.pumpWidget(
      RepaintBoundary(key: capture, child: const app.App()),
    );
    await tester.pumpAndSettle();
    Finder logo(String name) => find.byWidgetPredicate((widget) {
      if (widget is! Image) return false;
      final provider = widget.image is ResizeImage
          ? (widget.image as ResizeImage).imageProvider
          : widget.image;
      return provider is AssetImage &&
          provider.assetName == 'assets/icon/$name.png';
    });
    Future<void> decodedLogo(String name) => waitFor(tester, () {
      final images = find.descendant(
        of: logo(name),
        matching: find.byType(RawImage),
      );
      return images.evaluate().isNotEmpty &&
          tester.widget<RawImage>(images.first).image != null;
    }, 'The $name logo must decode, not just exist as an Image widget');
    await decodedLogo('aniview_wordmark');
    await screenshot(tester, 'home-dark');
    Settings.themeSelection = ThemeSelection.materialLight;
    app.themeGeneration.value++;
    await tester.pumpAndSettle();
    expect(logo('aniview_wordmark_light'), findsOneWidget);
    expect(logo('aniview_wordmark'), findsNothing);
    await decodedLogo('aniview_wordmark_light');
    await screenshot(tester, 'home-light');

    await page(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Tracker.signIn(context),
            child: const Text('Sign in'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Sign in with AniList'), findsOneWidget);
    expect(find.text('Sign in with MyAnimeList'), findsOneWidget);
    await screenshot(tester, 'sign-in-options');

    await page(tester, const SearchScreen());
    if (isTv) {
      expect(find.text('English fixture'), findsWidgets);
      expect(find.text(fixture['description']! as String), findsOneWidget);
      final focus = tester.widget<Focus>(
        find
            .descendant(
              of: find.byType(PosterCard).last,
              matching: find.byType(Focus),
            )
            .last,
      );
      Focus.of(tester.element(find.byWidget(focus.child))).requestFocus();
      await tester.pumpAndSettle();
      expect(find.text('Genres'), findsNothing);
      await screenshot(tester, 'tv-discovery');
      tester
          .widget<TextField>(find.byType(TextField))
          .focusNode!
          .requestFocus();
      await tester.pumpAndSettle();
      expect(find.text('Genres'), findsOneWidget);
    }
    await tester.enterText(find.byType(TextField), 'fixture');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    await screenshot(tester, 'cleared-search');
    discoveryCompleted = true;
  }, timeout: const Timeout(Duration(minutes: 20)));

  testWidgets('native source recovery, downloads, playback and persisted state', (
    tester,
  ) async {
    expect(
      initialized,
      isTrue,
      reason: 'Native app initialization must finish',
    );
    // Use the source picker and then reload the real persisted preferences.
    await page(tester, DetailsScreen({...fixture}));
    if (Settings.preferredSource == 'Working source') {
      await reveal(tester, find.text('#2  Working source'));
      await tester.tap(find.text('#2  Working source'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('#1  Unsupported source'));
      await tester.pumpAndSettle();
    }
    await reveal(tester, find.text('#1  Unsupported source'));
    await tester.tap(find.text('#1  Unsupported source'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#2  Working source'));
    await tester.pumpAndSettle();
    expect(Settings.preferredSource, 'Working source');
    await prefs.reload();
    expect(prefs.getString('preferred_source'), 'Working source');
    await tester.pumpWidget(const SizedBox.shrink());
    await Settings.load();
    Sites.reload();
    await page(tester, DetailsScreen({...fixture}));
    expect(find.text('#2  Working source'), findsOneWidget);
    await screenshot(tester, 'saved-source');

    final downloads = Downloads.instance;
    await downloads.removeAll();
    await page(tester, DetailsScreen({...fixture}));
    await reveal(tester, find.text('#2  Working source'));
    await tester.tap(find.text('#2  Working source'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#1  Unsupported source'));
    await tester.pumpAndSettle();
    await downloadEpisode(tester, episodes.first);
    await waitFor(
      tester,
      () => downloads.entry(fixture, 1, false)?.status == DownloadStatus.failed,
      'The unsupported source should fail without clearing app data',
    );
    await reveal(tester, find.text('#1  Unsupported source'));
    await tester.tap(find.text('#1  Unsupported source'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#2  Working source'));
    await tester.pumpAndSettle();
    await downloadEpisode(tester, episodes.first, retry: true);
    await waitFor(
      tester,
      () => downloads.entry(fixture, 1, false)?.status == DownloadStatus.done,
      'Switching source should recover: ${downloads.entry(fixture, 1, false)?.error}',
    );
    expect(downloads.entry(fixture, 1, false)!.source, 'Working source');
    expect(downloads.entry(fixture, 1, false)!.error, isNull);

    // Decode downloaded clear HLS, AES-128 HLS and direct MP4 with real native players.
    await page(tester, const Scaffold(body: Text('Native video checks')));
    for (final episode in episodes.take(3)) {
      await page(tester, DetailsScreen({...fixture}));
      if (episode.number != 1) {
        await downloadEpisode(tester, episode);
      }
      await waitFor(
        tester,
        () =>
            downloads.entry(fixture, episode.number, false)?.status ==
            DownloadStatus.done,
        'Download ${episode.ref}: ${downloads.entry(fixture, episode.number, false)?.error}',
      );
      final d = downloads.find(fixture, episode.number)!;
      if (Platform.isAndroid || episode.ref == 'direct') {
        expect(d.videoFile, 'episode.mp4');
        final files = await Directory('${downloads.folder}/${d.id}')
            .list()
            .toList();
        expect(
          files.whereType<File>().map((file) => file.uri.pathSegments.last),
          ['episode.mp4'],
        );
      }
      debugPrint('NATIVE_STAGE playing ${episode.ref}');
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: PlayerScreen(
            media: {...fixture},
            source: null,
            episodes: [episode],
            index: 0,
            dub: false,
          ),
        ),
      );
      await tester.pump();
      final player =
          (tester.state(find.byType(PlayerScreen)) as dynamic).player
              as ExoPlayer;
      final errors = <String>[];
      final sub = player.stream.error.listen(errors.add);
      try {
        try {
          await waitFor(
            tester,
            () =>
                player.state.duration.inMilliseconds > 3000 &&
                player.state.position.inMilliseconds > 200 &&
                player.state.size != null,
            'Native decode ${episode.ref}: $errors',
          );
        } catch (_) {
          final screen = tester.state(find.byType(PlayerScreen)) as dynamic;
          debugPrint(
            'NATIVE_PLAYER_FAILURE episode=${episode.ref} '
            'duration=${player.state.duration} position=${player.state.position} '
            'size=${player.state.size} screenError=${screen.error} errors=$errors',
          );
          rethrow;
        }
        await player.pause().timeout(const Duration(seconds: 15));
        await player
            .seek(const Duration(seconds: 2))
            .timeout(const Duration(seconds: 15));
        await waitFor(
          tester,
          () => player.state.position.inMilliseconds >= 1800,
          'Native seek ${episode.ref}',
        );
        expect(errors, isEmpty);
        debugPrint(
          'NATIVE_VIDEO ${episode.ref} file=${d.videoFile} duration=${player.state.duration} size=${player.state.size}',
        );
      } finally {
        await sub.cancel();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 500));
      }
    }
    downloads.enqueue(
      {...fixture},
      'Working source',
      [episodes.last],
      dub: false,
      season: episodes,
    );
    await waitFor(
      tester,
      () => downloads.entry(fixture, 4, false)?.status == DownloadStatus.done,
      'Final download saved for the cold restart check',
    );
    await waitFor(tester, () {
      try {
        final saved = readIndex(
          File('${downloads.folder}/index.json').readAsStringSync(),
        );
        return saved.where((d) => d.status == DownloadStatus.done).length ==
            episodes.length;
      } catch (_) {
        return false;
      }
    }, 'All completed downloads persisted before exiting the process');
    await prefs.setBool('native_test_checkpoint', discoveryCompleted);
    binding.reportData = {
      'native_completed': discoveryCompleted,
      'os': Platform.operatingSystem,
      'tv': isTv,
      'cold_restart': checkpoint,
    };
    debugPrint('NATIVE_REPORTS ${reports.path}');
  }, timeout: const Timeout(Duration(minutes: 20)));
}

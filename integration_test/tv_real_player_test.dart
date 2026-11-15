// A manual check of the real player on a device: plays a real video file through the app's own player (ExoPlayer on
// Android, no fake backend) and keeps it open for REAL_SECONDS, so it can be driven from the host with
// `adb shell input keyevent …` and screenshotted.
//
//   python3 -m http.server 8765 --bind 127.0.0.1 --directory <dir with clock.mp4> &
//   flutter drive --profile --no-dds -d <device> --driver=test_driver/perf_driver.dart \
//     --target=integration_test/tv_real_player_test.dart \
//     --dart-define=REAL_VIDEO=http://10.0.2.2:8765/clock.mp4 --dart-define=REAL_SECONDS=300
//
// 10.0.2.2 is the host as an Android emulator sees it; on a phone over adb, `adb reverse tcp:8765 tcp:8765` and
// http://127.0.0.1:8765/clock.mp4. The file is fetched once, then served to the player from a loopback server that
// answers byte ranges, as a site's server would; every other request is blocked as in perf_test.dart. The log says
// REAL_PLAYER_READY when the player is up and REAL_PLAYER_DONE before it closes.
import 'dart:async';
import 'dart:io';

import 'package:aniview/changelog.dart';
import 'package:aniview/main.dart';
import 'package:aniview/player.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/tracker.dart';
import 'package:aniview/tv.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'perf_fixtures.dart';

const _video = String.fromEnvironment('REAL_VIDEO');
const _seconds = int.fromEnvironment('REAL_SECONDS', defaultValue: 240);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  // Real touches (`adb shell input` on a phone) reach the app; the test binding otherwise keeps them to itself.
  binding.shouldPropagateDevicePointerEvents = true;
  late HttpServer server;
  final site = FakeSite();

  setUpAll(() async {
    if (_video.isEmpty) throw StateError('Give --dart-define=REAL_VIDEO=<url>');
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/real_player.mp4');
    // Fetched before the guard goes up: it lets only loopback through.
    final client = HttpClient();
    final res = await (await client.getUrl(Uri.parse(_video))).close();
    if (res.statusCode != 200) throw StateError('$_video: ${res.statusCode}');
    await res.pipe(file.openWrite());
    client.close();
    server = await _serve(file);
    site.server = Uri.parse('http://127.0.0.1:${server.port}/');
    guardNetwork();
    SharedPreferences.setMockInitialValues({
      'changelog_seen': changelogVersion,
      'welcome': false,
      'resume': false,
      'analytics': false,
      'subscription_survey_v1': 'answered',
      'subscription_survey_beta_v2': 'answered',
    });
    await Settings.load();
    await detectTv(layout: Settings.layout);
    // On a phone, the swipes (seek, brightness, volume) are driven too; they're off by default.
    if (!isTv) Settings.swipeGestures = true;
    Sites.load = () async => [site];
    Sites.reload();
    ExtensionHost.current = NoExtensions();
    Tracker.primary = FakeCatalog();
    await seedPosters(Directory('${dir.path}/real_player_posters'));
  });

  tearDownAll(() => server.close(force: true));

  testWidgets('real player, driven from the host', (tester) async {
    await tester.pumpWidget(const App());
    await Future<void>.delayed(const Duration(seconds: 3));
    unawaited(
      Navigator.of(
        tester.element(find.byType(Scaffold).first),
        rootNavigator: true,
      ).push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerScreen(
            media: fakeShow(5),
            source: site,
            episodes: [for (var i = 1; i <= 3; i++) Episode(i, ref: '$i')],
            index: 0,
            dub: false,
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(seconds: 3));
    debugPrint('REAL_PLAYER_READY isTv=$isTv');
    await Future<void>.delayed(const Duration(seconds: _seconds));
    debugPrint('REAL_PLAYER_DONE');
  });
}

/// Serves [file] at every path, answering byte ranges.
Future<HttpServer> _serve(File file) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final length = await file.length();
  server.listen((request) async {
    final res = request.response;
    try {
      var start = 0, end = length - 1;
      res.headers
        ..contentType = ContentType('video', 'mp4')
        ..set(HttpHeaders.acceptRangesHeader, 'bytes');
      final range = RegExp(r'bytes=(\d*)-(\d*)')
          .firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
      if (range != null) {
        if (range[1]!.isNotEmpty) start = int.parse(range[1]!);
        if (range[2]!.isNotEmpty) end = int.parse(range[2]!);
        res
          ..statusCode = HttpStatus.partialContent
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/$length',
          );
      }
      res.contentLength = end - start + 1;
      if (request.method != 'HEAD') {
        await res.addStream(file.openRead(start, end + 1));
      }
    } catch (_) {
      // The player let go of the connection.
    } finally {
      await res.close().catchError((Object _) {});
    }
  });
  return server;
}

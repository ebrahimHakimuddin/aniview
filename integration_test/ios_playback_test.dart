import 'dart:io';

import 'package:aniview/exo.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/stream_address.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' show MediaKit;
import 'package:path_provider/path_provider.dart';

// First run: python3 tool/ios_media_fixture.py
// Then: flutter test integration_test/ios_playback_test.dart -d <iPhone simulator>
// This exercises the actual iOS libraries, not the fake PlayerBackend in unit tests.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native iOS HLS, headers, subtitles, seeking and offline tracks',
    (tester) async {
      expect(
        Platform.isIOS,
        isTrue,
        reason: 'Run on an iOS simulator or device',
      );
      MediaKit.ensureInitialized();
      const origin = 'http://127.0.0.1:8765';
      const headers = {'X-AniView-Fixture': '1'};
      final directory = await Directory(
        '${(await getApplicationSupportDirectory()).path}/playback-smoke',
      ).create(recursive: true);
      final player = ExoPlayer();
      final errors = <String>[];
      final subscription = player.stream.error.listen(errors.add);
      addTearDown(() async {
        await subscription.cancel();
        await player.dispose();
        await directory.delete(recursive: true);
      });

      Future<void> until(bool Function() ready) async {
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (!ready() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          ready(),
          isTrue,
          reason: 'Native player timed out; errors: $errors',
        );
      }

      Future<void> save(String name) async {
        final response = await http.get(
          Uri.parse('$origin/$name'),
          headers: headers,
        );
        expect(response.statusCode, 200);
        await File('${directory.path}/$name').writeAsBytes(response.bodyBytes);
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExoVideo(
              player,
              subtitleStyle: const TextStyle(fontSize: 22),
            ),
          ),
        ),
      );
      final address = await StreamAddress.instance.forPlayer(
        VideoStream(
          'Fixture',
          '$origin/index.m3u8',
          headers,
          subtitles: [Subtitle('English', '$origin/en.vtt')],
        ),
      );
      final shown = await player.load(
        address.url,
        headers: address.headers,
        hls: address.hls,
        start: const Duration(seconds: 4),
        subtitles: address.subtitles,
        subtitleFile: 'English',
        rate: 1.5,
      );
      expect(shown, 'English');
      await until(
        () => player.state.size != null && player.state.position.inSeconds >= 4,
      );
      expect(player.state.duration.inSeconds, greaterThanOrEqualTo(19));
      await until(() => player.cues.value.contains('AniView subtitle'));
      await player.pause();
      await until(() => !player.state.playing);
      await player.seek(const Duration(seconds: 8));
      await until(() => (player.state.position.inSeconds - 8).abs() <= 1);
      await player.setSubtitleTrack(SubtitleTrack.off);
      expect(player.cues.value, isEmpty);
      await player.setRate(2);
      await player.play();
      await until(
        () => player.state.playing && player.state.position.inSeconds >= 10,
      );
      await player.stop();

      // Reopen the saved HLS with relative segment names and no network URLs.
      await save('index.m3u8');
      await save('en.vtt');
      final playlist = await File('${directory.path}/index.m3u8').readAsLines();
      for (final line in playlist.where(
        (line) => line.isNotEmpty && !line.startsWith('#'),
      )) {
        await save(line);
      }
      await player.load(
        '${directory.path}/index.m3u8',
        start: const Duration(seconds: 6),
        subtitles: [(url: '${directory.path}/en.vtt', label: 'English')],
        subtitleFile: 'English',
      );
      await until(
        () => player.state.position.inSeconds >= 6 && player.state.playing,
      );
      await player.stop();

      // Two embedded audio tracks in a local MP4, with no server needed for playback.
      await save('sample.mp4');
      await player.load('${directory.path}/sample.mp4');
      await until(() => player.state.audios.length == 2);
      await player.setAudioTrack(player.state.audios.last);
      await until(
        () => player.state.playing && player.state.position > Duration.zero,
      );
      expect(errors, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

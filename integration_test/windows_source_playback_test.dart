import 'dart:io';

import 'package:aniview/exo.dart';
import 'package:aniview/platform.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/stream_address.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' show MediaKit, NativePlayer;

// Opt-in live Windows check. The separate native fixture is the offline control.
// flutter test integration_test/windows_source_playback_test.dart -d windows
String _safe(Object error) =>
    '$error'.replaceAll(RegExp(r'''https?://[^\s"'<>]+'''), '<redacted URL>');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const media = {
    'id': 21,
    'idMal': 21,
    'title': {'english': 'One Piece', 'romaji': 'One Piece'},
  };

  for (final source in [
    Anikoto('Anikoto', 'https://anikototv.to'),
    AniPm('ani.pm', 'https://ani.pm'),
    AnimeStream('AnimeStream', 'https://anime.uniquestream.net'),
  ]) {
    testWidgets('${source.name}: One Piece 1180 native playback', (
      tester,
    ) async {
      expect(Platform.isWindows, isTrue, reason: 'Run with -d windows');
      isDesktop = true;
      MediaKit.ensureInitialized();
      final player = ExoPlayer();
      final nativeLogs = player.video!.player.stream.log.listen((log) {
        if (log.level == 'error' || log.level == 'fatal') {
          stdout.writeln('native ${log.prefix}: ${_safe(log.text)}');
        }
      });
      final startupErrors = <String>[];
      final allErrors = <String>[];
      final subscription = player.stream.error.listen((error) {
        allErrors.add(_safe(error));
        // Match PlayerScreen's startup-error decision, not merely file loading.
        if (player.state.duration == Duration.zero) {
          startupErrors.add(_safe(error));
        }
      });
      addTearDown(() async {
        await nativeLogs.cancel();
        await subscription.cancel();
        await player.dispose();
      });
      var stage = 'source match';
      try {
        await player.pause();
        final native = player.video!.player.platform as NativePlayer;
        final version = await native.getProperty('mpv-version');
        stdout.writeln('${source.name}: native player $version');
        final id = await source
            .match(media)
            .timeout(const Duration(seconds: 60));
        expect(id, isNotNull);
        stage = 'episode listing';
        final episodes = await source
            .episodesOf(id!)
            .timeout(const Duration(seconds: 60));
        final episode = episodes.firstWhere((e) => e.number == 1180);
        stage = 'stream extraction';
        final streams = await source
            .streams(media, episode, dub: false)
            .timeout(const Duration(seconds: 90));
        expect(streams, isNotEmpty);
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

        Future<void> until(bool Function() ready) async {
          final deadline = DateTime.now().add(const Duration(seconds: 45));
          while (!ready() && DateTime.now().isBefore(deadline)) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(ready(), isTrue, reason: '$stage timed out; $allErrors');
        }

        final failures = <String>[];
        for (final (index, stream) in streams.indexed) {
          startupErrors.clear();
          allErrors.clear();
          try {
            stage = 'server ${index + 1}: relay setup';
            final address = await StreamAddress.instance
                .forPlayer(stream)
                .timeout(const Duration(seconds: 45));
            stage = 'server ${index + 1}: native open at 10 seconds';
            await player
                .load(
                  address.url,
                  headers: address.headers,
                  hls: address.hls,
                  start: const Duration(seconds: 10),
                  subtitles: address.subtitles,
                  audios: address.audios,
                )
                .timeout(const Duration(seconds: 60));
            await until(
              () =>
                  player.state.duration > Duration.zero &&
                  player.state.size != null &&
                  player.state.playing &&
                  player.state.position.inSeconds >= 12,
            );
            expect(
              startupErrors,
              isEmpty,
              reason: 'PlayerScreen would report a startup failure',
            );
            stage = 'server ${index + 1}: seek';
            await player.seek(const Duration(seconds: 30));
            await until(
              () =>
                  player.state.position.inSeconds >= 32 &&
                  player.state.position.inSeconds < 45 &&
                  player.state.playing,
            );
            stdout.writeln(
              '${source.name} server ${index + 1}: '
              'PASS duration=${player.state.duration.inSeconds}s '
              'size=${player.state.size}; errors=$allErrors',
            );
          } catch (error) {
            failures.add('$stage: ${_safe(error)}; errors=$allErrors');
            stdout.writeln('${source.name}: FAIL ${failures.last}');
          } finally {
            await player.stop().timeout(const Duration(seconds: 10));
          }
        }
        expect(failures, isEmpty);
      } catch (error) {
        fail('${source.name} / $stage: ${_safe(error)}');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }, timeout: const Timeout(Duration(minutes: 12)));
  }
}

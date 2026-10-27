import 'dart:io';

import 'package:aniview/exo.dart';
import 'package:aniview/platform.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/stream_address.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' show MediaKit, NativePlayer;

import 'native_diagnostic.dart';

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

  testWidgets('missing media still reports a native playback error', (
    tester,
  ) async {
    expect(Platform.isWindows, isTrue, reason: 'Run with -d windows');
    isDesktop = true;
    MediaKit.ensureInitialized();
    final directory = await Directory.systemTemp.createTemp('aniview-missing-');
    final player = ExoPlayer();
    addTearDown(() async {
      await player.dispose().timeout(const Duration(seconds: 10));
      await directory.delete(recursive: true);
    });
    await tester.pumpWidget(
      MaterialApp(home: ExoVideo(player, subtitleStyle: const TextStyle())),
    );
    await configureNativeDiagnostic(player);
    final errors = <String>[];
    final subscription = player.stream.error.listen(errors.add);
    addTearDown(subscription.cancel);
    await player
        .open(directory.uri.resolve('missing.mp4').toFilePath())
        .timeout(const Duration(seconds: 10));
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (errors.isEmpty && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      errors,
      isNotEmpty,
      reason: 'Real file-open errors must reach the UI',
    );
    expect(player.state.duration, Duration.zero);
    await tester.pumpWidget(const SizedBox.shrink());
  });

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
        await player.dispose().timeout(const Duration(seconds: 10));
      });
      var stage = 'video surface initialization';
      try {
        // VideoController waits for a post-frame callback before completing
        // initialization. Native commands wait for that controller in turn.
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
        stdout.writeln('${source.name}: $stage');
        await player.video!.platform.future.timeout(
          const Duration(seconds: 20),
        );
        await configureNativeDiagnostic(player);
        await player.pause().timeout(const Duration(seconds: 10));
        final native = player.video!.player.platform as NativePlayer;
        final version = await native
            .getProperty('mpv-version')
            .timeout(const Duration(seconds: 10));
        stdout.writeln('${source.name}: native player $version');
        stage = 'source match';
        stdout.writeln('${source.name}: $stage');
        final id = await source
            .match(media)
            .timeout(const Duration(seconds: 60));
        expect(id, isNotNull);
        stage = 'episode listing';
        stdout.writeln('${source.name}: $stage');
        final episodes = await source
            .episodesOf(id!)
            .timeout(const Duration(seconds: 60));
        final matching = episodes.where((e) => e.number == 1180);
        // AnimeStream is supplemental coverage, not one of the two sources in
        // the reported failure. An unavailable episode cannot test playback.
        if (matching.isEmpty && source is AnimeStream) {
          markTestSkipped(
            'AnimeStream returned ${episodes.length} episodes without 1180; '
            'no playback coverage for this source',
          );
          return;
        }
        expect(
          matching,
          isNotEmpty,
          reason:
              'Source returned ${episodes.length} episodes but no episode '
              '1180; playback was not attempted',
        );
        final episode = matching.first;
        stage = 'stream extraction';
        stdout.writeln('${source.name}: $stage');
        final streams = await source
            .streams(media, episode, dub: false)
            .timeout(const Duration(seconds: 90));
        expect(streams, isNotEmpty);

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
            stdout.writeln('${source.name}: $stage');
            final address = await StreamAddress.instance
                .forPlayer(stream)
                .timeout(const Duration(seconds: 45));
            stage = 'server ${index + 1}: native open at 10 seconds';
            stdout.writeln('${source.name}: $stage');
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
            // Include recovered playback in assertion output: a native startup
            // log alone does not prove decoding or the relay failed.
            final startupEvidence =
                'Playback reached ${player.state.position.inSeconds}s; '
                'duration=${player.state.duration.inSeconds}s; '
                'size=${player.state.size}; errors=$allErrors';
            stage = 'server ${index + 1}: seek';
            await player.seek(const Duration(seconds: 30));
            await until(
              () =>
                  player.state.position.inSeconds >= 32 &&
                  player.state.position.inSeconds < 45 &&
                  player.state.playing,
            );
            expect(
              startupErrors,
              isEmpty,
              reason:
                  'PlayerScreen would report a startup failure. '
                  '$startupEvidence; seek reached '
                  '${player.state.position.inSeconds}s',
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

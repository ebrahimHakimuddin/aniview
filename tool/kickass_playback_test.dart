// Opt-in Linux decoding check; requires ffprobe and ffmpeg on PATH.
import 'dart:convert';
import 'dart:io';

import 'package:aniview/sources.dart';
import 'package:aniview/stream_address.dart';
import 'package:flutter_test/flutter_test.dart';

String _safe(Object value) =>
    '$value'.replaceAll(RegExp(r'https?://[^\s\x27\x22]+'), '<stream URL>');

void main() {
  test('KickAssAnime Blue Box season 2 episode 2 reaches the decoder', () async {
    final source = KickAssAnime('KickAssAnime', 'https://kaa.lt');
    final show = await source.match({
      'title': {
        'english': 'Blue Box Season 2',
        'romaji': 'Ao no Hako Season 2',
      },
    });
    expect(show, isNotNull);
    final episodes = await source.episodesOf(show!);
    final episode = episodes.firstWhere((e) => e.number == 2);
    final streams = await source.streams(
      {},
      episode,
      dub: const bool.fromEnvironment('TEST_DUB'),
    );
    expect(streams, isNotEmpty);
    final stream = streams.first;
    stdout.writeln(
      'title=${episode.title}; HLS=${stream.isHls}; key length=${stream.key?.length}',
    );
    expect(stream.subtitles.where((s) => s.label == 'English'), isNotEmpty);
    final subtitle = await fetch(
      stream.subtitles.firstWhere((s) => s.label == 'English').url,
      headers: stream.headers,
    );
    expect(subtitle, contains('-->'));
    stdout.writeln('Subtitle tracks: ${stream.subtitles.length}');
    final address = await StreamAddress.instance.forPlayer(stream);
    stdout.writeln(
      'routed through localhost=${Uri.parse(address.url).host == '127.0.0.1'}',
    );
    final result = await Process.run('ffprobe', [
      '-v',
      'error',
      '-rw_timeout',
      '20000000',
      '-show_entries',
      'stream=codec_name,codec_type:stream_tags=language',
      '-of',
      'json',
      address.url,
    ]).timeout(const Duration(seconds: 90));
    stdout.writeln(_safe(result.stderr));
    expect(result.exitCode, 0, reason: _safe(result.stderr));
    final decoded = jsonDecode(result.stdout as String);
    expect(
      (decoded['streams'] as List).any((s) => s['codec_type'] == 'video'),
      isTrue,
    );
    expect(
      (decoded['streams'] as List).any((s) => s['codec_type'] == 'audio'),
      isTrue,
    );
    final audio = (decoded['streams'] as List).where(
      (s) => s['codec_type'] == 'audio',
    );
    expect(
      audio.map((s) => s['tags']?['language']),
      contains(const bool.fromEnvironment('TEST_DUB') ? 'eng' : 'jpn'),
    );
    final frames = await Process.run('ffmpeg', [
      '-v',
      'error',
      '-xerror',
      '-rw_timeout',
      '20000000',
      '-i',
      address.url,
      '-t',
      '1',
      '-map',
      '0:v:0',
      '-map',
      '0:a:0',
      '-f',
      'null',
      '-',
    ]).timeout(const Duration(seconds: 90));
    expect(frames.exitCode, 0, reason: _safe(frames.stderr));
    stdout.writeln('Decoded one second of video and audio successfully.');
  }, timeout: const Timeout(Duration(minutes: 3)));
}

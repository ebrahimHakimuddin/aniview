// Opt-in Linux decoding check; requires ffprobe and ffmpeg on PATH.
import 'dart:convert';
import 'dart:io';

import 'package:aniview/sources.dart';
import 'package:aniview/stream_address.dart';
import 'package:flutter_test/flutter_test.dart';

String _safe(Object value) =>
    '$value'.replaceAll(RegExp(r'https?://[^\s\x27\x22]+'), '<stream URL>');

void main() {
  test('AnimeStream Blue Box season 2 episode 2 reaches the decoder', () async {
    final source = AnimeStream('AnimeStream', 'https://anime.uniquestream.net');
    final hits = await source.search('Blue Box');
    final show = hits.firstWhere((s) => s.title.toLowerCase() == 'blue box');
    final series = jsonDecode(
      await fetch('${source.base}/api/v1/series/${show.id}'),
    );
    final season = (series['seasons'] as List).firstWhere(
      (s) => s['season_number'] == 2,
    );
    final episodes = await source.episodesOf(
      '${show.id}/${season['content_id']}',
    );
    final episode = seasonNumbered(episodes, {
      'episodes': 12,
    }).firstWhere((e) => e.number == 2);
    final streams = await source.streams({}, episode, dub: false);
    expect(streams, isNotEmpty);
    final stream = streams.first;
    stdout.writeln(
      'title=${episode.title}; HLS=${stream.isHls}; key length=${stream.key?.length}',
    );
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
      'stream=codec_name,codec_type',
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

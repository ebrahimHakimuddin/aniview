// Opt-in live decoder regression: fvm flutter test tool/playback_diagnostic_test.dart
// Requires ffprobe and ffmpeg. Samples Blue Box season 2, episode 2 on both sites.
import 'dart:convert';
import 'dart:io';

import 'package:aniview/hls_proxy.dart';
import 'package:aniview/platform.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/stream_address.dart';
import 'package:flutter_test/flutter_test.dart';

String safe(Object value) =>
    '$value'.replaceAll(RegExp(r'https?://[^\s]+'), '<stream URL>');

void main() {
  for (final source in [
    AniPm('ani.pm', 'https://ani.pm'),
    AnimeStream('AnimeStream', 'https://anime.uniquestream.net'),
  ]) {
    test('${source.name}: Blue Box S2E2 audio, subtitles and quality', () async {
      isDesktop = true;
      final hits = await source.search('Blue Box');
      late String id;
      if (source is AnimeStream) {
        final show = hits.firstWhere(
          (h) => h.title.toLowerCase() == 'blue box',
        );
        final series = jsonDecode(
          await fetch('${source.base}/api/v1/series/${show.id}'),
        );
        final season = (series['seasons'] as List).firstWhere(
          (s) => s['season_number'] == 2,
        );
        id = '${show.id}/${season['content_id']}';
      } else {
        id = hits.firstWhere((h) => h.title == 'Blue Box Season 2').id;
      }
      final episodes = await source.episodesOf(id);
      final episode = seasonNumbered(episodes, {
        'episodes': 12,
      }).firstWhere((e) => e.number == 2);
      final stream = (await source.streams({}, episode, dub: false)).first;
      final address = await StreamAddress.instance.forPlayer(stream);
      final heights = await HlsProxy.configureQuality(address.url, 0);
      expect(heights, contains(720));
      stdout.writeln('${source.name}: resolutions=$heights');

      final probe = await Process.run('ffprobe', [
        '-v',
        'error',
        '-rw_timeout',
        '15000000',
        '-show_entries',
        'stream=codec_name,codec_type,width,height',
        '-of',
        'json',
        address.url,
      ]).timeout(const Duration(seconds: 90));
      expect(probe.exitCode, 0, reason: safe(probe.stderr));
      final tracks = jsonDecode(probe.stdout as String)['streams'] as List;
      expect(tracks.any((s) => s['codec_type'] == 'audio'), isTrue);
      expect(
        tracks.any(
          (s) => s['codec_type'] == 'video' && s['height'] == heights.first,
        ),
        isTrue,
      );

      if (source is AnimeStream) {
        final english = address.subtitles.firstWhere(
          (s) => s.label == 'English',
        );
        final captions = await Process.run('ffprobe', [
          '-v',
          'error',
          '-count_packets',
          '-show_entries',
          'stream=nb_read_packets',
          '-of',
          'csv=p=0',
          english.url,
        ]).timeout(const Duration(seconds: 30));
        expect(captions.exitCode, 0, reason: safe(captions.stderr));
        final count = int.tryParse((captions.stdout as String).trim());
        expect(
          count,
          greaterThan(0),
          reason: 'The player must receive subtitle cues',
        );
        stdout.writeln('${source.name}: English subtitle cues=$count');
      }

      final decoded = await Process.run('ffmpeg', [
        '-v',
        'info',
        '-rw_timeout',
        '15000000',
        '-ss',
        '14',
        '-i',
        address.url,
        '-t',
        '2',
        '-map',
        '0:v:0',
        '-map',
        '0:a:0',
        '-af',
        'volumedetect',
        '-f',
        'null',
        '-',
      ]).timeout(const Duration(seconds: 90));
      expect(decoded.exitCode, 0, reason: safe(decoded.stderr));
      final volume = RegExp(r'max_volume: (-?[\d.]+) dB')
          .firstMatch(decoded.stderr as String);
      expect(
        volume,
        isNotNull,
        reason: 'Audio must decode to non-silent samples',
      );
      stdout.writeln(
        '${source.name}: decoded video and audible audio (peak ${volume![1]} dB)',
      );
    }, timeout: const Timeout(Duration(minutes: 4)));
  }
}

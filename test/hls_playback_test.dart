import 'dart:io';

import 'package:aniview/hls_proxy.dart';
import 'package:aniview/platform.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/subtitles.dart';
import 'package:flutter_test/flutter_test.dart';

const master =
    '#EXTM3U\n'
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",DEFAULT=YES,URI="audio"\n'
    '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",URI="subtitles"\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=9000000,RESOLUTION=1920x1080,AUDIO="a",SUBTITLES="s"\nhigh\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720,AUDIO="a",SUBTITLES="s"\nlow\n';

void main() {
  test(
    'desktop relay applies quality and preserves subtitle routing end to end',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final desktop = isDesktop;
      isDesktop = true;
      addTearDown(() async {
        isDesktop = desktop;
        await server.close(force: true);
      });
      server.listen((request) async {
        request.response.write(switch (request.uri.path) {
          '/master' => master,
          '/subtitles' => '#EXTM3U\n#EXTINF:20,\ncue\n',
          '/cue' => 'WEBVTT\n\n  \n\n00:00:01.000 --> 00:00:02.000\nHello.\n',
          _ => '',
        });
        await request.response.close();
      });
      final root = await HlsProxy.url(
        'http://127.0.0.1:${server.port}/master',
        {},
      );
      expect(await HlsProxy.configureQuality(root, 720), [1080, 720]);
      final capped = await fetch(root);
      expect(playlistHeights(capped), [720]);
      expect(capped, contains('TYPE=AUDIO'));
      final subLine = capped
          .split('\n')
          .firstWhere((l) => l.contains('TYPE=SUBTITLES'));
      final subUrl = RegExp(r'URI="([^"]+)"').firstMatch(subLine)![1]!;
      final subPlaylist = await fetch(subUrl);
      final cueUrl = subPlaylist
          .split('\n')
          .firstWhere((l) => l.startsWith('http'));
      expect(Uri.parse(cueUrl).path, endsWith('.vtt'));
      expect(await fetch(cueUrl), isNot(contains('\n  \n')));
      await HlsProxy.configureQuality(root, 0);
      expect(playlistHeights(await fetch(root)), [1080]);
      expect(await HlsProxy.configureQuality('/local/video.mp4', 720), isEmpty);
    },
  );
  test('normalizes padded WebVTT separators without changing cues', () {
    const input =
        'WEBVTT\n\nNOTE SegmentIndex\nNOTE metadata\n\n   \n\n1\n00:00:14.514 --> 00:00:15.932\nHello.\n';
    final normalized = normalizeWebVtt(input);
    expect(normalized, isNot(contains('\n   \n')));
    expect(parseCues(normalized, 'vtt'), parseCues(input, 'vtt'));
    expect(
      normalizeWebVtt('WEBVTT\r\n \t\r\nHello world'),
      'WEBVTT\r\n\nHello world',
    );
  });
  test(
    'reports every selectable height and preserves audio at a quality cap',
    () {
      expect(playlistHeights(master), [1080, 720]);
      final capped = oneVariant(master, maxHeight: 720);
      expect(capped, contains('\nlow\n'));
      expect(capped, isNot(contains('\nhigh\n')));
      expect(capped, contains('TYPE=AUDIO'));
      expect(capped, contains('TYPE=SUBTITLES'));
      expect(oneVariant(master), contains('\nhigh\n'));
      expect(oneVariant(master, maxHeight: 480), contains('\nlow\n'));
      expect(playlistHeights('#EXTM3U\n#EXTINF:5,\nsegment.ts'), isEmpty);
    },
  );
  test('subtitle media segments retain vtt extension', () {
    expect(
      rewritePlaylist(
        '#EXTM3U\n#EXTINF:5,\nopaque-id\n',
        Uri.parse('https://cdn.test/subs'),
        (url, ext) => '$url.$ext',
        segmentExt: 'vtt',
      ),
      contains('https://cdn.test/opaque-id.vtt'),
    );
  });
  test(
    'subtitle renditions keep WebVTT segment extensions through the relay',
    () {
      final rewritten = rewritePlaylist(
        master,
        Uri.parse('https://cdn.test/master'),
        (url, ext) => '$url.$ext',
      );
      expect(rewritten, contains('URI="https://cdn.test/subtitles.vtt.m3u8"'));
    },
  );
}

import 'dart:typed_data';

import 'package:aniview/sources.dart';
import 'package:aniview/stream_address.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers each request with a readable tag instead of a localhost address.
class FakeRelay implements Relay {
  @override
  Future<String> remote(
    String url,
    Map<String, String> headers,
    String ext, {
    Uint8List? key,
  }) async =>
      'relay:$ext:$url:${headers['Referer']}${key == null ? '' : ':key${key.length}'}';

  @override
  Future<String> localFile(String dir, String file) async => 'local:$dir:$file';

  @override
  Future<String> documentFile(String tree, String id, String file) async =>
      'doc:$tree:$id:$file';
}

void main() {
  final address = StreamAddress(FakeRelay());
  const headers = {'Referer': 'https://site'};
  const tree = 'content://tree/primary:Anime';
  final saf = DocumentFolder(tree, '7-1-sub');
  const dir = LocalFolder('/data/downloads/7-1-sub');

  VideoStream stream(String url, [List<Subtitle> subtitles = const []]) =>
      VideoStream('s', url, headers, subtitles: subtitles);

  // stream, expected for our own player, expected for another app
  final cases = <(String, VideoStream, PlayableAddress, PlayableAddress)>[
    (
      'saf document',
      stream(saf.urlOf('index.m3u8'), [
        Subtitle('English', saf.urlOf('sub0.vtt')),
      ]),
      PlayableAddress('doc:$tree:7-1-sub:index.m3u8', hls: true),
      PlayableAddress('doc:$tree:7-1-sub:index.m3u8', hls: true),
    ),
    (
      'local file',
      stream(dir.urlOf('index.m3u8'), [
        Subtitle('English', dir.urlOf('sub0.vtt')),
      ]),
      PlayableAddress('/data/downloads/7-1-sub/index.m3u8', hls: true),
      PlayableAddress('local:/data/downloads/7-1-sub:index.m3u8', hls: true),
    ),
    (
      'remote HLS',
      stream('https://cdn/a/master.m3u8', [
        Subtitle('English', 'https://cdn/en.vtt'),
      ]),
      PlayableAddress(
        'relay:m3u8:https://cdn/a/master.m3u8:https://site',
        hls: true,
      ),
      PlayableAddress(
        'relay:m3u8:https://cdn/a/master.m3u8:https://site',
        hls: true,
      ),
    ),
    (
      'mp4 keeps its headers',
      stream('https://cdn/a/video.mp4', [
        Subtitle('English', 'https://cdn/en.ass'),
      ]),
      PlayableAddress('https://cdn/a/video.mp4', headers: headers),
      PlayableAddress('https://cdn/a/video.mp4', headers: headers),
    ),
  ];
  // Each stream's one subtitle, as each side addresses it.
  const subtitles = {
    'saf document': (
      'doc:$tree:7-1-sub:sub0.vtt',
      'doc:$tree:7-1-sub:sub0.vtt',
    ),
    'local file': (
      '/data/downloads/7-1-sub/sub0.vtt',
      'local:/data/downloads/7-1-sub:sub0.vtt',
    ),
    'remote HLS': (
      'relay:vtt:https://cdn/en.vtt:https://site',
      'relay:vtt:https://cdn/en.vtt:https://site',
    ),
    'mp4 keeps its headers': (
      'relay:ass:https://cdn/en.ass:https://site',
      'relay:ass:https://cdn/en.ass:https://site',
    ),
  };

  for (final (name, input, player, external) in cases) {
    for (final (who, expected, run) in [
      ('player', player, address.forPlayer),
      ('external app', external, address.forExternalApp),
    ]) {
      test('$name for the $who', () async {
        final got = await run(input);
        expect(got.url, expected.url);
        expect(got.headers, expected.headers);
        expect(got.hls, expected.hls);
        final (forPlayer, forExternal) = subtitles[name]!;
        expect(
          [for (final s in got.subtitles) (s.label, s.url)],
          [('English', who == 'player' ? forPlayer : forExternal)],
        );
      });
    }
  }

  test('a stream\'s own key goes to its playlist, not its subtitles', () async {
    final got = await address.forPlayer(
      VideoStream(
        's',
        'https://cdn/a/master.m3u8',
        headers,
        key: Uint8List(16),
        subtitles: [Subtitle('English', 'https://cdn/en.vtt')],
      ),
    );
    expect(got.url, 'relay:m3u8:https://cdn/a/master.m3u8:https://site:key16');
    expect(
      got.subtitles.single.url,
      'relay:vtt:https://cdn/en.vtt:https://site',
    );
  });

  group('DownloadLocation', () {
    test('a document address round-trips, tree and all', () {
      final url = saf.urlOf('index.m3u8');
      expect(url, startsWith('saf://'));
      expect(url, isNot(contains('content://')));
      final (location, file) = DownloadLocation.parse(url)!;
      expect(file, 'index.m3u8');
      expect(location, isA<DocumentFolder>());
      expect((location as DocumentFolder).tree, tree);
      expect(location.id, '7-1-sub');
    });

    test(
      'a path parses to its folder and file; a remote address to nothing',
      () {
        final (location, file) = DownloadLocation.parse('/a/b/index.m3u8')!;
        expect((location as LocalFolder).path, '/a/b');
        expect(file, 'index.m3u8');
        expect(DownloadLocation.parse('https://cdn/x.m3u8'), isNull);
      },
    );
  });
}

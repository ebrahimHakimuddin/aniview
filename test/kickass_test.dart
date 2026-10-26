import 'dart:convert';

import 'package:aniview/sources.dart';
import 'package:aniview/hls_proxy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

void main() {
  final original = httpClient;
  tearDown(() => httpClient = original);

  test('requested HLS language survives desktop quality selection', () {
    const master =
        '#EXTM3U\n'
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Japanese",LANGUAGE="jpn",DEFAULT=YES,URI="ja.m3u8"\n'
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="English",LANGUAGE="eng",URI="en.m3u8"\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=100,RESOLUTION=1280x720,AUDIO="a"\nvideo.m3u8\n';
    final selected = selectPlaylistAudio(master, 'eng');
    expect(selected, contains('en.m3u8'));
    expect(selected, isNot(contains('ja.m3u8')));
    expect(oneVariant(selected), contains('en.m3u8'));
    expect(selectPlaylistAudio(master, null), master);
    expect(() => selectPlaylistAudio(master, 'fra'), throwsFormatException);
  });

  test('ranked KickAssAnime is supported, including the old domain', () {
    for (final host in ['kaa.lt', 'kaa.to']) {
      final sites = sourcesFromRanking(['KickAssAnime|https://$host']);
      expect(sites.first, isA<KickAssAnime>());
      expect(sites.first.base, 'https://kaa.lt');
    }
  });

  test('search uses POST and matches an exact season alias', () async {
    httpClient = MockClient((request) async {
      expect(request.method, 'POST');
      expect(jsonDecode(request.body)['query'], 'Blue Box Season 2');
      return http.Response(
        jsonEncode([
          {'slug': 's1', 'title': 'Ao no Hako', 'title_en': 'Blue Box'},
          {
            'slug': 's2',
            'title': 'Ao no Hako Season 2',
            'title_en': 'Blue Box Season 2',
          },
        ]),
        200,
      );
    });
    final source = KickAssAnime('KickAssAnime', 'https://kaa.test');
    expect((await source.search('Blue Box Season 2')).last.id, 's2');
    expect(
      await source.match({
        'title': {'english': 'Blue Box Season 2'},
      }),
      's2',
    );
  });

  test('does not guess between ambiguous titles', () async {
    httpClient = MockClient(
      (_) async => http.Response(
        jsonEncode([
          {'slug': 'a', 'title': 'Same'},
          {'slug': 'b', 'title': 'Same'},
        ]),
        200,
      ),
    );
    expect(
      await KickAssAnime('KAA', 'https://kaa.test').match({
        'title': {'romaji': 'Same'},
      }),
      isNull,
    );
  });

  String page(List<int> numbers, String suffix) => jsonEncode({
    'pages': [
      {'number': 1},
      {'number': 2},
    ],
    'result': [
      for (final n in numbers)
        {'episode_number': n, 'episode_string': '$n', 'slug': '$suffix$n'},
    ],
  });
  String detail(String language) => jsonEncode({
    'language': language,
    'servers': [
      {'name': 'Broken', 'src': 'https://player.test/broken'},
      {'name': 'VidStreaming', 'src': 'https://player.test/watch'},
    ],
  });
  final props = jsonEncode({
    'manifest': [0, '/master.m3u8'],
    'title': [0],
    'subtitles': [
      1,
      [
        [
          0,
          {
            'name': [0, 'English'],
            'src': [0, '/en.vtt'],
          },
        ],
      ],
    ],
  }).replaceAll('"', '&quot;');

  test(
    'paginates, round-trips refs, resolves dub and preserves HLS/subtitles',
    () async {
      final net = FakeNet({
        'lang=ja-JP&page=1': page([2], 'ja'),
        'lang=ja-JP&page=2': page([1], 'ja'),
        'lang=en-US&page=1': page([2], 'en'),
        'lang=en-US&page=2': page([1], 'en'),
        '/episode/ep-2-en2': detail('en-US'),
        '/episode/ep-2-ja2': detail('ja-JP'),
        '/watch': '<astro-island props="$props">',
      });
      final source = KickAssAnime('KAA', 'https://kaa.test', net: net);
      final episodes = await source.episodesOf('show');
      expect(episodes.map((e) => e.number), [1, 2]);
      final episode = Episode.fromJson(
        jsonDecode(jsonEncode(episodes.last.toJson())),
      );
      for (final dub in [false, true]) {
        final stream = (await source.streams({}, episode, dub: dub)).single;
        expect(stream.isHls, isTrue);
        expect(stream.audioLanguage, dub ? 'eng' : 'jpn');
        expect(stream.url, 'https://player.test/master.m3u8');
        expect(stream.headers['Referer'], 'https://player.test/');
        expect(stream.subtitles.single.url, 'https://player.test/en.vtt');
        expect(stream.subtitles.single.label, 'English');
      }
      expect(
        net.requests.any((url) => url.endsWith('/episode/ep-2-en2')),
        isTrue,
      );
    },
  );

  test(
    'missing dub returns no stream instead of silently playing Japanese',
    () async {
      final source = KickAssAnime(
        'KAA',
        'https://kaa.test',
        net: FakeNet({'lang=en-US': '{"pages": [], "result": []}'}),
      );
      expect(
        await source.streams(
          {},
          Episode(
            2,
            ref: {
              'show': 'show',
              'episode': 'ep-2-ja',
              'language': 'ja-JP',
              'number': 2,
            },
          ),
          dub: true,
        ),
        isEmpty,
      );
    },
  );
}

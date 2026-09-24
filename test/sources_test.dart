import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aniview/downloads.dart';
import 'package:aniview/hls_proxy.dart';
import 'package:aniview/sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../tool/top_sites.dart';

void main() {
  test('loads the top sites once, and afresh after a failed load', () async {
    var loads = 0;
    Sites.load = () async {
      if (++loads == 1) throw const SocketException('offline');
      return [ReAnime('Re:Anime', 'https://re.test')];
    };
    await expectLater(Sites.all(), throwsA(isA<SocketException>()));
    expect((await Sites.named('Re:Anime'))?.name, 'Re:Anime');
    expect(await Sites.named('Gone'), isNull);
    expect(identical(Sites.all(), Sites.all()), isTrue);
    expect(loads, 2);
  });

  test('reads the top anime sites from everythingmoe markup', () {
    const html =
        '<div id="sec-anime" class="section"><div class="section-notes">x</div>'
        '<div data-rank="1" data-filter="Scraper" class="section-item"><span style="color:#ffc844;">1.</span> <a href="/s/anikoto" '
        'data-link="https://anikototv.to/home"><img src="a.png" alt=""> Anikoto</a></div>'
        '<div data-rank="2" data-filter="Hard-sub" class="section-item"><span style="color:#d8ba76;">2.</span> <a href="/s/animepahe" '
        'data-link="https://animepahe.pw"><img src="b.png" alt=""> animepahe</a></div>'
        '<div data-rank="3" class="section-item">3. <a href="/s/reanime" data-link="https://reanime.to/home">'
        '<img src="c.png" alt=""> Re:Anime</a></div>'
        '<div data-rank="4" class="section-item">4. <a href="/s/x" data-link="https://x.to"> X</a></div></div>'
        '<div id="sec-donghua"><div data-rank="1" class="section-item">1. <a href="/s/d" data-link="https://d.to"> D</a>';
    expect(parseTopSites(html), [
      ('Anikoto', 'https://anikototv.to'),
      ('animepahe', 'https://animepahe.pw'),
      ('Re:Anime', 'https://reanime.to'),
      ('X', 'https://x.to'),
    ]);
  });

  test('unpacks p.a.c.k.e.r scripts', () {
    const packed =
        r"eval(function(p,a,c,k,e,d){}('0 1=\'2://3.4/5.6\'',62,7,"
        r"'const|source|https|cdn|example|video|m3u8'.split('|'),0,{}))";
    expect(unpack(packed), "const source='https://cdn.example/video.m3u8'");
  });

  // Captured from megaplay.buzz getSourcesNew; the same decryption its player runs.
  test('decrypts megaplay sources', () {
    expect(
      decodeMegaplaySource(
        'wdeBruh3qqn_i5wUNnyaPcXqidp1UWP84FfPHzGyKXAz4mAVkH6j3DueswO2yXLWn8H-XMHNvbAo5Gsg7zIcFBuQI_zsUvMGI1gKwQsPTSHQHiF55R4BopgEQ-7jebQQ4C0Gu7YhaMucopp6d3Q8yAY9b5GdsSvPGq6CUn7SHyc',
      ),
      {
        'file': 'https://fetch.nexabloom.top/anime/bb6d2babd7797d94d8f4a8600bc9b44e/b7d51fb7e838ee9b60dcdb34b953bc07/master.m3u8',
      },
    );
  });

  test('the proxy serves only the addresses it gave out', () async {
    final dir = await Directory.systemTemp.createTemp();
    addTearDown(() => dir.delete(recursive: true));
    await File('${dir.path}/index.m3u8').writeAsString('#EXTM3U');
    final given = Uri.parse(await HlsProxy.localFile(dir.path, 'index.m3u8'));
    final guessed = given.replace(
      pathSegments: given.pathSegments.skip(1), // the same file, no token
    );
    Future<int> status(Uri uri) async {
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(uri)).close();
        await response.drain<void>();
        return response.statusCode;
      } finally {
        client.close();
      }
    }

    expect(await status(given), 200);
    expect(await status(guessed), 403);
  });

  test('rewrites HLS playlists through the proxy', () {
    String proxy(String url, String ext) => 'P($url).$ext';
    final base = Uri.parse('https://cdn.test/a/master.m3u8');
    expect(
      rewritePlaylist(
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nindex.m3u8\n',
        base,
        proxy,
      ),
      '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nP(https://cdn.test/a/index.m3u8).m3u8\n',
    );
    expect(
      rewritePlaylist(
        '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="k.key"\n#EXTINF:10,\nhttps://img.test/x.image?s=1\n',
        base,
        proxy,
      ),
      '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="P(https://cdn.test/a/k.key).ts"\n#EXTINF:10,\n'
      'P(https://img.test/x.image?s=1).ts\n',
    );
  });

  test('strips fake image headers in front of MPEG-TS segments', () {
    final ts = Uint8List(188 * 4)
      ..[0] = 0x47
      ..[188] = 0x47
      ..[376] = 0x47
      ..[564] = 0x47;
    expect(
      stripToTs(Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 1, 2, 3, ...ts])),
      ts,
    );
    expect(stripToTs(Uint8List.fromList([1, 2, 3])), [1, 2, 3]);
  });

  test('picks the best variant and rewrites a media playlist to local files', () {
    const master =
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nlow/index.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=2400000\nhigh/index.m3u8\n#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=90000,URI="i.m3u8"\n';
    expect(bestVariant(master), 'high/index.m3u8');

    const sized =
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080\n1080.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720\n720.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=854x480\n480.m3u8\n';
    expect(bestVariant(sized), '1080.m3u8');
    expect(bestVariant(sized, maxHeight: 720), '720.m3u8');
    // Nothing fits: the smallest.
    expect(bestVariant(sized, maxHeight: 360), '480.m3u8');

    final (local, files, length) = localizePlaylist(
      '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="/k/1.key"\n#EXTINF:4.5,\nseg1.ts\n'
      '#EXTINF:5.5,\nhttps://img.test/x.image?sig=1\n#EXT-X-ENDLIST\n',
      Uri.parse('https://cdn.test/a/index.m3u8'),
    );
    expect(
      local,
      '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key0.bin"\n#EXTINF:4.5,\nseg00000.ts\n'
      '#EXTINF:5.5,\nseg00001.ts\n#EXT-X-ENDLIST\n',
    );
    expect(files, {
      'key0.bin': Uri.parse('https://cdn.test/k/1.key'),
      'seg00000.ts': Uri.parse('https://cdn.test/a/seg1.ts'),
      'seg00001.ts': Uri.parse('https://img.test/x.image?sig=1'),
    });
    expect(length, const Duration(seconds: 10));
  });

  // The offline season cache stores episodes as JSON; nested refs (Anikoto's data attributes) must survive the round trip.
  test('episodes round-trip through JSON', () {
    const episode = Episode(
      5.5,
      title: 'T',
      overview: 'O',
      ref: {
        'sub': {'p': 'id'},
      },
    );
    final back = Episode.fromJson(jsonDecode(jsonEncode([episode]))[0]);
    expect(
      [back.number, back.title, back.thumbnail, back.overview, back.ref],
      [5.5, 'T', null, 'O', episode.ref],
    );
  });

  group('site adapters read their pages', () {
    /// Answers each request with the snapshot whose key its URL contains.
    void serve(Map<String, String> pages) =>
        httpClient = MockClient((request) async {
          final url = '${request.url}';
          for (final MapEntry(:key, :value) in pages.entries) {
            if (url.contains(key)) return http.Response(value, 200);
          }
          return http.Response('', 404);
        });

    test('Anikoto: search results, and a match only on the right MAL id', () async {
      String item(String href, String title, String mal) =>
          '<div class="item "><img src="https://img.test/$mal.jpg">'
          '<a class="name d-title" href="$href" data-jp="x">$title</a>'
          '<div class="right">TV</div></div>';
      String list(String mal) => jsonEncode({
        'result':
            '<ul><a href="#" data-num="1" data-ids="ids-$mal-1" data-mal="$mal">1</a>'
            '<a href="#" data-num="2" data-ids="ids-$mal-2" data-mal="$mal">2</a></ul>',
      });
      serve({
        '/filter?keyword=':
            item('https://ak.test/watch/other', 'Other &amp; Co', '1') +
            item('https://ak.test/watch/right', 'Right', '5114'),
        '/watch/other': '<div id="watch-main" class="w" data-id="10">',
        '/watch/right': '<div id="watch-main" class="w" data-id="20">',
        '/episode/list/10': list('1'),
        '/episode/list/20': list('5114'),
      });
      final site = Anikoto('Anikoto', 'https://ak.test');

      final results = await site.search('x');
      expect(
        [for (final r in results) (r.id, r.title, r.info)],
        [
          ('https://ak.test/watch/other', 'Other & Co', 'TV'),
          ('https://ak.test/watch/right', 'Right', 'TV'),
        ],
      );
      final media = {
        'id': 1,
        'idMal': 5114,
        'title': {'romaji': 'Right'},
      };
      expect(await site.match(media), 'https://ak.test/watch/right');
      final episodes = await site.episodesOf('https://ak.test/watch/right');
      expect([for (final e in episodes) e.number], [1, 2]);
      expect((episodes.first.ref as Map)['ids'], 'ids-5114-1');
    });

    test('Re:ANIME: matches by AniList id and drops empty titles', () async {
      serve({
        '/api/v1/search': jsonEncode({
          'results': [
            {
              'anime_id': 7,
              'anilist_id': 99,
              'title': {'romaji': 'Wrong'},
            },
            {
              'anime_id': 8,
              'anilist_id': 21,
              'title': {'english': 'One Piece'},
              'format': 'TV',
              'episodes': 1100,
            },
          ],
        }),
        '/api/v1/anime/8/episodes': jsonEncode({
          'data': [
            {'episode_number': 1, 'title': 'Romance Dawn', 'thumbnail': ''},
            {'episode_number': 2, 'title': ''},
          ],
        }),
      });
      final site = ReAnime('Re:Anime', 'https://re.test');

      final id = await site.match({
        'id': 21,
        'title': {'romaji': 'One Piece'},
      });
      expect(id, '8|21');
      expect((await site.search('x')).last.info, 'TV · 1100 eps');
      final episodes = await site.episodesOf(id!);
      expect(
        [for (final e in episodes) (e.number, e.title, e.thumbnail, e.ref)],
        [(1, 'Romance Dawn', null, '21'), (2, null, null, '21')],
      );
    });

    test('a redesigned page gives no episodes rather than failing', () async {
      serve({'/watch/x': '<html>redesigned</html>'});
      final site = Anikoto('Anikoto', 'https://ak.test');
      expect(await site.episodesOf('https://ak.test/watch/x'), isEmpty);
    });
  });
}

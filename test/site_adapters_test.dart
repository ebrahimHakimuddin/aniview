import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aniview/cloudflare.dart';
import 'package:aniview/metadata.dart';
import 'package:aniview/sources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

// Captured from megaplay.buzz getSourcesNew (see sources_test.dart): decrypts to a file of this master playlist.
const _enc =
    'wdeBruh3qqn_i5wUNnyaPcXqidp1UWP84FfPHzGyKXAz4mAVkH6j3DueswO2yXLWn8H-XMHNvbAo5Gsg7zIcFBuQI_zsUvMGI1gKwQsPTSHQHiF55R4BopgEQ-7jebQQ4C0Gu7YhaMucopp6d3Q8yAY9b5GdsSvPGq6CUn7SHyc';

const _packed =
    r"eval(function(p,a,c,k,e,d){}('0 1=\'2://3.4/5.6\'',62,7,"
    r"'const|source|https|cdn|example|video|m3u8'.split('|'),0,{}))";

void main() {
  group('AnimePahe', () {
    String episodes(int page, List<(int, String)> list) => jsonEncode({
      'last_page': 2,
      'data': [
        for (final (n, session) in list) {'episode': n, 'session': session},
      ],
    });

    test('renumbers a later season from 1, across pages', () async {
      final site = AnimePahe(
        'animepahe',
        'https://pahe.test',
        cleared: FakeNet({
          'page=1': episodes(1, [(13, 's13'), (14, 's14')]),
          'page=2': episodes(2, [(15, 's15')]),
        }),
      );
      final list = await site.episodesOf('show');
      expect(
        [for (final e in list) (e.number, e.ref)],
        [(1, 'show/s13'), (2, 'show/s14'), (3, 'show/s15')],
      );
    });

    test('streams are the buttons of the audio asked for, best resolution first', () async {
      String button(String src, String audio, int res) =>
          '<button data-src="$src" data-audio="$audio" data-resolution="$res" data-fansub="Fan">x</button>';
      final site = AnimePahe(
        'animepahe',
        'https://pahe.test',
        cleared: FakeNet({
          '/play/': [
            button('https://kwik.test/e/low', 'jpn', 360),
            button('https://kwik.test/e/high', 'jpn', 1080),
            button('https://kwik.test/e/mid', 'jpn', 720),
            button('https://kwik.test/e/gone', 'jpn', 480),
            button('https://kwik.test/e/dubbed', 'eng', 720),
          ].join(),
        }),
        net: FakeNet({
          '/e/low': "var s='https://cdn.test/360/index.m3u8'",
          '/e/high': "var s='https://cdn.test/1080/index.m3u8'",
          '/e/mid': _packed, // packed, as kwik serves it
          '/e/dubbed': "var s='https://cdn.test/dub/index.m3u8'",
        }),
      );
      final episode = Episode(1, ref: 'show/s1');

      final sub = await site.streams({}, episode, dub: false);
      // The page that doesn't load is left out.
      expect(
        [for (final s in sub) (s.label, s.url)],
        [
          ('Fan 1080p', 'https://cdn.test/1080/index.m3u8'),
          ('Fan 720p', 'https://cdn.example/video.m3u8'),
          ('Fan 360p', 'https://cdn.test/360/index.m3u8'),
        ],
      );
      expect(sub.first.headers['Referer'], 'https://kwik.test/');

      final dub = await site.streams({}, episode, dub: true);
      expect(dub.single.url, 'https://cdn.test/dub/index.m3u8');
    });

    test(
      'matches a search result whose page links the show\'s AniList id',
      () async {
        final site = AnimePahe(
          'animepahe',
          'https://pahe.test',
          cleared: FakeNet({
            'm=search': jsonEncode({
              'data': [
                {'session': 'other', 'title': 'Other'},
                {'session': 'right', 'title': 'Right', 'episodes': 12},
              ],
            }),
            '/anime/other': '<a href="https://anilist.co/anime/99">',
            '/anime/right': '<a href="https://anilist.co/anime/7">',
          }),
        );
        expect(
          await site.match({
            'id': 7,
            'title': {'romaji': 'Right'},
          }),
          'right',
        );
      },
    );
  });

  group('megaplay', () {
    String sources({Object? outro}) => jsonEncode({
      'enc': _enc,
      'tracks': [
        {
          'kind': 'captions',
          'label': 'English',
          'file': 'https://s.test/en.vtt',
        },
        {'kind': 'thumbnails', 'file': 'https://s.test/thumbs.vtt'},
      ],
      'intro': {'start': 5, 'end': 90},
      'outro': outro ?? {'start': 0, 'end': 0},
    });

    test('gives the HLS stream with its subtitles and skip times', () async {
      final net = FakeNet({
        '/embed': '<div data-id="42"></div>',
        'getSourcesNew?id=42&s=tcdn': sources(),
        'master.m3u8': '#EXTM3U',
      });
      final streams = await megaplay(
        'HD-1',
        'https://mp.test/embed?s=tcdn',
        referer: 'https://site.test/',
        net: net,
      );
      final stream = streams.single;
      expect(stream.label, 'HD-1');
      expect(stream.url, endsWith('/master.m3u8'));
      expect(stream.headers['Referer'], 'https://mp.test/');
      expect(stream.subtitles.single.label, 'English');
      // A range ending at 0 is no skip.
      expect(
        [for (final k in stream.skips) (k.type, k.end)],
        [(SkipType.intro, const Duration(seconds: 90))],
      );
    });

    test(
      'gives nothing when the page has no id, or the CDN turns the stream away',
      () async {
        expect(
          await megaplay(
            'HD-1',
            'https://mp.test/embed',
            referer: '',
            net: FakeNet({'/embed': 'redesigned'}),
          ),
          isEmpty,
        );
        expect(
          await megaplay(
            'HD-1',
            'https://mp.test/embed',
            referer: '',
            net: FakeNet({
              '/embed': '<div data-id="42"></div>',
              'getSourcesNew': sources(),
              // no master.m3u8: a 404 from the CDN
            }),
          ),
          isEmpty,
        );
      },
    );

    test('Re:ANIME asks both servers by the show\'s AniList id', () async {
      final net = FakeNet({
        'ani/21/3/dub?s=tcdn': '<div data-id="42"></div>',
        'ani/21/3/dub?s=bcdn': '<div data-id="43"></div>',
        'getSourcesNew?id=42': sources(),
        'master.m3u8': '#EXTM3U',
      });
      final streams = await ReAnime(
        'Re:Anime',
        'https://re.test',
        net: net,
      ).streams({'id': 21}, const Episode(3, ref: '21'), dub: true);
      // HD-2's page has no sources to give: it drops out, HD-1 stays.
      expect(streams.map((s) => s.label), ['HD-1']);
    });
  });

  group('CloudflareNet', () {
    test('asks once when the clearance is good', () async {
      final asked = <String>[];
      final net = CloudflareNet(
        request: (uri, headers) async {
          asked.add('$uri');
          return (200, Uint8List.fromList(utf8.encode('hello')));
        },
        verify: (_) async => fail('no check was due'),
      );
      expect(await net.text('https://pahe.test/api?m=x'), 'hello');
      expect(asked, ['https://pahe.test/api?m=x']);
    });

    test(
      'opens the site in the browser once, then asks again, when refused',
      () async {
        final statuses = [403, 200];
        final verified = <String>[];
        final net = CloudflareNet(
          request: (_, _) async => (statuses.removeAt(0), Uint8List(0)),
          verify: (origin) async => verified.add(origin),
        );
        await net.bytes('https://pahe.test/anime/x');
        expect(verified, ['https://pahe.test/']);
      },
    );

    test(
      'gives up with the status when the browser doesn\'t clear it',
      () async {
        var verified = 0;
        final net = CloudflareNet(
          request: (_, _) async => (503, Uint8List(0)),
          verify: (_) async => verified++,
        );
        await expectLater(
          net.text('https://pahe.test/x'),
          throwsA(isA<HttpException>()),
        );
        expect(verified, 1);
      },
    );

    test('lets the browser\'s Cloudflare challenge through', () async {
      final net = CloudflareNet(
        request: (_, _) async => (403, Uint8List(0)),
        verify: (origin) async => throw CloudflareChallenge(origin),
      );
      await expectLater(
        net.text('https://pahe.test/x'),
        throwsA(isA<CloudflareChallenge>()),
      );
    });
  });
}

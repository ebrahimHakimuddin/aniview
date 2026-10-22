import 'dart:convert';

import 'package:aniview/anilist.dart';
import 'package:aniview/jellyfin.dart';
import 'package:aniview/net.dart';
import 'package:aniview/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
  });

  Map episode(int season, int n) => {
    'Id': 's${season}e$n',
    'Name': 'S$season E$n',
    'ParentIndexNumber': season,
    'IndexNumber': n,
  };

  Jellyfin server(Map<String, Object> pages) => Jellyfin(
    server: 'http://jf.test/',
    token: 'tok',
    user: 'u',
    net: FakeNet({
      for (final MapEntry(:key, :value) in pages.entries)
        key: jsonEncode(value),
    }),
  );

  test(
    'a TVDB-ordered series is cut to the AniList season ani.zip names',
    () async {
      httpClient = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'mappings': {'thetvdb_id': 377543},
            'episodes': {
              '1': {'seasonNumber': 2, 'episodeNumber': 1},
            },
          }),
          200,
        ),
      );
      final jf = server({
        'IncludeItemTypes': {
          'Items': [
            {
              'Id': 'other',
              'Type': 'Series',
              'Name': 'Other',
              'ProviderIds': {'Tvdb': '1'},
            },
            {
              'Id': 'jjk',
              'Type': 'Series',
              'Name': 'JJK',
              'ProviderIds': {'Tvdb': '377543'},
            },
          ],
        },
        '/Shows/jjk/Episodes': {
          'Items': [
            episode(0, 1),
            for (var n = 1; n <= 3; n++) episode(1, n),
            for (var n = 1; n <= 3; n++) episode(2, n),
          ],
        },
      });
      final media = {
        'id': 145064,
        'episodes': 2,
        'title': {'romaji': 'Jujutsu Kaisen 2nd Season'},
      };
      final id = await jf.match(media);
      expect(id, 'jjk/2/1/2');
      final list = await jf.episodesOf(id!);
      expect(
        [for (final e in list) (e.number, e.ref)],
        [(1, 's2e1'), (2, 's2e2')],
      );
    },
  );

  test('a dub is the server HLS on the English track when the file defaults to Japanese', () async {
    final jf = server({
      'ids=ep': {
        'Items': [
          {
            'Id': 'ep',
            'MediaSources': [
              {
                'Id': 'src',
                'Container': 'mkv',
                'DefaultAudioStreamIndex': 1,
                'MediaStreams': [
                  {'Type': 'Audio', 'Index': 1, 'Language': 'jpn'},
                  {'Type': 'Audio', 'Index': 2, 'Language': 'eng'},
                  {
                    'Type': 'Subtitle',
                    'Index': 3,
                    'IsTextSubtitleStream': true,
                    'DisplayTitle': 'English',
                  },
                ],
              },
            ],
          },
        ],
      },
    });
    final episode = (await jf.episodesOf('movie/ep')).single;
    final sub = await jf.streams({}, episode, dub: false);
    expect(sub.map((s) => s.label), ['Jellyfin', 'Jellyfin (transcoded)']);
    expect(
      sub.first.url,
      startsWith('http://jf.test/Videos/ep/stream.mkv?static=true'),
    );
    expect(
      sub.first.subtitles,
      isEmpty,
    ); // embedded: the player reads it from the file
    final dub = await jf.streams({}, episode, dub: true);
    expect(dub.single.url, contains('AudioStreamIndex=2'));
    expect(
      dub.single.subtitles.single.url,
      contains('/Subtitles/3/0/Stream.vtt'),
    );
  });

  test(
    'a show found by searching its titles never reads the whole library',
    () async {
      httpClient = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'mappings': {'anidb_id': 9},
          }),
          200,
        ),
      );
      final net = FakeNet({
        'searchTerm=': jsonEncode({
          'Items': [
            {
              'Id': 'a',
              'Type': 'Series',
              'Name': 'Frieren',
              'ProviderIds': {'AniDB': '9'},
            },
          ],
        }),
      });
      final jf = Jellyfin(
        server: 'http://jf.test',
        token: 't',
        user: 'u',
        net: net,
      );
      final id = await jf.match({
        'id': 1,
        'title': {'romaji': 'Sousou no Frieren 2nd Season'},
      });
      expect(id, startsWith('a/'));
      expect(net.requests, everyElement(contains('searchTerm=')));
      // The season's suffix is dropped too: libraries name a show by its first season.
      expect(net.requests, contains(contains('searchTerm=sousou+no+frieren&')));
    },
  );

  test(
    'progress goes to the server in ticks, and a finished episode as played',
    () async {
      final sent = <Map>[];
      final jf = server({});
      await http.runWithClient(
        () async {
          await jf.report(
            'ep',
            const Duration(minutes: 5),
            const Duration(minutes: 24),
          );
          await jf.report(
            'ep',
            const Duration(minutes: 23),
            const Duration(minutes: 24),
          );
        },
        () => MockClient((req) async {
          expect(
            req.url.toString(),
            'http://jf.test/UserItems/ep/UserData?userId=u',
          );
          sent.add(jsonDecode(req.body));
          return http.Response('{}', 200);
        }),
      );
      expect(sent, [
        {'Played': false, 'PlaybackPositionTicks': 3000000000},
        {'Played': true, 'PlaybackPositionTicks': 0},
      ]);
    },
  );

  test("the server's new shows come back as AniList shows, by their own id or ani.zip's", () async {
    httpClient = MockClient(
      (req) async => http.Response(
        jsonEncode({
          'mappings': {
            'anilist_id': req.url.query.contains('thetvdb_id=7') ? 20 : null,
          },
        }),
        200,
      ),
    );
    List? asked;
    AniList.transport = (query, variables) async {
      asked = variables['ids'];
      return {
        'Page': {
          'media': [
            for (final id in variables['ids']) {'id': id},
          ],
        },
      };
    };
    addTearDown(() => AniList.transport = null);
    final jf = server({
      'SortBy=DateLastContentAdded': {
        'Items': [
          {
            'ProviderIds': {'AniList': '10'},
          },
          {
            'ProviderIds': {'Tvdb': '7'},
          },
          {
            'ProviderIds': {'Tvdb': '8'},
          }, // unknown to ani.zip
          {
            'ProviderIds': {'AniList': '10'},
          }, // asked once
        ],
      },
    });
    final shows = await jf.shows();
    expect(asked, [10, 20]);
    expect([for (final m in shows) m['id']], [10, 20]);
  });

  test("a season the library doesn't have is no episodes, so the show can be requested", () async {
    final jf = server({
      '/Shows/jjk/Episodes': {
        'Items': [for (var n = 1; n <= 3; n++) episode(1, n)],
      },
    });
    expect(await jf.episodesOf('jjk/2/1/23'), isEmpty);
  });

  test(
    'a series found by the entry\'s own AniList id starts at its beginning',
    () async {
      httpClient = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'mappings': {'thetvdb_id': 377543},
            'episodes': {
              '1': {'seasonNumber': 2, 'episodeNumber': 1},
            },
          }),
          200,
        ),
      );
      final jf = server({
        'searchTerm=': {
          'Items': [
            {
              'Id': 'shoko',
              'Type': 'Series',
              'Name': 'Jujutsu Kaisen 2nd Season',
              'ProviderIds': {'AniList': '145064', 'Tvdb': '377543'},
            },
          ],
        },
        '/Shows/shoko/Episodes': {
          'Items': [for (var n = 1; n <= 2; n++) episode(1, n)],
        },
      });
      final id = await jf.match({
        'id': 145064,
        'episodes': 23,
        'title': {'romaji': 'Jujutsu Kaisen 2nd Season'},
      });
      expect(id, 'shoko///23');
      expect((await jf.episodesOf(id!)).map((e) => e.ref), ['s1e1', 's1e2']);
    },
  );
}

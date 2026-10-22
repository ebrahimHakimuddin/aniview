import 'dart:convert';

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
}

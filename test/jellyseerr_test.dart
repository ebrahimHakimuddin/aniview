import 'dart:convert';

import 'package:aniview/jellyseerr.dart';
import 'package:aniview/net.dart';
import 'package:aniview/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
  });

  final jjk2 = {
    'id': 145064,
    'format': 'TV',
    'title': {'romaji': 'Jujutsu Kaisen 2nd Season'},
  };

  test('signing in keeps only the session cookie', () async {
    await http.runWithClient(
      () => Jellyseerr.signIn('seerr.test:5055/', 'fam', 'pw'),
      () => MockClient((req) async {
        expect(
          req.url.toString(),
          'http://seerr.test:5055/api/v1/auth/jellyfin',
        );
        expect(jsonDecode(req.body), {'username': 'fam', 'password': 'pw'});
        return http.Response(
          '{}',
          200,
          headers: {
            'set-cookie': 'connect.sid=s%3Aabc.def; Path=/; Expires=Wed, 21 Nov 2026 08:32:37 GMT; HttpOnly',
          },
        );
      }),
    );
    expect(Settings.jellyseerrServer, 'http://seerr.test:5055');
    expect(Settings.jellyseerrCookie, 'connect.sid=s%3Aabc.def');
  });

  test("a TVDB season TMDB doesn't have suggests TMDB's latest, and requested seasons say so", () async {
    httpClient = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'mappings': {'themoviedb_id': '95479'},
          'episodes': {
            '1': {'seasonNumber': 2},
          },
        }),
        200,
      ),
    );
    final seerr = Jellyseerr('http://seerr.test', 'connect.sid=x');
    final title = await http.runWithClient(
      () => seerr.find(jjk2),
      () => MockClient((req) async {
        expect(req.url.path, '/api/v1/tv/95479');
        expect(req.headers['Cookie'], 'connect.sid=x');
        return http.Response(
          jsonEncode({
            'name': 'JUJUTSU KAISEN',
            'seasons': [
              {'seasonNumber': 0, 'episodeCount': 10},
              {'seasonNumber': 1, 'episodeCount': 59},
            ],
            'mediaInfo': {
              'status': 2,
              'requests': [
                {
                  'status': 1,
                  'seasons': [
                    {'seasonNumber': 1},
                  ],
                },
              ],
            },
          }),
          200,
        );
      }),
    );
    expect(title!.suggested, 1);
    expect(title.state, 'Requested');
    expect(
      [for (final s in title.seasons) (s.number, s.state)],
      [(0, null), (1, 'Requested')],
    );
  });

  test('the season ani.zip names is suggested when TMDB has it', () {
    final seasons = [
      for (final n in [0, 1, 2, 3]) (number: n, episodes: 12, state: null),
    ];
    expect(Jellyseerr.suggestedSeason(seasons, 2), 2);
    expect(Jellyseerr.suggestedSeason(seasons, null), 3);
  });

  test('an expired session signs out and says to sign in again', () async {
    Settings.jellyseerrCookie = 'connect.sid=old';
    final seerr = Jellyseerr.saved()!;
    httpClient = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'mappings': {'themoviedb_id': '1'},
        }),
        200,
      ),
    );
    await expectLater(
      http.runWithClient(
        () => seerr.find(jjk2),
        () => MockClient((_) async => http.Response('{"status":403}', 403)),
      ),
      throwsA(predicate((e) => '$e'.contains('Sign in to Jellyseerr again'))),
    );
    expect(Settings.jellyseerrCookie, isEmpty);
  });

  test('a series is requested by season, a movie whole', () async {
    final sent = <Map>[];
    final seerr = Jellyseerr('http://seerr.test', 'c');
    await http.runWithClient(
      () async {
        await seerr.request((
          id: 95479,
          movie: false,
          name: 'JJK',
          state: null,
          seasons: const [],
          suggested: 1,
        ), season: 1);
        await seerr.request((
          id: 810693,
          movie: true,
          name: 'JJK 0',
          state: null,
          seasons: const [],
          suggested: null,
        ));
      },
      () => MockClient((req) async {
        sent.add(jsonDecode(req.body));
        return http.Response('{}', 201);
      }),
    );
    expect(sent, [
      {
        'mediaType': 'tv',
        'mediaId': 95479,
        'seasons': [1],
      },
      {'mediaType': 'movie', 'mediaId': 810693},
    ]);
  });
}

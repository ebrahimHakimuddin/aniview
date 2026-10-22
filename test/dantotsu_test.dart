import 'dart:convert';

import 'package:aniview/anilist.dart';
import 'package:aniview/dantotsu.dart';
import 'package:aniview/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
    AniList.token = 'anilist-token';
  });
  tearDown(() => AniList.token = null);

  test(
    'comments come with a session made from the AniList sign-in, once',
    () async {
      final asked = <String>[];
      final (list, pages) = await http.runWithClient(
        () async {
          await Dantotsu.comments(16498, 1, episode: 3);
          return Dantotsu.comments(16498, 2, episode: 3, newest: true);
        },
        () => MockClient((req) async {
          asked.add('${req.method} ${req.url.path}?${req.url.query}');
          expect(req.headers['appauth'], isNotEmpty);
          if (req.url.path == '/authenticate') {
            expect(req.bodyFields, {'token': 'anilist-token'});
            return http.Response(
              jsonEncode({
                'authToken': 'session',
                'user': {'user_id': '42', 'username': 'me'},
              }),
              200,
            );
          }
          expect(req.headers['Authorization'], 'session');
          return http.Response(
            jsonEncode({
              'comments': [
                {'comment_id': 1, 'content': 'hi'},
              ],
              'totalPages': 4,
            }),
            200,
          );
        }),
      );
      expect(asked, [
        'POST /authenticate?',
        'GET /comments/16498/1?sort=highest_rated&tag=3',
        'GET /comments/16498/2?sort=newest&tag=3',
      ]);
      expect(list.single['content'], 'hi');
      expect(pages, 4);
      expect(Dantotsu.isMine({'user_id': '42'}), isTrue);
    },
  );

  test(
    'a turned-away session is made again, and the post goes once more',
    () async {
      Settings.dantotsuToken = 'old';
      Settings.dantotsuTokenAt = DateTime.now().millisecondsSinceEpoch;
      Settings.dantotsuUser = '42';
      final posts = <Map>[];
      await http.runWithClient(
        () => Dantotsu.post(16498, 'Great episode', episode: 3, parent: 7),
        () => MockClient((req) async {
          if (req.url.path == '/authenticate') {
            return http.Response(
              jsonEncode({
                'authToken': 'new',
                'user': {'user_id': '42', 'username': 'me'},
              }),
              200,
            );
          }
          if (req.headers['Authorization'] == 'old') {
            return http.Response('Unauthorized', 401);
          }
          posts.add(req.bodyFields);
          return http.Response('{}', 200);
        }),
      );
      expect(posts, [
        {
          'user_id': '42',
          'media_id': '16498',
          'content': 'Great episode',
          'tag': '3',
          'parent_comment_id': '7',
        },
      ]);
    },
  );

  test('without an AniList sign-in, comments say to sign in', () async {
    AniList.token = null;
    await expectLater(
      Dantotsu.comments(1, 1),
      throwsA(predicate((e) => '$e'.contains('Sign in with AniList'))),
    );
  });
}

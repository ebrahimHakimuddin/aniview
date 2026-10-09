import 'package:aniview/anilist.dart';
import 'package:aniview/mal.dart';

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('maps a MAL anime onto the AniList media shape', () {
    final media = MAL.media({
      'id': 21,
      'title': 'One Piece',
      'alternative_titles': {'en': 'One Piece'},
      'main_picture': {'medium': 'm.jpg', 'large': 'l.jpg'},
      'synopsis': 'Pirates.',
      'mean': 8.72,
      'genres': [
        {'id': 1, 'name': 'Action'},
      ],
      'media_type': 'tv',
      'status': 'currently_airing',
      'start_season': {'year': 1999, 'season': 'fall'},
      'num_episodes': 0,
    });

    expect(
      media['id'],
      isNull,
    ); // filled in from ani.zip when the show is opened
    expect(media['idMal'], 21);
    expect(titleOf(media), 'One Piece');
    expect(media['coverImage']['extraLarge'], 'l.jpg');
    expect(
      media['episodes'],
      isNull,
    ); // 0 means "still going", not "no episodes"
    expect(media['averageScore'], 87);
    expect(media['genres'], ['Action']);
    expect(media['format'], 'TV');
    expect(media['status'], 'RELEASING');
    expect(media['season'], 'FALL');
    expect(media['seasonYear'], 1999);
    expect(media['mediaListEntry'], isNull);
  });

  test('filters MAL results the way AniList would', () {
    final media = {
      'season': 'FALL',
      'seasonYear': 1999,
      'format': 'TV',
      'status': 'RELEASING',
      'genres': ['Action', 'Adventure'],
    };
    expect(const SearchFilters().matches(media), isTrue);
    expect(
      const SearchFilters(
        season: 'FALL',
        year: 1999,
        format: 'TV',
        genres: {'Action', 'Adventure'},
      ).matches(media),
      isTrue,
    );
    expect(const SearchFilters(year: 2000).matches(media), isFalse);
    expect(
      const SearchFilters(genres: {'Action', 'Comedy'}).matches(media),
      isFalse,
    ); // every genre must match
    const unwatched = SearchFilters(unwatched: true);
    expect(unwatched.matches(media), isTrue); // not on the list
    for (final (status, kept) in [
      ('PLANNING', true),
      ('CURRENT', false),
      ('REPEATING', false),
      ('COMPLETED', false),
    ]) {
      final listed = {
        ...media,
        'mediaListEntry': {'status': status},
      };
      expect(unwatched.matches(listed), kept, reason: status);
    }
  });

  group('signed in', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'mal_access': 'a',
        'mal_refresh': 'r',
        'mal_expires': DateTime.now()
            .add(const Duration(days: 20))
            .toIso8601String(),
      });
      await MAL.load();
    });
    tearDown(() => AniList.transport = null);

    MockClient answering(Map<String, Object> byPath) => MockClient(
      (req) async => http.Response(jsonEncode(byPath[req.url.path]), 200),
    );

    test(
      'lists carry AniList ids, and rewatching sits with watching',
      () async {
        AniList.transport = (query, v) async => {
          'Page': {
            'media': [
              for (final id in v['m'] as List)
                if (id != 3) {'id': id + 100, 'idMal': id},
            ],
          },
        };
        Map entry(int id, String status, {bool rewatching = false}) => {
          'node': {'id': id, 'title': 'S$id'},
          'list_status': {
            'status': status,
            'is_rewatching': rewatching,
            'num_episodes_watched': 2,
          },
        };
        final lists = await http.runWithClient(
          MAL.lists,
          () => answering({
            '/v2/users/@me/animelist': {
              'data': [
                entry(1, 'watching'),
                entry(2, 'completed', rewatching: true),
                entry(3, 'plan_to_watch'),
              ],
              'paging': {},
            },
          }),
        );
        expect([for (final m in lists['CURRENT']!) m['id']], [101, 102]);
        expect(lists['CURRENT']![1]['mediaListEntry']['status'], 'REPEATING');
        expect(lists['PLANNING']!.single['id'], isNull); // AniList lacks it
      },
    );

    test('stats come in AniList\'s shape, without activity', () async {
      final stats = await http.runWithClient(
        MAL.stats,
        () => answering({
          '/v2/users/@me': {
            'anime_statistics': {
              'num_items': 10,
              'num_episodes': 120,
              'num_days_watched': 1.5,
              'num_items_watching': 3,
            },
          },
        }),
      );
      final anime = stats!['statistics']['anime'];
      expect(anime['minutesWatched'], 2160);
      expect(anime['statuses'].first, {'status': 'CURRENT', 'count': 3});
      expect(stats['stats'], isNull);
    });

    test('a paired TV gets the access, never the refresh token', () async {
      final shared = MAL.shareable!;
      expect(shared.keys, unorderedEquals(['access', 'expires']));
      await MAL.useShared(shared);
      expect(MAL.signedIn, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('mal_refresh'), isNull);
    });
  });
}

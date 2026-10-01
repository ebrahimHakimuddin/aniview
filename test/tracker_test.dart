import 'dart:convert';

import 'package:aniview/anilist.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/tracker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _show(int id) => {
  'id': id,
  'idMal': id + 1000,
  'title': {'userPreferred': 'Show $id'},
  'episodes': 12,
  'mediaListEntry': {'progress': 0, 'status': 'CURRENT'},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // every HTTP call fails, like being offline

  test(
    'queues saves AniList can\'t take and keeps them until they go through',
    () async {
      SharedPreferences.setMockInitialValues({});
      AniList.token = 'signed in';

      for (var id = 1; id <= 6; id++) {
        expect(await Tracker.save(_show(id), 3), isFalse);
      }
      await Tracker.save(
        _show(4),
        5,
      ); // a newer save replaces the show's older one

      final prefs = await SharedPreferences.getInstance();
      Map queued() => jsonDecode(prefs.getString('anilist_pending')!);
      expect(queued().keys, ['1', '2', '3', '4', '5', '6']);
      expect(queued()['4']['progress'], 5);
      expect(queued()['4']['status'], 'CURRENT');

      expect(await Tracker.syncPending(), 0); // still offline: everything stays
      expect(queued().length, 6);
    },
  );

  test(
    'syncs a watched episode only forward, signed in, with sync on',
    () async {
      SharedPreferences.setMockInitialValues({});
      await Settings.load();
      final show = _show(7)..['mediaListEntry'] = {'progress': 4};

      AniList.token = null;
      expect(await Tracker.watched(show, 5), SyncResult.skipped);

      AniList.token = 'signed in';
      expect(await Tracker.watched(show, 3), SyncResult.skipped); // a rewatch
      Settings.syncAniList = false;
      expect(await Tracker.watched(show, 5), SyncResult.skipped);
      Settings.syncAniList = true;
      expect(await Tracker.watched(show, 5), SyncResult.queued); // offline
    },
  );

  group('with AniList answering', () {
    final sent = <Map>[];
    late Map<String, dynamic> remote;

    Future<Map<String, dynamic>> answer(
      String query,
      Map<String, dynamic> v,
    ) async {
      if (query.contains('mutation(\$m')) {
        sent.add(v);
        return {'SaveMediaListEntry': <String, dynamic>{}};
      }
      return {
        'Media': {'mediaListEntry': remote},
      };
    }

    setUp(() {
      sent.clear();
      remote = {'progress': 0};
      AniList.token = 'signed in';
      AniList.transport = answer;
    });
    tearDown(() {
      AniList.transport = null;
      AniList.token = null;
    });

    test('saves, and completing counts every episode', () async {
      SharedPreferences.setMockInitialValues({});
      final show = _show(1);
      expect(await Tracker.save(show, 3), isTrue);
      expect(sent.single, {'m': 1, 's': 'CURRENT', 'p': 3});

      sent.clear();
      expect(await Tracker.save(show, 3, status: 'COMPLETED'), isTrue);
      expect(sent.single, {'m': 1, 's': 'COMPLETED', 'p': 12});
      expect(show['mediaListEntry'], {'progress': 12, 'status': 'COMPLETED'});
    });

    test('a forward-only save never lowers AniList\'s progress', () async {
      SharedPreferences.setMockInitialValues({});
      remote = {'progress': 8};
      final show = _show(2)..['mediaListEntry'] = null;
      expect(await Tracker.save(show, 5, forwardOnly: true), isTrue);
      expect(sent, isEmpty);
    });

    test('queued saves go out once AniList answers', () async {
      SharedPreferences.setMockInitialValues({});
      AniList.transport = (_, _) async => throw Exception('down');
      expect(await Tracker.save(_show(3), 4), isFalse);

      AniList.transport = answer;
      expect(await Tracker.syncPending(), 1);
      expect(sent.single, {'m': 3, 's': 'CURRENT', 'p': 4});
    });

    test(
      'queued saves wait while signed out, and sign-out drops them',
      () async {
        SharedPreferences.setMockInitialValues({});
        AniList.transport = (_, _) async => throw Exception('down');
        await Tracker.save(_show(4), 2);

        AniList.token = null; // e.g. the token expired
        expect(await Tracker.syncPending(), 0);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('anilist_pending'), contains('"4"'));

        await Tracker.signOut();
        expect(prefs.getString('anilist_pending'), isNull);
      },
    );

    test('removing a show clears its list entry', () async {
      SharedPreferences.setMockInitialValues({});
      final show = _show(5);
      await Tracker.removeFromList(show);
      expect(show['mediaListEntry'], isNull);
    });
  });

  test('an entry draft completes at the last episode and counts them all', () {
    final draft = EntryDraft(status: 'PLANNING', total: 12);
    draft.setProgress(5);
    expect((draft.status, draft.progress), ('PLANNING', 5));
    draft.setProgress(99); // clamped to the total, which completes it
    expect((draft.status, draft.progress), ('COMPLETED', 12));
    expect(draft.canAdvance, isFalse);
    draft.setProgress(-3);
    expect(draft.progress, 0);

    draft.setStatus('COMPLETED');
    expect(draft.progress, 12);
    draft.setStatus('DROPPED'); // keeps the count
    expect((draft.status, draft.progress), ('DROPPED', 12));
  });

  test('an entry draft without a known total never completes by counting', () {
    final draft = EntryDraft();
    expect(draft.status, 'CURRENT');
    draft.setProgress(500);
    expect((draft.status, draft.progress), ('CURRENT', 500));
    expect(draft.canAdvance, isTrue);
    draft.setProgress(20000);
    expect(draft.progress, 9999);
    draft.setStatus('COMPLETED'); // nothing to count to
    expect(draft.progress, 9999);
  });

  test('the popular schedule drops ecchi shows while NSFW is hidden', () async {
    final at = DateTime.now().add(const Duration(hours: 2));
    Map media(int id, List genres) => {
      'id': id,
      'genres': genres,
      'airingSchedule': {
        'nodes': [
          {'episode': 1, 'airingAt': at.millisecondsSinceEpoch ~/ 1000},
        ],
      },
    };
    AniList.transport = (_, _) async => {
      'Page': {
        'pageInfo': {'hasNextPage': false},
        'media': [
          media(1, ['Action']),
          media(2, ['Ecchi']),
        ],
      },
    };
    addTearDown(() => AniList.transport = null);

    SharedPreferences.setMockInitialValues({'hide_nsfw': true});
    await Settings.load();
    expect(
      [for (final s in await Tracker.airingPopular()) s['media']['id']],
      [1],
    );

    SharedPreferences.setMockInitialValues({});
    await Settings.load();
    expect((await Tracker.airingPopular()).length, 2);
  });

  test('list statuses label AniList values; rewatching is not a move', () {
    expect(ListStatus.labels['REPEATING'], 'Rewatching');
    expect(ListStatus.labels.length, 6);
    expect(ListStatus.movable.keys, [
      'CURRENT',
      'PLANNING',
      'COMPLETED',
      'PAUSED',
      'DROPPED',
    ]);
    expect(ListStatus.movable['CURRENT'], 'Watching');
  });

  test(
    'counts statuses from the list when AniList\'s breakdown is empty',
    () async {
      AniList.token = 'signed in';
      addTearDown(() {
        AniList.transport = null;
        AniList.token = null;
      });
      AniList.transport = (query, variables) async {
        if (query.contains('MediaListCollection')) {
          expect(variables['u'], 7);
          return {
            'MediaListCollection': {
              'lists': [
                {
                  'status': 'COMPLETED',
                  'isCustomList': false,
                  'entries': [
                    {'id': 1},
                    {'id': 2},
                  ],
                },
                {
                  'status': null,
                  'isCustomList': true,
                  'entries': [
                    {'id': 1},
                  ],
                },
              ],
            },
          };
        }
        return {
          'Viewer': {
            'id': 7,
            'statistics': {
              'anime': {'count': 2, 'statuses': []},
            },
          },
        };
      };
      final stats = (await AniList.stats())!;
      expect(stats['statistics']['anime']['statuses'], [
        {'status': 'COMPLETED', 'count': 2},
      ]);
    },
  );

  group('browsing', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({'hide_nsfw': true});
      await Settings.load();
    });
    tearDown(() {
      Tracker.primary = const AniListCatalog();
      Tracker.fallback = const MalCatalog();
    });

    test(
      'falls back when the primary fails, and reports the primary when both do',
      () async {
        Tracker.primary = _Catalog(error: 'AniList is down');
        Tracker.fallback = _Catalog(shows: [_genre('Action'), _genre('Ecchi')]);
        expect(await Tracker.trending(), [
          _genre('Action'),
        ]); // from the fallback, ecchi hidden

        Tracker.fallback = _Catalog(error: 'MAL is down too');
        await expectLater(
          Tracker.trending(),
          throwsA(predicate((e) => '$e'.contains('AniList is down'))),
        );

        Tracker.primary = _Catalog(usable: false);
        Tracker.fallback = _Catalog(shows: [_genre('Drama')]);
        expect(await Tracker.season(), [
          _genre('Drama'),
        ]); // straight to the fallback
      },
    );

    test('searching for ecchi by genre shows it anyway', () async {
      Tracker.primary = _Catalog(shows: [_genre('Ecchi')]);
      const ecchi = SearchFilters(genres: {'Ecchi'});
      expect((await Tracker.search('', ecchi)).$1, hasLength(1));
      expect((await Tracker.search('x', const SearchFilters())).$1, isEmpty);
    });
  });
}

Map _genre(String genre) => {
  'genres': [genre],
};

class _Catalog implements Catalog {
  _Catalog({this.shows = const [], this.error, this.usable = true});
  final List shows;
  final String? error;
  @override
  final bool usable;

  Future<T> _answer<T>(T value) async =>
      error == null ? value : throw Exception(error);

  @override
  Future<List> trending() => _answer(shows);
  @override
  Future<List> season() => _answer(shows);
  @override
  Future<(List, bool)> search(String text, SearchFilters filters, int page) =>
      _answer((shows, false));
  @override
  Future<List<(String, Map)>> relations(Map media) => _answer(const []);
}

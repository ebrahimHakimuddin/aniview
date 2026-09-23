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

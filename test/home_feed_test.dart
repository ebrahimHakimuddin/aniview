import 'package:aniview/history.dart';
import 'package:aniview/home_feed.dart';
import 'package:aniview/settings.dart';
import 'package:flutter_test/flutter_test.dart';

class _Source implements HomeSource {
  @override
  bool signedIn = true;
  final calls = <String>[];
  List<Map> popular = [], around = [];
  List<WatchRecord> watched = [];
  Map<String, List> lists_ = {'CURRENT': [], 'PLANNING': []};
  List<Iterable<int>> asked = [];

  int count(String name) => calls.where((c) => c == name).length;

  @override
  Future<Map<String, dynamic>?> viewer() async => null;
  @override
  Future<Map<String, List>> lists({bool all = false}) async {
    calls.add(all ? 'library' : 'lists');
    return all ? {...lists_, 'DROPPED': []} : lists_;
  }

  @override
  Future<List> trending() async => [];
  @override
  Future<List> season() async => [];
  @override
  Future<Map<String, dynamic>?> stats() async => null;
  @override
  Future<List<Map>> airingAround(Iterable<int> ids) async {
    calls.add('around');
    asked.add(ids);
    return around;
  }

  @override
  Future<List<Map>> airingPopular() async {
    calls.add('popular');
    return popular;
  }

  @override
  Future<List<WatchRecord>> history() async {
    calls.add('history');
    return watched;
  }
}

Map _show(int id, {String? status, String? season, int? year}) => {
  'id': id,
  'status': status,
  'season': season,
  'seasonYear': year,
};

Map _slot(int id, DateTime at) => {
  'episode': 1,
  'airingAt': at.millisecondsSinceEpoch ~/ 1000,
  'media': _show(id),
};

void main() {
  group('HomeFeed', () {
    late _Source source;
    late DateTime clock;
    late HomeFeed feed;

    setUp(() {
      clock = DateTime(2026, 3, 1, 12);
      source = _Source();
      feed = HomeFeed(source: source, now: () => clock);
    });
    tearDown(() => feed.dispose());

    test('coming back re-reads only the watch history; stale lists are asked again on a tab pick', () async {
      await feed.lists;
      expect(source.count('lists'), 1);

      clock = clock.add(const Duration(seconds: 59));
      var heard = 0;
      feed.addListener(() => heard++);
      feed.reload();
      await feed.lists;
      expect(
        (source.count('lists'), source.count('history'), heard),
        (1, 1, 1),
      );

      clock = clock.add(const Duration(seconds: 2)); // a minute since it began
      feed.reload(); // back from a show: never refetches, however old
      await feed.lists;
      expect((source.count('lists'), source.count('history')), (1, 2));

      feed.reload(checkStale: true); // a tab picked or the app reopened
      await feed.lists;
      expect((source.count('lists'), source.count('history')), (2, 3));
    });

    test('forcing a reload, and refreshing, ask again at once', () async {
      await feed.lists;
      feed.reload(force: true);
      await feed.lists;
      expect(source.count('lists'), 2);

      await feed.refresh();
      expect(source.count('lists'), 3);
      expect(source.count('history'), 2);
    });

    test("home's lists come from My list's once it is loaded", () async {
      await feed.library;
      feed.reload(force: true);
      final lists = await feed.lists;

      expect(source.count('lists'), 0); // home reused the library's
      expect(source.count('library'), 2); // refetched, and home read it
      expect(lists.keys, ['CURRENT', 'PLANNING']); // not the other lists
    });

    test('follows the lists and what was watched, with a usable id', () async {
      source.lists_ = {
        'CURRENT': [_show(1)],
        'PLANNING': [_show(2)],
      };
      source.watched = [
        const WatchRecord({
          'media': {'id': 3},
        }),
        const WatchRecord({
          'media': {'id': 'mal:4'},
        }),
      ];
      await feed.released;
      expect(source.asked.single.toSet(), {1, 2, 3});
    });

    test('lists that fail still leave the recently watched followed', () async {
      source.watched = [
        const WatchRecord({
          'media': {'id': 3},
        }),
      ];
      final failing = HomeFeed(source: _Failing(source), now: () => clock);
      addTearDown(failing.dispose);
      await failing.released;
      expect(source.asked.single, [3]);
    });

    test('the schedule drops what aired before today', () async {
      source.around = [
        _slot(1, DateTime(2026, 2, 28, 23, 59)), // yesterday
        _slot(2, DateTime(2026, 3, 1, 0, 0, 1)),
        _slot(3, DateTime(2026, 3, 4, 20)),
      ];
      final ids = [for (final s in await feed.schedule) s['media']['id']];
      expect(ids, [2, 3]);
    });

    test('signed out, the schedule is the popular shows', () async {
      source.signedIn = false;
      source.popular = [_slot(9, DateTime(2026, 3, 2, 20))];
      expect(await feed.schedule, source.popular);
      expect(source.count('around'), 0);
    });

    test('a loaded schedule is fetched again with the lists', () async {
      await feed.schedule;
      await feed.allSchedule;
      feed.reload(force: true);
      await feed.schedule;
      await feed.allSchedule;
      expect(source.count('around'), 2);
      expect(source.count('popular'), 2);
    });

    test('pages not opened yet are not fetched', () async {
      feed.reload(force: true);
      await feed.lists;
      expect((source.count('library'), source.count('popular')), (0, 0));
    });
  });

  group('schedule', () {
    final now = DateTime(2026, 3, 1, 12);
    final slots = [
      _slot(1, DateTime(2026, 3, 1, 8)), // aired this morning
      _slot(2, DateTime(2026, 3, 1, 20)),
      _slot(3, DateTime(2026, 3, 1, 22)),
      _slot(4, DateTime(2026, 3, 2, 9)),
    ];
    int id(Map s) => s['media']['id'];

    test('today lists its episodes with the next one apart', () {
      final today = scheduleDay(slots, now, 0);
      expect(today.shown.map(id), [1, 2, 3]);
      expect(id(today.next!), 2);
      expect(today.rest.map(id), [1, 3]);
    });

    test('other days have no next, and a month end rolls over', () {
      final tomorrow = scheduleDay(slots, now, 1);
      expect(tomorrow.shown.map(id), [4]);
      expect(tomorrow.next, isNull);
      expect(tomorrow.rest.map(id), [4]);
      expect(scheduleDate(DateTime(2026, 2, 28, 12), 2), DateTime(2026, 3, 2));
      expect(scheduleDay(slots, now, 3).shown, isEmpty);
    });

    test('nothing is next once the day is over', () {
      final evening = DateTime(2026, 3, 1, 23);
      expect(scheduleDay(slots, evening, 0).next, isNull);
    });
  });

  group('home rows', () {
    const season = ('SPRING', 2026);
    final airing = _show(1, status: 'RELEASING');
    final thisSeason = _show(2, season: 'SPRING', year: 2026);
    final finished = _show(3, status: 'FINISHED', season: 'WINTER', year: 2020);
    final planned = _show(4);

    test('watching is split from what airs when its row is shown', () {
      final lists = {
        'CURRENT': [airing, thisSeason, finished],
        'PLANNING': [planned],
      };
      final split = homeRows(lists, splitAiring: true, season: season);
      expect(split.airing, [airing, thisSeason]);
      expect(split.watching, [finished]);
      expect(split.planning, [planned]);
      expect(split.empty, isFalse);

      final joined = homeRows(lists, splitAiring: false, season: season);
      expect(joined.watching, [airing, thisSeason, finished]);
    });

    test('empty only when neither list has anything', () {
      expect(homeRows({}, splitAiring: true, season: season).empty, isTrue);
      expect(
        homeRows(
          {
            'CURRENT': [airing],
          },
          splitAiring: true,
          season: season,
        ).empty,
        isFalse, // even if it all moved to the airing row
      );
    });

    test('the first shown row, past the carousel, takes focus', () {
      expect(
        firstRow([
          (HomeSection.featured, true),
          (HomeSection.newEpisodes, false),
          (HomeSection.watching, true),
          (HomeSection.trending, true),
        ]),
        HomeSection.watching,
      );
      expect(firstRow([(HomeSection.featured, true)]), isNull);
    });
  });

  group('remote intents', () {
    const record = WatchRecord({'episode': 3});

    test('Play on TV resumes what is saved, else starts the next episode', () {
      final saved = decide(RemoteIntent.remotePlay, record);
      expect(
        (saved.popToRoot, saved.resume, saved.autoplay),
        (true, record, false),
      );
      final fresh = decide(RemoteIntent.remotePlay, null);
      expect(
        (fresh.popToRoot, fresh.resume, fresh.autoplay),
        (true, null, true),
      );
    });

    test("the launcher's row resumes, or just opens the page", () {
      final saved = decide(RemoteIntent.launcher, record);
      expect((saved.popToRoot, saved.resume), (true, record));
      final cleared = decide(RemoteIntent.launcher, null);
      expect(
        (cleared.popToRoot, cleared.resume, cleared.autoplay),
        (false, null, false),
      );
    });

    test('a notification only opens the page', () {
      final go = decide(RemoteIntent.notification, record);
      expect((go.popToRoot, go.resume, go.autoplay), (false, null, false));
    });
  });
}

/// A source whose lists never load.
class _Failing extends _Source {
  _Failing(_Source from) : super() {
    watched = from.watched;
    asked = from.asked;
  }

  @override
  Future<Map<String, List>> lists({bool all = false}) =>
      Future.error('AniList is down');
}

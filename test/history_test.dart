import 'package:aniview/history.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _show = {
  'id': 1,
  'title': {'userPreferred': 'Show'},
};
const _min = Duration(minutes: 1);

List<Episode> _episodes(int n) => [
  for (var i = 1; i <= n; i++) Episode(i, ref: '$i'),
];

Future<void> _play(List<Episode> episodes, int index, Duration position) =>
    WatchHistory.played(
      _show,
      source: 'Site',
      episodes: episodes,
      index: index,
      position: position,
      duration: _min * 24,
      dub: false,
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({}); // watched at the default 85%
    await Settings.load();
  });

  test(
    'a show saved before its AniList id was known is still found after',
    () async {
      final before = {
        'id': 'mal:1001',
        'idMal': 1001,
        'title': {'userPreferred': 'Show'},
      };
      await WatchHistory.played(
        before,
        source: 'Site',
        episodes: _episodes(3),
        index: 0,
        position: _min * 10,
        duration: _min * 24,
        dub: false,
      );
      final after = {...before, 'id': 1}; // ani.zip answered
      expect((await WatchHistory.of(after))?.episode, 1);
      await WatchHistory.played(
        after,
        source: 'Site',
        episodes: _episodes(3),
        index: 0,
        position: _min * 12,
        duration: _min * 24,
        dub: false,
      );
      expect(await WatchHistory.all(), hasLength(1)); // replaced, not split
    },
  );

  test('plans pages around the next unwatched episode', () {
    final episodes = _episodes(120);
    final plan = EpisodePlan(
      episodes,
      progress: 60,
      newestFirst: true,
      record: const WatchRecord({
        'episode': 61,
        'position': 6000,
        'duration': 24000,
      }),
    );
    expect(plan.upNext?.number, 61);
    expect(plan.pages.length, 3);
    expect(
      plan.shown,
      contains(plan.upNext),
    ); // opens on its page, whatever the order
    expect(plan.watched(episodes[59]), isTrue);
    expect(plan.watched(episodes[60]), isFalse);
    expect(plan.resumedPart(episodes[60]), .25);
    expect(plan.resumedPart(episodes[61]), isNull);

    expect(EpisodePlan(episodes, progress: 60, page: 9).page, 2); // clamped
    expect(EpisodePlan(episodes, progress: 120).upNext, isNull);
  });

  test(
    'resumes only the episode left part-way, and only with resuming on',
    () async {
      final episodes = _episodes(3);
      await _play(episodes, 1, _min * 5);
      expect(await WatchHistory.resumePoint(_show, 2), _min * 5);
      expect(await WatchHistory.resumePoint(_show, 1), isNull);

      Settings.resume = false;
      expect(await WatchHistory.resumePoint(_show, 2), isNull);
    },
  );

  test(
    "the main button resumes what's saved, else starts the next unwatched",
    () {
      final episodes = _episodes(3);
      const saved = WatchRecord({
        'episode': 2,
        'position': 90000,
        'source': 'Site',
      });
      expect(
        EpisodePlan.nextUp(saved, null, 1),
        isA<ResumeSaved>().having((r) => r.midway, 'midway', isTrue),
      );
      expect(
        EpisodePlan.nextUp(null, episodes, 0),
        isA<StartEpisode>()
            .having((s) => s.episode.number, 'episode', 1)
            .having((s) => s.first, 'first', isTrue),
      );
      expect(
        EpisodePlan.nextUp(null, episodes, 2),
        isA<StartEpisode>().having((s) => s.first, 'first', isFalse),
      );
      expect(EpisodePlan.nextUp(null, episodes, 3), isNull); // all watched
      expect(EpisodePlan.nextUp(null, null, 0), isNull); // still loading
    },
  );

  test('a finished show not started yet opens at episode 1', () {
    bool newest(String status, {int progress = 0, bool watched = false}) =>
        EpisodePlan.newestFirstFor(
          {'status': status},
          preferred: true,
          progress: progress,
          watchedHere: watched,
        );
    expect(newest('FINISHED'), isFalse);
    expect(newest('FINISHED', progress: 3), isTrue);
    expect(
      newest('FINISHED', watched: true),
      isTrue,
    ); // watched here, signed out
    expect(newest('RELEASING'), isTrue); // the new episodes are the point
    expect(
      EpisodePlan.newestFirstFor(
        {'status': 'RELEASING'},
        preferred: false,
        progress: 3,
        watchedHere: true,
      ),
      isFalse,
    );
  });

  test('offline, only episodes downloaded in either audio play', () {
    final episodes = _episodes(4);
    final dubbed = {2}, subbed = {4};
    bool downloaded(Episode e) =>
        dubbed.contains(e.number) || subbed.contains(e.number);
    final offline = EpisodePlan.playable(
      episodes,
      online: false,
      downloaded: downloaded,
    );
    expect(offline.map((e) => e.number), [2, 4]);
    expect(
      EpisodePlan.playable(episodes, online: true, downloaded: (_) => false),
      episodes,
    );

    final start = EpisodePlan.startAt(
      episodes[3],
      offline,
      downloadedFrom: 'Site',
    );
    expect((start.index, start.sourceName), (1, 'Site'));
    expect(
      EpisodePlan.startAt(episodes[0], episodes, site: 'Live').sourceName,
      'Live',
    );
  });

  test('tracked progress after picking episodes, .5 episodes included', () {
    List<Episode> eps(List<num> numbers) => [
      for (final n in numbers) Episode(n, ref: '$n'),
    ];
    final picked = eps([5, 6.5, 7]);
    expect(EpisodePlan.progressAfter(picked), 7); // through the latest
    expect(EpisodePlan.progressAfter(eps([6, 6.5])), 6); // 6.5 isn't 7
    expect(EpisodePlan.progressAfter(picked, unwatch: true), 4); // before 5
    expect(EpisodePlan.progressAfter(eps([6.5, 8]), unwatch: true), 6);
    expect(EpisodePlan.progressAfter(eps([1, 2, 12.5])), 12); // season end
    expect(EpisodePlan.progressAfter(const []), 0);
  });

  test('a download range starts at the first unwatched episode', () {
    final episodes = _episodes(12);
    expect(EpisodePlan.rangeStart(episodes, 4).number, 5);
    expect(EpisodePlan.rangeStart(episodes, 0).number, 1);
    expect(EpisodePlan.rangeStart(episodes, 12).number, 1); // all watched

    expect(EpisodePlan.rangeOf(episodes, '3', '5').map((e) => e.number), [
      3,
      4,
      5,
    ]);
    expect(EpisodePlan.rangeOf(episodes, '11.5', '99').length, 1);
    expect(EpisodePlan.rangeOf(episodes, '', '5'), isEmpty);
    expect(EpisodePlan.rangeOf(episodes, '5', '3'), isEmpty);
  });

  test('newest first flips rows and the scroll offset, one row of context', () {
    expect(EpisodePlan.rowFor(0, 100, false), 0);
    expect(EpisodePlan.rowFor(0, 100, true), 99);
    expect(EpisodePlan.offsetFor(10, 100, false, 88), 9 * 88);
    expect(EpisodePlan.offsetFor(10, 100, true, 88), 88 * 88); // row 89
    expect(EpisodePlan.offsetFor(0, 100, false, 88), 0); // never above the top

    final episodes = _episodes(60);
    expect(EpisodePlan.indexOfNumber(episodes, ' 7 '), 6);
    expect(EpisodePlan.indexOfNumber(episodes, '999'), 59); // the last
    expect(EpisodePlan.indexOfNumber(episodes, 'x'), isNull);
  });

  test('an order picked on the page beats the preferred one', () {
    expect(
      EpisodePlan.newestFirstFor(
        {'status': 'RELEASING'},
        preferred: true,
        progress: 0,
        watchedHere: false,
        picked: false,
      ),
      isFalse,
    );
  });
}

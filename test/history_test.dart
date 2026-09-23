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
    'keeps the spot mid-episode and moves on once it counts as watched',
    () async {
      final episodes = _episodes(3);

      await _play(episodes, 0, const Duration(seconds: 3));
      expect(await WatchHistory.of(_show), isNull); // too early to count

      await _play(episodes, 0, _min * 10);
      var record = (await WatchHistory.of(_show))!;
      expect(record.episode, 1);
      expect(record.position, _min * 10);

      await _play(episodes, 0, _min * 21); // past 85%
      record = (await WatchHistory.of(_show))!;
      expect(record.episode, 2);
      expect(record.position, Duration.zero);

      await _play(episodes, 2, _min * 23); // finished the last one
      expect(await WatchHistory.of(_show), isNull);
    },
  );

  test('a read right after a save sees it, as when the player pops', () async {
    _play(_episodes(3), 1, _min * 5).ignore(); // the player doesn't wait
    expect((await WatchHistory.of(_show))!.episode, 2);
  });

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
}

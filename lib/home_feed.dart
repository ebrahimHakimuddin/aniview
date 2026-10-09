import 'package:flutter/foundation.dart';

import 'anilist.dart';
import 'history.dart';
import 'settings.dart';
import 'tracker.dart';

/// Everything the home pages read, asked of [HomeFeed] through this: AniList and the tracker, the on-device watch
/// history, and whether anyone is signed in. Replaced in tests.
abstract interface class HomeSource {
  bool get signedIn;
  Future<Map<String, dynamic>?> viewer();
  Future<Map<String, List>> lists({bool all = false});
  Future<List> trending();
  Future<List> season();
  Future<Map<String, dynamic>?> stats();
  Future<List<Map>> airingAround(Iterable<int> ids);
  Future<List<Map>> airingPopular();
  Future<List<WatchRecord>> history();
}

class LiveHomeSource implements HomeSource {
  const LiveHomeSource();
  @override
  bool get signedIn => Tracker.signedIn;
  @override
  Future<Map<String, dynamic>?> viewer() => Tracker.viewer();
  @override
  Future<Map<String, List>> lists({bool all = false}) =>
      Tracker.lists(all: all);
  @override
  Future<List> trending() => Tracker.trending();
  @override
  Future<List> season() => Tracker.season();
  @override
  Future<Map<String, dynamic>?> stats() => Tracker.stats();
  @override
  Future<List<Map>> airingAround(Iterable<int> ids) =>
      AniList.airingAround(ids);
  @override
  Future<List<Map>> airingPopular() => Tracker.airingPopular();
  @override
  Future<List<WatchRecord>> history() => WatchHistory.all();
}

/// The futures behind Home, Schedule, My list and Me, built when first read and replaced when they go stale.
/// Watch history is on-device and always re-read; list changes made in the app are already in the shared show
/// maps, so AniList is asked again at most once a minute unless forced. Listeners hear every replacement.
class HomeFeed extends ChangeNotifier {
  HomeFeed({
    this.source = const LiveHomeSource(),
    DateTime Function() now = DateTime.now,
  }) : _now = now,
       _fetched = now();

  /// How long fetched lists and airing are good for; see [reload].
  static const staleAfter = Duration(minutes: 1);

  final HomeSource source;
  final DateTime Function() _now;

  /// When lists and airing were last fetched.
  DateTime _fetched;

  late Future<Map<String, dynamic>?> viewer = source.viewer();
  late Future<Map<String, List>> lists = source.lists();
  late Future<List> trending = source.trending();
  late Future<List> season = source.season();

  final _categories = <HomeSection, Future<List>>{};
  Future<List> category(HomeSection section) => _categories.putIfAbsent(
    section,
    () => Tracker.search('', section.filters!).then((result) => result.$1),
  );

  /// Where you stopped in each show, newest first; on-device, so it's there even when AniList isn't.
  late Future<List<WatchRecord>> history = source.history();

  /// A week back and a week ahead of the shows you follow, in one request (AniList allows 30 a minute).
  late Future<List<Map>> _airing = _loadAiring();

  /// The newest episode out this past week of each show you're watching or watched recently.
  late Future<List<Map>> released = _released();

  /// The week ahead of the shows you're watching or planning and the ones you watched recently, or signed out,
  /// of the popular shows airing now; loaded the first time Schedule is shown.
  Future<List<Map>>? _scheduleLoad;
  Future<List<Map>> get schedule => _scheduleLoad ??= _schedule();

  /// The popular, all-show schedule for the second Schedule tab.
  Future<List<Map>>? _allScheduleLoad;
  Future<List<Map>> get allSchedule =>
      _allScheduleLoad ??= source.airingPopular();

  /// Every list, for My list; loaded the first time it's shown.
  Future<Map<String, List>>? _library;
  Future<Map<String, List>> get library => _library ??= source.lists(all: true);

  /// Your totals, for Me; loaded the first time it's shown.
  Future<Map<String, dynamic>?>? _stats;
  Future<Map<String, dynamic>?> get stats => _stats ??= source.stats();

  Future<List<Map>> _loadAiring() async =>
      source.airingAround(await _followed(['CURRENT', 'PLANNING']));

  Future<List<Map>> _released() async => AniList.latestAired(
    await _airing,
    (await _followed(['CURRENT'])).toSet(),
  );

  Future<List<Map>> _schedule() async =>
      !source.signedIn ? allSchedule : fromToday(await _airing, _now());

  /// Home's watching and planning lists: taken from My list's when that's loaded, instead of asking again.
  Future<Map<String, List>> _lists() => _library == null
      ? source.lists()
      : _library!.then(
          (l) => {'CURRENT': l['CURRENT']!, 'PLANNING': l['PLANNING']!},
        );

  /// The AniList ids of shows on the lists named by [statuses] and in the watch history.
  Future<List<int>> _followed(List<String> statuses) async {
    final listed = await lists.then(
      (l) => [for (final s in statuses) ...?l[s]],
      onError: (Object _) => const [], // still check the recently watched ones
    );
    return [
      for (final m in [...listed, for (final r in await history) r.media])
        if (Show(m).onAniList) m['id'] as int,
    ];
  }

  /// Fetches the lists and what airs, and everything built on them.
  void _fetchLists() {
    _fetched = _now();
    if (_library != null) _library = source.lists(all: true);
    lists = _lists();
    _airing = _loadAiring();
    released = _released();
    if (_scheduleLoad != null) _scheduleLoad = _schedule();
    if (_allScheduleLoad != null) _allScheduleLoad = source.airingPopular();
  }

  /// After a show was opened or another page picked: history is re-read (on-device, cheap). Lists and airing are
  /// asked again only when [force]d, or when [checkStale] and they're more than [staleAfter] old. Coming back
  /// from a show leaves [checkStale] off: its changes are already in the shared show maps, and refetching the
  /// lists as the page slides back in stalls the animation.
  void reload({bool force = false, bool checkStale = false}) {
    history = source.history();
    if (force || (checkStale && _now().difference(_fetched) > staleAfter)) {
      _fetchLists();
    }
    notifyListeners();
  }

  /// Pull to refresh: everything is asked again. Completes once the home rows have answered (each shows its
  /// own error state).
  Future<void> refresh() async {
    viewer = source.viewer();
    trending = source.trending();
    season = source.season();
    _categories.clear();
    history = source.history();
    _fetchLists();
    if (_stats != null) _stats = source.stats();
    notifyListeners();
    try {
      await Future.wait([lists, trending, season]);
    } catch (_) {}
  }
}

// ───────────────────────────── Schedule ─────────────────────────────

/// When a schedule slot ({episode, airingAt, media}) airs.
DateTime airsAt(Map slot) =>
    DateTime.fromMillisecondsSinceEpoch((slot['airingAt'] as int) * 1000);

/// [slots] from the start of [now]'s day on.
List<Map> fromToday(List<Map> slots, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  return [
    for (final s in slots)
      if (!airsAt(s).isBefore(today)) s,
  ];
}

/// The date [day] days after [now]'s.
DateTime scheduleDate(DateTime now, int day) =>
    DateTime(now.year, now.month, now.day + day);

/// One day of a schedule: its slots in order, the [next] one to air (today only), and the [rest].
({List<Map> shown, Map? next, List<Map> rest}) scheduleDay(
  List<Map> slots,
  DateTime now,
  int day,
) {
  final date = scheduleDate(now, day);
  final shown = slots.where((s) {
    final at = airsAt(s);
    return at.year == date.year && at.month == date.month && at.day == date.day;
  }).toList();
  final next = day == 0
      ? shown.where((s) => airsAt(s).isAfter(now)).firstOrNull
      : null;
  return (
    shown: shown,
    next: next,
    rest: [
      for (final s in shown)
        if (!identical(s, next)) s,
    ],
  );
}

// ───────────────────────────── Home rows ─────────────────────────────

/// Airing now: still releasing, or from the [season] (name, year) now.
bool airingNow(Map media, (String, int) season) =>
    media['status'] == 'RELEASING' ||
    (media['season'] == season.$1 && media['seasonYear'] == season.$2);

/// Home's list rows from the watching and planning lists: the ones [airing] now, [watching] (without them when
/// their own row is shown, [splitAiring]), and [planning]. [empty] when there's nothing on either list.
({List airing, List watching, List planning, bool empty}) homeRows(
  Map<String, List> lists, {
  required bool splitAiring,
  required (String, int) season,
}) {
  final current = lists['CURRENT'] ?? const [];
  final planning = lists['PLANNING'] ?? const [];
  final airing = [
    for (final m in current)
      if (airingNow(m, season)) m,
  ];
  return (
    airing: airing,
    watching: splitAiring
        ? [
            for (final m in current)
              if (!airingNow(m, season)) m,
          ]
        : current,
    planning: planning,
    empty: current.isEmpty && planning.isEmpty,
  );
}

/// The first home row that's shown, which takes focus on TV (the carousel isn't a row there).
HomeSection? firstRow(List<(HomeSection, bool)> sections) =>
    sections.where((s) => s.$2 && s.$1 != HomeSection.featured).firstOrNull?.$1;

// ───────────────────────────── Remote intents ─────────────────────────────

/// How the app was asked to show a show; [event] is what analytics calls it.
enum RemoteIntent {
  /// A new-episode notification was tapped.
  notification('notification_open'),

  /// "Play on TV" from the phone.
  remotePlay('remote_play'),

  /// The TV launcher's Continue watching row.
  launcher('watch_next_open');

  const RemoteIntent(this.event);
  final String event;
}

/// What to do about [intent] for a show whose watch record is [record] (null without one): back into the player
/// (from [resume]), or its page, [autoplay]ing the next episode; [popToRoot] first, as whatever is open gives way.
({bool popToRoot, WatchRecord? resume, bool autoplay}) decide(
  RemoteIntent intent,
  WatchRecord? record,
) => switch (intent) {
  RemoteIntent.notification => (
    popToRoot: false,
    resume: null,
    autoplay: false,
  ),
  RemoteIntent.remotePlay => (
    popToRoot: true,
    resume: record,
    autoplay: record == null,
  ),
  RemoteIntent.launcher => (
    popToRoot: record != null,
    resume: record,
    autoplay: false,
  ),
};

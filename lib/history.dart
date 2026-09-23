import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'settings.dart';
import 'sources.dart';
import 'tv.dart';

/// Watch progress: where the user stopped in each show (newest first, on-device, mirrored to the TV launcher's
/// Continue watching row), what counts as a finished episode, and what that means for a show's episode list.
class WatchHistory {
  static const _key = 'watch_history';

  /// The latest write; reads wait for it so a page never sees history from before the player's last save.
  static Future<void> _writing = Future.value();

  static Future<List<Map<String, dynamic>>> all() async {
    await _writing;
    return _read();
  }

  static Future<List<Map<String, dynamic>>> _read() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    return raw == null
        ? []
        : (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  }

  static Future<Map<String, dynamic>?> of(Map media) async =>
      (await all()).where((r) => r['media']['id'] == media['id']).firstOrNull;

  /// Past the "counts as watched" point set in Settings.
  static bool finished(Duration position, Duration duration) =>
      duration > Duration.zero &&
      position.inMilliseconds >
          duration.inMilliseconds * Settings.watchedPercent / 100;

  /// Records playing [episodes]`[index]` up to [position]. A finished episode moves the show on to the next one
  /// from its start, or out of history after the last; the first few seconds don't count as starting it.
  static Future<void> played(
    Map media, {
    required String source,
    required List<Episode> episodes,
    required int index,
    required Duration position,
    required Duration duration,
    required bool dub,
  }) => _writing = _writing
      .then(
        (_) => _played(
          media,
          source: source,
          episodes: episodes,
          index: index,
          position: position,
          duration: duration,
          dub: dub,
        ),
      )
      .catchError((Object _) {}); // one failed write mustn't block the rest

  static Future<void> _played(
    Map media, {
    required String source,
    required List<Episode> episodes,
    required int index,
    required Duration position,
    required Duration duration,
    required bool dub,
  }) async {
    if (position < const Duration(seconds: 5)) return;
    if (!finished(position, duration)) {
      return _save(
        media,
        source: source,
        episode: episodes[index].number,
        position: position,
        duration: duration,
        dub: dub,
      );
    }
    if (index + 1 >= episodes.length) return _remove(media);
    await _save(
      media,
      source: source,
      episode: episodes[index + 1].number,
      position: Duration.zero,
      dub: dub,
    );
  }

  static Future<void> _save(
    Map media, {
    required String source,
    required num episode,
    required Duration position,
    Duration? duration,
    required bool dub,
  }) async {
    final entries = [
      {
        'media': media,
        'source': source,
        'episode': episode,
        'position': position.inMilliseconds,
        'duration': ?duration?.inMilliseconds,
        'dub': dub,
        'at': DateTime.now().millisecondsSinceEpoch,
      },
      ...(await _read()).where((r) => r['media']['id'] != media['id']),
    ];
    await _write(entries.take(20).toList());
  }

  static Future<void> remove(Map media) async {
    await _writing;
    await _remove(media);
  }

  static Future<void> _remove(Map media) async => _write(
    (await _read()).where((r) => r['media']['id'] != media['id']).toList(),
  );

  static Future<void> clear() => _write(const []);

  static Future<void> _write(List<Map<String, dynamic>> entries) async {
    await (await SharedPreferences.getInstance()).setString(
      _key,
      jsonEncode(entries),
    );
    syncWatchNext(entries);
  }
}

/// A show's episode list as the details page shows it: [pageSize] at a time in the chosen order, opening on the
/// page that holds the next unwatched episode, with each episode's watched state and resume point.
class EpisodePlan {
  EpisodePlan(
    List<Episode> episodes, {
    required this.progress,
    this.record,
    bool newestFirst = false,
    int? page,
    int pageSize = 50,
  }) {
    final ordered = [...episodes]
      ..sort(
        (a, b) => newestFirst
            ? b.number.compareTo(a.number)
            : a.number.compareTo(b.number),
      );
    pages = [
      for (var i = 0; i < ordered.length; i += pageSize)
        ordered.skip(i).take(pageSize).toList(),
    ];
    upNext = ordered
        .where((e) => !watched(e))
        .fold<Episode?>(
          null,
          (low, e) => low == null || e.number < low.number ? e : low,
        );
    final holding = pages.indexWhere((p) => p.contains(upNext));
    this.page = pages.isEmpty
        ? 0
        : (page ?? (holding == -1 ? 0 : holding)).clamp(0, pages.length - 1);
  }

  /// Episodes marked watched on the tracker.
  final int progress;

  /// This show's [WatchHistory] entry, if any.
  final Map<String, dynamic>? record;

  late final List<List<Episode>> pages;

  /// The page to show: the one asked for, else the one holding [upNext].
  late final int page;

  /// The lowest-numbered episode not yet watched; null when all are.
  late final Episode? upNext;

  List<Episode> get shown => pages.isEmpty ? const [] : pages[page];

  bool watched(Episode e) => e.number <= progress;

  /// How far into [e] its saved resume point is, 0–1; null without one.
  double? resumedPart(Episode e) {
    final position = record?['position'] as int?;
    final duration = record?['duration'] as int?;
    if (record?['episode'] != e.number ||
        position == null ||
        duration == null ||
        duration <= 0) {
      return null;
    }
    return (position / duration).clamp(0.0, 1.0);
  }
}

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'anilist.dart';
import 'mal.dart';
import 'metadata.dart';

/// The app's list tracking, over AniList and MyAnimeList together.
///
/// Reads prefer AniList and fall back to MAL when it errors, so browsing keeps working while
/// AniList is down. Writes go to every signed-in service, so both lists stay current.
class Tracker {
  static bool get anilistIn => AniList.token != null;
  static bool get malIn => MAL.token != null;
  static bool get signedIn => anilistIn || malIn;

  static Future<void> load() => Future.wait([AniList.load(), MAL.load()]);

  static Future<T> _data<T>(
    Future<T> Function() anilist,
    Future<T> Function() mal,
  ) async {
    if (!AniList.usable) return mal();
    try {
      return await anilist();
    } catch (error) {
      if (!MAL.usable) rethrow;
      try {
        return await mal();
      } catch (_) {
        throw error; // AniList is the primary; report why it failed
      }
    }
  }

  /// Runs a write on every signed-in service. It fails only when they all do, so one flaky
  /// service can neither block tracking nor trigger the offline queue on its own.
  static Future<Map<String, dynamic>?> _write(
    Future<Map<String, dynamic>?> Function()? anilist,
    Future<Map<String, dynamic>?> Function()? mal,
  ) async {
    Map<String, dynamic>? saved;
    Object? failure;
    var ok = false;
    for (final write in [anilist, mal]) {
      if (write == null) continue;
      try {
        saved ??= await write();
        ok = true;
      } catch (e) {
        failure = e;
      }
    }
    if (!ok) throw failure ?? Exception('Sign in to track what you watch');
    return saved;
  }

  static final _ids = <String, Future<(int?, int?)>>{};

  /// Fills in whichever of the AniList/MAL ids a show is missing (MAL entries arrive without an
  /// AniList id, which streaming sources, downloads and history are keyed by). A show ani.zip
  /// doesn't know keeps a `mal:<id>` key instead, so it at least stays distinct from other shows.
  static Future<void> resolveIds(Map media) async {
    final id = media['id'], malId = media['idMal'];
    if ((id != null && malId != null) || (id == null && malId == null)) return;
    final (anilistId, resolvedMal) = await (_ids['${id ?? 'mal:$malId'}'] ??=
        idsOf(media));
    media['id'] ??= anilistId ?? 'mal:$malId';
    media['idMal'] ??= resolvedMal;
  }

  static Future<Map<String, dynamic>?> viewer() async {
    if (!anilistIn) return malIn ? MAL.viewer() : null;
    try {
      return await AniList.viewer();
    } catch (_) {
      return malIn ? MAL.viewer() : null;
    }
  }

  static Future<List> trending() => _data(AniList.trending, MAL.trending);

  static Future<List> season() => _data(AniList.season, MAL.season);

  static Future<List> search(String text) =>
      _data(() => AniList.search(text), () => MAL.search(text));

  static Future<List<(String, Map)>> relations(Map media) {
    Future<List<(String, Map)>> mal() async =>
        media['idMal'] == null ? const [] : MAL.relations(media['idMal']);
    if (media['id'] is! int) return mal();
    return _data(() => AniList.relations(media['id']), mal);
  }

  /// Watching (incl. rewatching) and planning entries of whichever service is signed in.
  static Future<Map<String, List>> lists() async {
    if (!anilistIn) return malIn ? MAL.lists() : {};
    try {
      return await AniList.lists();
    } catch (_) {
      if (!malIn) rethrow;
      return MAL.lists();
    }
  }

  /// The furthest progress any signed-in service has for a show, so a stale one can't roll it back.
  static Future<int> progressOf(Map media) async {
    await resolveIds(media);
    var best = -1;
    Object? failure;
    for (final read in [
      if (anilistIn && media['id'] is int)
        () => AniList.progressOf(media['id']),
      if (malIn && media['idMal'] != null) () => MAL.progressOf(media['idMal']),
    ]) {
      try {
        final progress = await read();
        if (progress > best) best = progress;
      } catch (e) {
        failure = e;
      }
    }
    if (best < 0 && failure != null) throw failure;
    return best < 0 ? 0 : best;
  }

  /// Sets a show's list status and progress everywhere; returns the saved entry.
  static Future<Map<String, dynamic>> saveEntry(
    Map media, {
    required String status,
    required int progress,
  }) async {
    await resolveIds(media);
    final saved = await _write(
      anilistIn && media['id'] is int
          ? () => AniList.saveEntry(
              media['id'],
              status: status,
              progress: progress,
            )
          : null,
      malIn && media['idMal'] != null
          ? () => MAL.saveEntry(
              media['idMal'],
              status: status,
              progress: progress,
            )
          : null,
    );
    return saved ?? {'status': status, 'progress': progress};
  }

  static Future<void> saveProgress(Map media, int progress) => saveEntry(
    media,
    status: progress == media['episodes'] ? 'COMPLETED' : 'CURRENT',
    progress: progress,
  );

  static Future<void> removeFromList(Map media) async {
    await resolveIds(media);
    await _write(
      anilistIn && media['id'] is int
          ? () async {
              await AniList.removeFromList(media['id']);
              return null;
            }
          : null,
      malIn && media['idMal'] != null
          ? () async {
              await MAL.removeFromList(media['idMal']);
              return null;
            }
          : null,
    );
  }

  static const _pendingKey = 'anilist_pending';
  static Future<int>? _syncing;

  static Map<String, dynamic> _pending(SharedPreferences prefs) =>
      jsonDecode(prefs.getString(_pendingKey) ?? '{}');

  /// Remembers progress made while no tracker could be reached so [syncPending] can push it later.
  static Future<void> queueProgress(Map media, int progress) async {
    final prefs = await SharedPreferences.getInstance();
    final pending = _pending(prefs);
    final key = '${media['id'] ?? 'mal:${media['idMal']}'}';
    final existing = pending[key]?['progress'] as int? ?? 0;
    if (progress <= existing) return;
    pending[key] = {'media': media, 'progress': progress};
    await prefs.setString(_pendingKey, jsonEncode(pending));
  }

  /// Pushes queued offline progress and returns how many shows were updated. Never rolls a list back.
  static Future<int> syncPending() =>
      _syncing ??= _syncPending().whenComplete(() => _syncing = null);

  static Future<int> _syncPending() async {
    if (!signedIn) return 0;
    final prefs = await SharedPreferences.getInstance();
    final pending = _pending(prefs);
    if (pending.isEmpty) return 0;
    var synced = 0;
    for (final MapEntry(:key, :value) in pending.entries.toList()) {
      try {
        final media = value['media'] as Map;
        final progress = value['progress'] as int;
        if (progress > await progressOf(media)) {
          await saveProgress(media, progress);
          synced++;
        }
        pending.remove(key);
      } catch (_) {
        break; // still offline; the rest stays queued
      }
    }
    await prefs.setString(_pendingKey, jsonEncode(pending));
    return synced;
  }
}

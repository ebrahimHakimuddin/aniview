import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'anilist.dart';
import 'mal.dart';
import 'metadata.dart';

/// Browsing and AniList tracking. Reads prefer AniList and fall back to MyAnimeList's public data
/// when it errors; saves go to AniList only and are kept on-device for the next app open when it fails.
class Tracker {
  static bool get signedIn => AniList.token != null;

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

  static final _ids = <String, (int?, int?)>{};

  /// Fills in whichever of the AniList/MAL ids a show is missing (MAL entries arrive without an
  /// AniList id, which streaming sources, downloads and history are keyed by). Until ani.zip answers,
  /// or for a show it doesn't know, the show keeps a `mal:<id>` key so it stays distinct from others.
  /// Returns false when ani.zip couldn't be reached, so the lookup is tried again next time.
  static Future<bool> resolveIds(Map media) async {
    final malId = media['idMal'];
    if (media['id'] is int ? malId != null : malId == null) return true;
    final key = '${media['id'] is int ? media['id'] : 'mal:$malId'}';
    try {
      final (anilistId, resolvedMal) = _ids[key] ??= await idsOf(media);
      if (anilistId != null) media['id'] = anilistId;
      media['idMal'] ??= resolvedMal;
      return true;
    } catch (_) {
      return false;
    } finally {
      media['id'] ??= 'mal:$malId';
    }
  }

  static Future<Map<String, dynamic>?> viewer() => AniList.viewer();

  static Future<List> trending() => _data(AniList.trending, MAL.trending);

  static Future<List> season() => _data(AniList.season, MAL.season);

  /// One page of results and whether there's another.
  static Future<(List, bool)> search(
    String text,
    SearchFilters filters, {
    int page = 1,
  }) => _data(
    () => AniList.search(text, filters, page),
    () => MAL.search(text, filters, page),
  );

  static Future<List<(String, Map)>> relations(Map media) {
    Future<List<(String, Map)>> mal() async =>
        media['idMal'] == null ? const [] : MAL.relations(media['idMal']);
    if (media['id'] is! int) return mal();
    return _data(() => AniList.relations(media['id']), mal);
  }

  /// Watching (incl. rewatching) and planning entries.
  static Future<Map<String, List>> lists() => AniList.lists();

  /// The list status after watching up to [progress]: completed on the last episode, otherwise
  /// watching (or still rewatching).
  static String statusFor(Map media, int progress) =>
      progress == media['episodes']
      ? 'COMPLETED'
      : media['mediaListEntry']?['status'] == 'REPEATING'
      ? 'REPEATING'
      : 'CURRENT';

  /// Saves progress to AniList, or queues it on-device for [syncPending] when AniList can't take it
  /// (down, or you're offline). Returns false when it was queued. [forwardOnly] (the player's
  /// automatic sync) never lowers AniList's progress.
  static Future<bool> save(
    Map media,
    int progress, {
    String? status,
    bool forwardOnly = false,
  }) async {
    status ??= statusFor(media, progress);
    final job = {
      'media': media,
      'progress': progress,
      'status': status,
      // MAL-sourced shows (browsed while AniList was down) don't know your AniList progress.
      'forwardOnly': forwardOnly && media['mediaListEntry'] == null,
    };
    media['mediaListEntry'] = {'progress': progress, 'status': status};
    if (await _push(job)) {
      syncPending().ignore(); // AniList answers again: send what was queued
      return true;
    }
    await _queue(job);
    return false;
  }

  /// Sends one save. True when it's done or can never apply (signed out, a show AniList doesn't
  /// have); false means try again later.
  static Future<bool> _push(Map job) async {
    if (!signedIn) return true;
    final media = job['media'] as Map;
    final progress = job['progress'] as int;
    if (!await resolveIds(media)) return false;
    final id = media['id'];
    if (id is! int) return true;
    try {
      // Jobs queued before 1.6.1 carry no flag and only ever moved forward.
      if (job['forwardOnly'] != false &&
          progress <= await AniList.progressOf(id)) {
        return true;
      }
      await AniList.saveEntry(
        id,
        status: job['status'] ?? statusFor(media, progress),
        progress: progress,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> removeFromList(Map media) async {
    await resolveIds(media);
    if (media['id'] is int) await AniList.removeFromList(media['id']);
  }

  static const _pendingKey = 'anilist_pending';
  static Future<int>? _syncing;

  static Map<String, dynamic> _pending(SharedPreferences prefs) =>
      jsonDecode(prefs.getString(_pendingKey) ?? '{}');

  /// One job per show; a newer save replaces the show's older one.
  static Future<void> _queue(Map job) async {
    final prefs = await SharedPreferences.getInstance();
    final media = job['media'] as Map;
    final pending = _pending(prefs);
    pending['${media['id'] ?? 'mal:${media['idMal']}'}'] = job;
    await prefs.setString(_pendingKey, jsonEncode(pending));
  }

  /// Retries queued saves and returns how many went through; the rest stay for next time.
  static Future<int> syncPending() =>
      _syncing ??= _syncPending().whenComplete(() => _syncing = null);

  static Future<int> _syncPending() async {
    final prefs = await SharedPreferences.getInstance();
    final sent = <String, String>{};
    for (final MapEntry(:key, :value) in _pending(prefs).entries) {
      if (await _push(value)) sent[key] = jsonEncode(value);
    }
    // Re-read: a save queued while this ran must not be overwritten.
    final pending = _pending(prefs)
      ..removeWhere((key, value) => sent[key] == jsonEncode(value));
    await prefs.setString(_pendingKey, jsonEncode(pending));
    return sent.length;
  }
}

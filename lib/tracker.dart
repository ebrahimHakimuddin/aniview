import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'analytics.dart';
import 'anilist.dart';
import 'mal.dart';
import 'metadata.dart';
import 'settings.dart';

/// Where browsing comes from. Both catalogues answer in AniList's shape (see [Show]); MyAnimeList's adapter maps
/// its own answers to it.
abstract interface class Catalog {
  /// Whether this build can use it (it has a client id).
  bool get usable;
  Future<List> trending();
  Future<List> season();

  /// One [page] of results and whether there's another. [text] may be empty to browse by [filters] alone.
  Future<(List, bool)> search(String text, SearchFilters filters, int page);

  /// Prequels and sequels as (PREQUEL|SEQUEL, show), prequels first.
  Future<List<(String, Map)>> relations(Map media);
}

class AniListCatalog implements Catalog {
  const AniListCatalog();
  @override
  bool get usable => AniList.usable;
  @override
  Future<List> trending() => AniList.trending();
  @override
  Future<List> season() => AniList.season();
  @override
  Future<(List, bool)> search(String text, SearchFilters filters, int page) =>
      AniList.search(text, filters, page);
  @override
  Future<List<(String, Map)>> relations(Map media) =>
      AniList.relations(media['id']);
}

class MalCatalog implements Catalog {
  const MalCatalog();
  @override
  bool get usable => MAL.usable;
  @override
  Future<List> trending() => MAL.trending();
  @override
  Future<List> season() => MAL.season();
  @override
  Future<(List, bool)> search(String text, SearchFilters filters, int page) =>
      MAL.search(text, filters, page);
  @override
  Future<List<(String, Map)>> relations(Map media) async =>
      media['idMal'] == null ? const [] : MAL.relations(media['idMal']);
}

/// What the player's automatic sync did with a watched episode.
enum SyncResult { skipped, saved, queued }

/// Browsing and AniList tracking. Reads prefer AniList and fall back to MyAnimeList's public data
/// when it errors; saves go to AniList only and are kept on-device for the next app open when it fails.
class Tracker {
  static bool get signedIn => AniList.token != null;

  /// Signs in to AniList; returns the account name, or null when the sheet was closed without signing in.
  static Future<String?> signIn(BuildContext context) async {
    if (AniList.clientId.isEmpty) {
      throw Exception(
        'This build has no AniList client id (--dart-define=ANILIST_CLIENT_ID)',
      );
    }
    await AniList.login(context);
    if (!signedIn) return null;
    final me = await AniList.viewer();
    Analytics.event('sign_in');
    return me?['name'] as String? ?? 'AniList user';
  }

  static Future<void> signOut() => AniList.logout();

  /// Browsing asks [primary] (AniList) and falls back to [fallback] (MyAnimeList); replaced in tests.
  @visibleForTesting
  static Catalog primary = const AniListCatalog(),
      fallback = const MalCatalog();

  static Future<T> _browse<T>(Future<T> Function(Catalog) ask) async {
    if (!primary.usable) return ask(fallback);
    try {
      return await ask(primary);
    } catch (error) {
      if (!fallback.usable) rethrow;
      try {
        return await ask(fallback);
      } catch (_) {
        throw error; // the primary's failure is the one to report
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

  static Future<List> trending() => _browse((c) => c.trending()).then(_safe);

  static Future<List> season() => _browse((c) => c.season()).then(_safe);

  /// One page of results and whether there's another.
  static Future<(List, bool)> search(
    String text,
    SearchFilters filters, {
    int page = 1,
  }) async {
    final (found, more) = await _browse((c) => c.search(text, filters, page));
    // Asking for the genre by name shows it anyway.
    return (filters.genres.contains('Ecchi') ? found : _safe(found), more);
  }

  /// Drops ecchi shows while [Settings.hideNsfw] is on.
  static List _safe(List shows) => !Settings.hideNsfw
      ? shows
      : [
          for (final m in shows)
            if (!(m['genres'] as List? ?? const []).contains('Ecchi')) m,
        ];

  /// A show only MyAnimeList knows (no AniList id yet) asks it directly.
  static Future<List<(String, Map)>> relations(Map media) => media['id'] is! int
      ? fallback.relations(media)
      : _browse((c) => c.relations(media));

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

  /// The player's sync once [episode] counts as watched: only signed in with sync on, and never pulling the list
  /// back when rewatching an earlier episode.
  static Future<SyncResult> watched(Map media, int episode) async {
    if (!signedIn || !Settings.syncAniList) return SyncResult.skipped;
    if (episode <= (media['mediaListEntry']?['progress'] as int? ?? 0)) {
      return SyncResult.skipped;
    }
    return await save(media, episode, forwardOnly: true)
        ? SyncResult.saved
        : SyncResult.queued;
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

import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'analytics.dart';
import 'anilist.dart';
import 'mal.dart';
import 'metadata.dart';
import 'settings.dart';
import 'ui.dart' show confirmDestructive, sheetTitle;
import 'states.dart' show showSheet;

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

/// A list entry being edited: its status and episodes watched move together. Reaching the [total] episodes
/// completes it; completing it counts them all.
class EntryDraft {
  EntryDraft({String? status, this.progress = 0, this.total})
    : status = status ?? 'CURRENT';

  String status;
  int progress;

  /// The show's episode count; null while unknown.
  final int? total;

  bool get canAdvance => total == null || progress < total!;

  void setProgress(int value) {
    progress = value.clamp(0, total ?? 9999);
    if (progress == total) status = 'COMPLETED';
  }

  void setStatus(String value) {
    status = value;
    if (value == 'COMPLETED' && total != null) progress = total!;
  }
}

/// The statuses of an AniList list entry, in the order they are offered.
enum ListStatus {
  current('CURRENT', 'Watching'),
  planning('PLANNING', 'Planning'),
  completed('COMPLETED', 'Completed'),
  paused('PAUSED', 'Paused'),
  dropped('DROPPED', 'Dropped'),
  repeating('REPEATING', 'Rewatching');

  const ListStatus(this.value, this.label);

  /// AniList's name for it, which the show maps carry, and what the person reads.
  final String value, label;

  /// Every status's label, by its value.
  static final labels = {for (final s in values) s.value: s.label};

  /// The ones a show can be moved to: rewatching is something watching turns into.
  static final movable = {
    for (final s in values)
      if (s != repeating) s.value: s.label,
  };
}

/// What the player's automatic sync did with a watched episode.
enum SyncResult { skipped, saved, queued }

/// A list-keeping account: where saves go and your list comes from.
abstract interface class ListProvider {
  String get name;

  /// Whether this build can sign in to it (it has a client id).
  bool get usable;
  bool get signedIn;

  /// Where its queued saves are kept.
  String get pendingKey;

  /// The show's id here; null when it has none (yet).
  int? idOf(Map media);
  Future<void> login(BuildContext context);
  Future<void> logout();
  Future<Map<String, dynamic>?> viewer();

  /// Your totals for Me, in the shape of [AniList.stats].
  Future<Map<String, dynamic>?> stats();
  Future<Map<String, List>> lists({bool all = false});
  Future<int> progressOf(int id);
  Future<void> save(int id, {required String status, required int progress});
  Future<void> remove(int id);

  /// The field of a pairing message that carries this account's sign-in (see [Tracker.shareable]).
  String get shareKey;

  /// The sign-in a paired TV can use; null when signed out.
  Object? get shareable;

  /// Signs in with what a paired phone shared.
  Future<void> useShared(Object shared);
}

class _AniListProvider implements ListProvider {
  const _AniListProvider();
  @override
  String get name => 'AniList';
  @override
  bool get usable => AniList.usable;
  @override
  bool get signedIn => AniList.token != null;
  @override
  String get pendingKey => 'anilist_pending';
  @override
  int? idOf(Map media) => media['id'] is int ? media['id'] : null;
  @override
  Future<void> login(BuildContext context) => AniList.login(context);
  @override
  Future<void> logout() => AniList.logout();
  @override
  Future<Map<String, dynamic>?> viewer() => AniList.viewer();
  @override
  Future<Map<String, dynamic>?> stats() => AniList.stats();
  @override
  Future<Map<String, List>> lists({bool all = false}) =>
      AniList.lists(all: all);
  @override
  Future<int> progressOf(int id) => AniList.progressOf(id);
  @override
  Future<void> save(int id, {required String status, required int progress}) =>
      AniList.saveEntry(id, status: status, progress: progress);
  @override
  Future<void> remove(int id) => AniList.removeFromList(id);
  @override
  String get shareKey => 'token';
  @override
  Object? get shareable => AniList.token;
  @override
  Future<void> useShared(Object shared) => AniList.useToken(shared as String);
}

class _MalProvider implements ListProvider {
  const _MalProvider();
  @override
  String get name => 'MyAnimeList';
  @override
  bool get usable => MAL.usable;
  @override
  bool get signedIn => MAL.signedIn;
  @override
  String get pendingKey => 'mal_pending';
  @override
  int? idOf(Map media) => media['idMal'];
  @override
  Future<void> login(BuildContext context) => MAL.login(context);
  @override
  Future<void> logout() => MAL.logout();
  @override
  Future<Map<String, dynamic>?> viewer() => MAL.viewer();
  @override
  Future<Map<String, dynamic>?> stats() => MAL.stats();
  @override
  Future<Map<String, List>> lists({bool all = false}) => MAL.lists(all: all);
  @override
  Future<int> progressOf(int id) => MAL.progressOf(id);
  @override
  Future<void> save(int id, {required String status, required int progress}) =>
      MAL.saveEntry(id, status: status, progress: progress);
  @override
  Future<void> remove(int id) => MAL.removeFromList(id);
  @override
  String get shareKey => 'mal';
  @override
  Object? get shareable => MAL.shareable;
  @override
  Future<void> useShared(Object shared) => MAL.useShared(shared as Map);
}

/// Browsing, and list tracking on AniList or MyAnimeList: one account at a time, where your list is read from and
/// saves go. Browsing and social stay on AniList (reads fall back to MyAnimeList's public data when it errors).
class Tracker {
  static const anilist = _AniListProvider();
  static const mal = _MalProvider();

  /// Every account that can be signed in to; replaced in tests.
  @visibleForTesting
  static List<ListProvider> accounts = const [anilist, mal];

  static Future<void> load() async {
    await Future.wait([AniList.load(), MAL.load()]);
    // Before accounts were exclusive both could be signed in: keep the one signed in to first.
    final prefs = await SharedPreferences.getInstance();
    final order = prefs.getStringList('tracker_order') ?? const [];
    final both = accounts.where((p) => p.signedIn).toList();
    if (both.length > 1) {
      final keep = both.firstWhere(
        (p) => p.name == order.firstOrNull,
        orElse: () => both.first,
      );
      for (final p in both) {
        if (p != keep) await signOut(p);
      }
    }
    await prefs.remove('tracker_order');
  }

  /// The account signed in to, if any.
  static ListProvider? get account =>
      accounts.where((p) => p.signedIn).firstOrNull;

  static bool get signedIn => account != null;

  /// The account's sign-in for a paired TV, under its [ListProvider.shareKey]; empty when signed out.
  static Map<String, Object> get shareable => {
    if (account case final p?) p.shareKey: ?p.shareable,
  };

  /// Signs in with what a paired phone sent as [shareable]; false when it sent no sign-in.
  static Future<bool> useShared(Map sent) async {
    for (final p in accounts) {
      if (sent[p.shareKey] case final Object shared) {
        await p.useShared(shared);
        return true;
      }
    }
    return false;
  }

  /// AniList in particular, which social, stats and notifications need.
  static bool get anilistSignedIn => anilist.signedIn;

  /// Chooses an account when [provider] is omitted; returns the account name, or null when the sheet was closed without
  /// signing in.
  static Future<String?> signIn(
    BuildContext context, [
    ListProvider? provider,
  ]) async {
    provider ??= await showSheet<ListProvider>(
      context,
      (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            sheetTitle(sheet, 'Sign in'),
            for (final account in accounts)
              ListTile(
                leading: const Icon(Icons.person_outline_rounded),
                title: Text('Sign in with ${account.name}'),
                subtitle: account.signedIn
                    ? const Text('Already signed in')
                    : null,
                onTap: account.signedIn
                    ? null
                    : () => Navigator.pop(sheet, account),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (provider == null || !context.mounted) return null;
    if (!provider.usable) {
      throw Exception('This build has no ${provider.name} client id');
    }
    // One account at a time: switching signs the other out, once this one has signed in.
    final other = account;
    if (other != null &&
        other != provider &&
        !await confirmDestructive(
          context,
          title: 'Switch to ${provider.name}?',
          message:
              'You\'ll be signed out of ${other.name}. Your list and progress then come from ${provider.name}.',
          action: 'Switch',
        )) {
      return null;
    }
    if (!context.mounted) return null;
    await provider.login(context);
    if (!provider.signedIn) return null;
    if (other != null && other != provider) await signOut(other);
    Analytics.event('sign_in', {'tracker': provider.name});
    final me = await provider.viewer().catchError((Object _) => null);
    return me?['name'] as String? ?? '${provider.name} user';
  }

  /// Signs out and drops its saves still queued, so the next account never sends the last one's.
  static Future<void> signOut(ListProvider provider) async {
    await provider.logout();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(provider.pendingKey);
    Settings.welcomeName = null; // the next greeting asks whoever is left
  }

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

  static Future<Map<String, dynamic>?> viewer() async => account?.viewer();

  static Future<Map<String, dynamic>?> stats() async => account?.stats();

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

  static bool _ecchi(Map media) =>
      (media['genres'] as List? ?? const []).contains('Ecchi');

  /// Drops ecchi shows while [Settings.hideNsfw] is on.
  static List _safe(List shows) => !Settings.hideNsfw
      ? shows
      : [
          for (final m in shows)
            if (!_ecchi(m)) m,
        ];

  /// This week's episodes of the popular shows airing now (see [AniList.airingPopular]), without the ecchi ones
  /// while [Settings.hideNsfw] is on.
  static Future<List<Map>> airingPopular() async => [
    for (final s in await AniList.airingPopular())
      if (!Settings.hideNsfw || !_ecchi(s['media'] as Map)) s,
  ];

  /// A show only MyAnimeList knows (no AniList id yet) asks it directly.
  static Future<List<(String, Map)>> relations(Map media) => media['id'] is! int
      ? fallback.relations(media)
      : _browse((c) => c.relations(media));

  /// The account's watching (incl. rewatching) and planning entries; with [all], every list.
  static Future<Map<String, List>> lists({bool all = false}) async =>
      await account?.lists(all: all) ?? {};

  /// The list status after watching up to [progress]: completed on the last episode, otherwise
  /// watching (or still rewatching).
  static String statusFor(Map media, int progress) =>
      progress == media['episodes']
      ? 'COMPLETED'
      : media['mediaListEntry']?['status'] == 'REPEATING'
      ? 'REPEATING'
      : 'CURRENT';

  /// Saves progress to the account; when it can't take it (down, or you're offline) it's queued on-device for
  /// [syncPending]. Returns false when it was queued. [forwardOnly] (the player's automatic sync) never lowers the
  /// account's progress. A [status] of COMPLETED counts
  /// every episode watched.
  static Future<bool> save(
    Map media,
    int progress, {
    String? status,
    bool forwardOnly = false,
  }) async {
    status ??= statusFor(media, progress);
    if (status == 'COMPLETED') progress = media['episodes'] as int? ?? progress;
    final job = {
      'media': media,
      'progress': progress,
      'status': status,
      // Checked against the account's progress: the show's entry may be stale (watched on another device since).
      'forwardOnly': forwardOnly,
    };
    media['mediaListEntry'] = {'progress': progress, 'status': status};
    final p = account;
    if (p == null) return true;
    if (!await _push(p, job)) {
      await _queue(p, job);
      return false;
    }
    syncPending().ignore(); // answering again: send what was queued
    return true;
  }

  /// Sends one save to [p]. True when it's done or can never apply (signed out, a show [p] doesn't have); false
  /// means try again later.
  static Future<bool> _push(ListProvider p, Map job) async {
    if (!p.signedIn) return true;
    final media = job['media'] as Map;
    final progress = job['progress'] as int;
    var id = p.idOf(media);
    if (id == null) {
      if (!await resolveIds(media)) return false;
      id = p.idOf(media);
      if (id == null) return true; // not on this service: skipped
    }
    try {
      // Jobs queued before 1.6.1 carry no flag and only ever moved forward.
      if (job['forwardOnly'] != false && progress <= await p.progressOf(id)) {
        return true;
      }
      await p.save(
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

  /// A show to watch at random: from your Planning list when [Settings.randomFrom] says so and it has any, else
  /// from the 1000 most popular that you aren't watching and haven't completed. Null when there's none.
  static Future<Map?> random() async {
    final pick = Random();
    if (Settings.randomFrom == 'planning' && signedIn) {
      final planning = (await lists())['PLANNING'] ?? const [];
      if (planning.isNotEmpty) return planning[pick.nextInt(planning.length)];
    }
    final (shows, _) = await search(
      '',
      const SearchFilters(sort: 'POPULARITY_DESC', unwatched: true),
      page: pick.nextInt(25) + 1,
    );
    return shows.isEmpty ? null : shows[pick.nextInt(shows.length)];
  }

  /// Removes the show from the account's list; a failure is reported.
  static Future<void> removeFromList(Map media) async {
    await resolveIds(media);
    if (account case final p?) {
      if (p.idOf(media) case final id?) await p.remove(id);
    }
    media['mediaListEntry'] = null;
  }

  static Future<int>? _syncing;

  static Map<String, dynamic> _pending(
    SharedPreferences prefs,
    ListProvider p,
  ) => jsonDecode(prefs.getString(p.pendingKey) ?? '{}');

  /// One job per show and account; a newer save replaces the show's older one.
  static Future<void> _queue(ListProvider p, Map job) async {
    final prefs = await SharedPreferences.getInstance();
    final media = job['media'] as Map;
    final pending = _pending(prefs, p);
    pending['${media['id'] ?? 'mal:${media['idMal']}'}'] = job;
    await prefs.setString(p.pendingKey, jsonEncode(pending));
  }

  /// Retries queued saves and returns how many went through; the rest stay for next time.
  static Future<int> syncPending() =>
      _syncing ??= _syncPending().whenComplete(() => _syncing = null);

  static Future<int> _syncPending() async {
    final prefs = await SharedPreferences.getInstance();
    var total = 0;
    for (final p in accounts) {
      final sent = <String, String>{};
      for (final MapEntry(:key, :value) in _pending(prefs, p).entries) {
        // Signed out (or the token just expired): keep the rest for when you sign in again.
        if (!p.signedIn) break;
        if (await _push(p, value)) sent[key] = jsonEncode(value);
      }
      // Re-read: a save queued while this ran must not be overwritten.
      final pending = _pending(prefs, p)
        ..removeWhere((key, value) => sent[key] == jsonEncode(value));
      await prefs.setString(p.pendingKey, jsonEncode(pending));
      total += sent.length;
    }
    return total;
  }
}

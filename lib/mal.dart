import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'anilist.dart';
import 'desktop/sign_in.dart';
import 'platform.dart';

/// MyAnimeList's API v2: public browsing, a stand-in for AniList's when it is down, and (signed in) your list.
/// Answers with AniList-shaped media maps so the rest of the app can't tell them apart.
class MAL {
  static const clientId = String.fromEnvironment('MAL_CLIENT_ID');
  static const _fields =
      'id,title,alternative_titles,main_picture,synopsis,mean,genres,media_type,'
      'status,start_season,num_episodes';

  static bool get usable => clientId.isNotEmpty;

  static const _redirect = 'aniview://mal';
  static String? _access, _refresh;
  static DateTime? _expires;
  static Map<String, dynamic>? _viewer;

  static bool get signedIn => _access != null;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _access = prefs.getString('mal_access');
    _refresh = prefs.getString('mal_refresh');
    _expires = DateTime.tryParse(prefs.getString('mal_expires') ?? '');
  }

  /// Authorization code with PKCE (MAL has no implicit grant): the browser comes back to `aniview://mal?code=…`.
  static Future<void> login(BuildContext context) async {
    final random = Random.secure();
    String token(int n) => base64Url
        .encode([for (var i = 0; i < n; i++) random.nextInt(256)])
        .replaceAll('=', '');
    // MAL only supports the "plain" method, where the challenge is the verifier itself.
    final verifier = token(48), state = token(12);
    final url =
        'https://myanimelist.net/v1/oauth2/authorize?response_type=code&client_id=$clientId'
        '&code_challenge=$verifier&code_challenge_method=plain&state=$state'
        '&redirect_uri=${Uri.encodeComponent(_redirect)}';
    String? pick(Uri uri) => uri.queryParameters['state'] == state
        ? uri.queryParameters['code']
        : null;
    final code = isDesktop
        ? await signInInBrowser(
            context,
            url,
            name: 'MyAnimeList',
            callbackHost: 'mal',
            pick: pick,
          )
        : await Navigator.of(context).push<String>(
            MaterialPageRoute(
              fullscreenDialog: true,
              builder: (_) => LoginPage(
                title: 'Sign in with MyAnimeList',
                url: url,
                pick: pick,
              ),
            ),
          );
    if (code == null || code.isEmpty) return;
    await _grant({
      'grant_type': 'authorization_code',
      'code': code,
      'code_verifier': verifier,
      'redirect_uri': _redirect,
    });
  }

  static Future<void> _grant(Map<String, String> form) async {
    final res = await http.post(
      Uri.https('myanimelist.net', '/v1/oauth2/token'),
      body: {'client_id': clientId, ...form},
    );
    if (res.statusCode != 200) {
      // A refresh token MAL no longer honours means signing in again.
      if (form['grant_type'] == 'refresh_token') await logout();
      throw Exception('MyAnimeList: sign-in failed (HTTP ${res.statusCode})');
    }
    final json = jsonDecode(res.body);
    _access = json['access_token'];
    _refresh = json['refresh_token'];
    _expires = DateTime.now().add(Duration(seconds: json['expires_in'] as int));
    _viewer = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mal_access', _access!);
    await prefs.setString('mal_refresh', _refresh!);
    await prefs.setString('mal_expires', _expires!.toIso8601String());
  }

  /// What a paired TV signs in with ({access, expires}); null signed out. Never the refresh token: if MyAnimeList
  /// retires one once it's used, a TV renewing would sign the phone out. The TV signs out when the access expires.
  static Map<String, String>? get shareable => _access == null
      ? null
      : {'access': _access!, 'expires': ?_expires?.toIso8601String()};

  /// Signs in with what a paired phone [shareable]d.
  static Future<void> useShared(Map shared) async {
    await logout();
    _access = shared['access'] as String;
    _expires = DateTime.tryParse(shared['expires'] as String? ?? '');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mal_access', _access!);
    if (_expires != null) {
      await prefs.setString('mal_expires', _expires!.toIso8601String());
    }
  }

  static Future<void> logout() async {
    _access = _refresh = _expires = _viewer = null;
    final prefs = await SharedPreferences.getInstance();
    for (final key in ['mal_access', 'mal_refresh', 'mal_expires']) {
      await prefs.remove(key);
    }
  }

  /// The access token, renewed first when it has under a day left (they last a month).
  static Future<String> _bearer() async {
    if (_access == null) throw Exception('Not signed in to MyAnimeList');
    if (_refresh != null &&
        (_expires?.isBefore(DateTime.now().add(const Duration(days: 1))) ??
            false)) {
      await _grant({'grant_type': 'refresh_token', 'refresh_token': _refresh!});
    }
    return _access!;
  }

  static Future<Map<String, dynamic>> _mine(
    String method,
    String path, {
    Map<String, String> query = const {},
    Map<String, String>? form,
  }) async {
    final request = http.Request(
      method,
      Uri.https('api.myanimelist.net', '/v2/$path', query),
    )..headers['Authorization'] = 'Bearer ${await _bearer()}';
    if (form != null) request.bodyFields = form;
    final res = await http.Response.fromStream(await request.send());
    if (res.statusCode == 401) await logout();
    // Deleting what isn't on the list is already done.
    if (res.statusCode == 404 && method == 'DELETE') return {};
    if (res.statusCode == 429) {
      throw Exception(
        'MyAnimeList is getting too many requests. Try again shortly',
      );
    }
    if (res.statusCode ~/ 100 != 2) {
      throw Exception('MyAnimeList: HTTP ${res.statusCode}');
    }
    return res.body.isEmpty ? {} : jsonDecode(res.body);
  }

  /// {name, avatar:{large}} in AniList's shape.
  static Future<Map<String, dynamic>?> viewer() async {
    if (!signedIn) return null;
    return _viewer ??= await _mine('GET', 'users/@me').then(
      (me) => {
        'name': me['name'],
        'avatar': {'large': me['picture']},
      },
    );
  }

  /// Your totals in the shape of [AniList.stats]. MyAnimeList keeps no activity history, so there's none.
  static Future<Map<String, dynamic>?> stats() async {
    if (!signedIn) return null;
    final s =
        (await _mine(
              'GET',
              'users/@me',
              query: {'fields': 'anime_statistics'},
            ))['anime_statistics']
            as Map? ??
        const {};
    int n(String key) => (s[key] as num? ?? 0).toInt();
    return {
      'statistics': {
        'anime': {
          'count': n('num_items'),
          'episodesWatched': n('num_episodes'),
          'minutesWatched': ((s['num_days_watched'] as num? ?? 0) * 1440)
              .round(),
          'statuses': [
            for (final (status, key) in const [
              ('CURRENT', 'num_items_watching'),
              ('PLANNING', 'num_items_plan_to_watch'),
              ('COMPLETED', 'num_items_completed'),
              ('PAUSED', 'num_items_on_hold'),
              ('DROPPED', 'num_items_dropped'),
            ])
              {'status': status, 'count': n(key)},
          ],
        },
      },
    };
  }

  // AniList's list statuses and MAL's; rewatching is a flag on a completed entry there, as its site shows it.
  static const _toMal = {
    'CURRENT': 'watching',
    'REPEATING': 'completed',
    'PLANNING': 'plan_to_watch',
    'COMPLETED': 'completed',
    'PAUSED': 'on_hold',
    'DROPPED': 'dropped',
  };

  static Future<int> progressOf(int malId) async =>
      (await _mine(
        'GET',
        'anime/$malId',
        query: {'fields': 'my_list_status'},
      ))['my_list_status']?['num_episodes_watched'] ??
      0;

  static Future<void> saveEntry(
    int malId, {
    required String status,
    required int progress,
  }) => _mine(
    'PATCH',
    'anime/$malId/my_list_status',
    form: {
      'status': _toMal[status] ?? 'watching',
      'num_watched_episodes': '$progress',
      'is_rewatching': '${status == 'REPEATING'}',
    },
  );

  static Future<void> removeFromList(int malId) =>
      _mine('DELETE', 'anime/$malId/my_list_status');

  /// Your list in the shape of [AniList.lists]; each show carries its `mediaListEntry`.
  static Future<Map<String, List>> lists({bool all = false}) async {
    final out = <String, List>{
      'CURRENT': [],
      'PLANNING': [],
      if (all) ...{'COMPLETED': [], 'PAUSED': [], 'DROPPED': []},
    };
    const back = {
      'watching': 'CURRENT',
      'plan_to_watch': 'PLANNING',
      'completed': 'COMPLETED',
      'on_hold': 'PAUSED',
      'dropped': 'DROPPED',
    };
    for (var offset = 0; ; offset += 1000) {
      final json = await _mine(
        'GET',
        'users/@me/animelist',
        query: {
          'fields': '$_fields,list_status',
          'sort': 'list_updated_at',
          'nsfw': 'true',
          'limit': '1000',
          'offset': '$offset',
        },
      );
      for (final e in json['data'] as List? ?? const []) {
        final entry = e['list_status'] as Map;
        final key = back[entry['status']];
        final repeating = entry['is_rewatching'] == true;
        final m = media(e['node'])
          ..['mediaListEntry'] = {
            'status': repeating ? 'REPEATING' : key,
            'progress': entry['num_episodes_watched'] ?? 0,
          };
        // Rewatching sits with watching, as AniList lists it.
        out[repeating ? 'CURRENT' : key]?.add(m);
      }
      if (json['paging']?['next'] == null) break;
    }
    await _withAniListIds(out.values.expand((l) => l));
    return out;
  }

  /// AniList ids by MAL id, as far as they're known; null for a show AniList doesn't have, so it isn't asked again.
  static final _anilistIds = <int, int?>{};

  /// Fills in the AniList ids of [shows], which Schedule, airing times and episode notifications go by. AniList
  /// being down leaves them for each show's page to fill in (`Tracker.resolveIds`).
  static Future<void> _withAniListIds(Iterable shows) async {
    final unknown = {
      for (final m in shows)
        if (!_anilistIds.containsKey(m['idMal'])) m['idMal'] as int,
    };
    try {
      if (unknown.isNotEmpty) {
        final found = await AniList.idsByMal(unknown.toList());
        for (final id in unknown) {
          _anilistIds[id] = found[id];
        }
      }
    } catch (_) {}
    for (final m in shows) {
      m['id'] ??= _anilistIds[m['idMal']];
    }
  }

  static Future<Map<String, dynamic>> _get(
    String path,
    Map<String, String> query,
  ) async {
    final res = await http.get(
      Uri.https('api.myanimelist.net', '/v2/$path', query),
      headers: {'X-MAL-CLIENT-ID': clientId},
    );
    if (res.statusCode != 200) {
      throw Exception('MyAnimeList: HTTP ${res.statusCode}');
    }
    return jsonDecode(res.body);
  }

  static const _formats = {
    'tv': 'TV',
    'tv_special': 'TV_SHORT',
    'ova': 'OVA',
    'ona': 'ONA',
    'movie': 'MOVIE',
    'special': 'SPECIAL',
    'music': 'MUSIC',
  };
  static const _statuses = {
    'finished_airing': 'FINISHED',
    'currently_airing': 'RELEASING',
    'not_yet_aired': 'NOT_YET_RELEASED',
  };

  /// A MAL anime node as the AniList media map the app is built around. `id` (the AniList id) is
  /// unknown here and gets filled in from ani.zip by `Tracker.resolveIds` when a show is opened.
  static Map<String, dynamic> media(Map node) {
    final picture =
        node['main_picture']?['large'] ?? node['main_picture']?['medium'];
    final episodes = node['num_episodes'] as int?;
    final mean = node['mean'] as num?;
    return {
      'id': null,
      'idMal': node['id'],
      'title': {
        'userPreferred': node['title'],
        'romaji': node['title'],
        'english': node['alternative_titles']?['en'],
      },
      'coverImage': {'extraLarge': picture, 'large': picture, 'color': null},
      'bannerImage': null,
      'episodes': episodes == 0 ? null : episodes,
      'description': node['synopsis'],
      'averageScore': mean == null ? null : (mean * 10).round(),
      'genres': [
        for (final g in node['genres'] as List? ?? const []) g['name'],
      ],
      'format': _formats[node['media_type']],
      'status': _statuses[node['status']],
      'season': (node['start_season']?['season'] as String?)?.toUpperCase(),
      'seasonYear': node['start_season']?['year'],
      'nextAiringEpisode': null,
      'mediaListEntry': null, // unknown: MAL can't see your AniList list
    };
  }

  static List<Map<String, dynamic>> _list(Map<String, dynamic> json) => [
    for (final e in json['data'] as List? ?? const []) media(e['node']),
  ];

  static Future<List> trending() async => _list(
    await _get('anime/ranking', {
      'ranking_type': 'airing',
      'limit': '20',
      'fields': _fields,
    }),
  );

  static Future<List> season() async {
    final (season, year) = AniList.currentSeason;
    return _list(
      await _get('anime/season/$year/${season.toLowerCase()}', {
        'sort': 'anime_num_list_users',
        'limit': '20',
        'fields': _fields,
      }),
    );
  }

  /// MAL can't filter or sort a search, so filters apply to each fetched page and sorting is ignored.
  static Future<(List, bool)> search(
    String text, [
    SearchFilters filters = const SearchFilters(),
    int page = 1,
  ]) async {
    final (season, year) = (filters.season, filters.year);
    final paging = {'limit': '100', 'offset': '${(page - 1) * 100}'};
    final json = text.isNotEmpty
        ? await _get('anime', {'q': text, ...paging, 'fields': _fields})
        : season != null && year != null
        ? await _get('anime/season/$year/${season.toLowerCase()}', {
            'sort': 'anime_num_list_users',
            ...paging,
            'fields': _fields,
          })
        : await _get('anime/ranking', {
            'ranking_type': 'bypopularity',
            ...paging,
            'fields': _fields,
          });
    return (
      _list(json).where(filters.matches).toList(),
      json['paging']?['next'] != null,
    );
  }

  /// Anime prequels and sequels as (PREQUEL|SEQUEL, media), prequels first.
  static Future<List<(String, Map)>> relations(int malId) async {
    final json = await _get('anime/$malId', {
      'fields': 'related_anime{$_fields}',
    });
    return [
      for (final e in json['related_anime'] as List? ?? const [])
        if (e['relation_type'] == 'prequel' || e['relation_type'] == 'sequel')
          ((e['relation_type'] as String).toUpperCase(), media(e['node'])),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
  }
}

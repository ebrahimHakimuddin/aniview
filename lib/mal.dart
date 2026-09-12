import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'anilist.dart';

/// MyAnimeList (API v2) as a stand-in for AniList: OAuth2 sign-in plus the same
/// calls, answering with AniList-shaped media maps so the rest of the app can't tell them apart.
class MAL {
  static const clientId = String.fromEnvironment('MAL_CLIENT_ID');
  static const _redirect = 'aniview://auth';
  static const _fields =
      'id,title,alternative_titles,main_picture,synopsis,mean,genres,media_type,'
      'status,start_season,num_episodes,my_list_status{status,num_episodes_watched,is_rewatching}';

  static String? token, _refresh;
  static Map<String, dynamic>? _viewer;

  /// MAL can answer public queries with just the client id, so it covers for AniList signed out too.
  static bool get usable => clientId.isNotEmpty;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    token = prefs.getString('mal_token');
    _refresh = prefs.getString('mal_refresh');
  }

  /// Authorization code flow with PKCE. MAL only implements the `plain` challenge, so the verifier is the challenge.
  static Future<void> login(BuildContext context) async {
    final verifier = List.generate(
      64,
      (_) =>
          'abcdefghijklmnopqrstuvwxyz0123456789'[Random.secure().nextInt(36)],
    ).join();
    final redirect = await oauthRedirect(
      context,
      'Sign in with MyAnimeList',
      'https://myanimelist.net/v1/oauth2/authorize?response_type=code'
          '&client_id=$clientId&code_challenge=$verifier&code_challenge_method=plain'
          '&redirect_uri=${Uri.encodeQueryComponent(_redirect)}',
    );
    final code = redirect?.queryParameters['code'];
    if (code == null) return; // closed without authorizing
    await _token({
      'grant_type': 'authorization_code',
      'code': code,
      'code_verifier': verifier,
      'redirect_uri': _redirect,
    });
  }

  static Future<void> logout() async {
    token = _refresh = null;
    _viewer = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('mal_token');
    await prefs.remove('mal_refresh');
  }

  static Future<void> _token(Map<String, String> body) async {
    final res = await http.post(
      Uri.parse('https://myanimelist.net/v1/oauth2/token'),
      body: {'client_id': clientId, ...body},
    );
    if (res.statusCode != 200) {
      throw Exception('MyAnimeList sign-in failed (HTTP ${res.statusCode})');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    token = json['access_token'] as String;
    _refresh = json['refresh_token'] as String?;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mal_token', token!);
    if (_refresh != null) await prefs.setString('mal_refresh', _refresh!);
  }

  /// MAL tokens last a month; a 401 means it's time to swap the refresh token for a new one.
  static Future<bool> _renew() async {
    if (_refresh == null) return false;
    try {
      await _token({'grant_type': 'refresh_token', 'refresh_token': _refresh!});
      return true;
    } catch (_) {
      await logout();
      return false;
    }
  }

  static Future<Map<String, dynamic>> _call(
    String method,
    String path, {
    Map<String, String> query = const {},
    Map<String, String>? body,
    bool retry = true,
  }) async {
    final request =
        http.Request(
            method,
            Uri.https(
              'api.myanimelist.net',
              '/v2/$path',
              query.isEmpty ? null : query,
            ),
          )
          ..headers.addAll({
            if (token != null)
              'Authorization': 'Bearer $token'
            else
              'X-MAL-CLIENT-ID': clientId,
          });
    if (body != null) request.bodyFields = body;
    final res = await http.Response.fromStream(await request.send());
    if (res.statusCode == 401 && token != null && retry && await _renew()) {
      return _call(method, path, query: query, body: body, retry: false);
    }
    if (res.statusCode >= 400) {
      throw Exception(
        'MyAnimeList: ${jsonDecode(res.body)['message'] ?? 'HTTP ${res.statusCode}'}',
      );
    }
    return res.body.isEmpty ? const {} : jsonDecode(res.body);
  }

  static Future<Map<String, dynamic>?> viewer() async {
    if (token == null) return null;
    if (_viewer != null) return _viewer;
    final me = await _call(
      'GET',
      'users/@me',
      query: {'fields': 'id,name,picture'},
    );
    return _viewer = {
      'id': me['id'],
      'name': me['name'],
      'avatar': {'large': me['picture']},
    };
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
  static const _listStatuses = {
    'watching': 'CURRENT',
    'completed': 'COMPLETED',
    'on_hold': 'PAUSED',
    'dropped': 'DROPPED',
    'plan_to_watch': 'PLANNING',
  };

  /// MAL's list status for an AniList one. REPEATING is "watching" again, which is what MAL calls it too.
  static String malStatus(String anilistStatus) => anilistStatus == 'REPEATING'
      ? 'watching'
      : _listStatuses.entries
            .firstWhere(
              (e) => e.value == anilistStatus,
              orElse: () => const MapEntry('watching', 'CURRENT'),
            )
            .key;

  /// A MAL anime node as the AniList media map the app is built around. `id` (the AniList id) is
  /// unknown here and gets filled in from ani.zip by `Tracker.resolveIds` when a show is opened.
  static Map<String, dynamic> media(Map node) {
    final picture =
        node['main_picture']?['large'] ?? node['main_picture']?['medium'];
    final entry = node['my_list_status'] as Map?;
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
      'mediaListEntry': entry == null
          ? null
          : {
              'progress': entry['num_episodes_watched'] ?? 0,
              'status': entry['is_rewatching'] == true
                  ? 'REPEATING'
                  : _listStatuses[entry['status']],
            },
    };
  }

  static List<Map<String, dynamic>> _list(Map<String, dynamic> json) => [
    for (final e in json['data'] as List? ?? const []) media(e['node']),
  ];

  static Future<List> trending() async => _list(
    await _call(
      'GET',
      'anime/ranking',
      query: {'ranking_type': 'airing', 'limit': '20', 'fields': _fields},
    ),
  );

  static Future<List> season() async {
    final (season, year) = AniList.currentSeason;
    return _list(
      await _call(
        'GET',
        'anime/season/$year/${season.toLowerCase()}',
        query: {
          'sort': 'anime_num_list_users',
          'limit': '20',
          'fields': _fields,
        },
      ),
    );
  }

  static Future<List> search(String text) async => _list(
    await _call(
      'GET',
      'anime',
      query: {'q': text, 'limit': '40', 'fields': _fields},
    ),
  );

  /// Anime prequels and sequels as (PREQUEL|SEQUEL, media), prequels first.
  static Future<List<(String, Map)>> relations(int malId) async {
    final json = await _call(
      'GET',
      'anime/$malId',
      query: {'fields': 'related_anime{$_fields}'},
    );
    return [
      for (final e in json['related_anime'] as List? ?? const [])
        if (e['relation_type'] == 'prequel' || e['relation_type'] == 'sequel')
          ((e['relation_type'] as String).toUpperCase(), media(e['node'])),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
  }

  /// Watching (incl. rewatching) and planning entries, most recently updated first.
  static Future<Map<String, List>> lists() async {
    if (token == null) return {};
    Future<List> of(String status) async => _list(
      await _call(
        'GET',
        'users/@me/animelist',
        query: {
          'status': status,
          'sort': 'list_updated_at',
          'limit': '1000',
          'fields': _fields,
        },
      ),
    );
    final [current, planning] = await Future.wait([
      of('watching'),
      of('plan_to_watch'),
    ]);
    return {'CURRENT': current, 'PLANNING': planning};
  }

  static Future<int> progressOf(int malId) async =>
      (await _call(
        'GET',
        'anime/$malId',
        query: {'fields': 'my_list_status'},
      ))['my_list_status']?['num_episodes_watched'] ??
      0;

  /// Sets a show's list status and progress (adds it to the list if needed); returns the saved entry.
  static Future<Map<String, dynamic>> saveEntry(
    int malId, {
    required String status,
    required int progress,
  }) async {
    final saved = await _call(
      'PATCH',
      'anime/$malId/my_list_status',
      body: {
        'status': malStatus(status),
        'num_watched_episodes': '$progress',
        if (status == 'REPEATING') 'is_rewatching': 'true',
      },
    );
    return {
      'progress': saved['num_episodes_watched'] ?? progress,
      'status': status,
    };
  }

  static Future<void> removeFromList(int malId) async {
    try {
      await _call('DELETE', 'anime/$malId/my_list_status');
    } catch (_) {} // 404 when it was never on the list
  }
}

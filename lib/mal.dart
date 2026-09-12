import 'dart:convert';

import 'package:http/http.dart' as http;

import 'anilist.dart';

/// MyAnimeList's public API v2, a read-only stand-in for AniList's browse calls when AniList is down.
/// Answers with AniList-shaped media maps so the rest of the app can't tell them apart.
class MAL {
  static const clientId = String.fromEnvironment('MAL_CLIENT_ID');
  static const _fields =
      'id,title,alternative_titles,main_picture,synopsis,mean,genres,media_type,'
      'status,start_season,num_episodes';

  static bool get usable => clientId.isNotEmpty;

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

  static Future<List> search(String text) async =>
      _list(await _get('anime', {'q': text, 'limit': '40', 'fields': _fields}));

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

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

String titleOf(Map media) =>
    media['title']['userPreferred'] ??
    media['title']['romaji'] ??
    media['title']['english'] ??
    '';

/// Search filters as AniList enum values (season "FALL", format "TV", …); null means any.
class SearchFilters {
  const SearchFilters({
    this.sort,
    this.season,
    this.year,
    this.format,
    this.status,
    this.genres = const {},
  });

  final String? sort, season, format, status;
  final int? year;
  final Set<String> genres; // all of them, like AniList's genre_in

  /// How many filters narrow the results; sorting doesn't count.
  int get count =>
      [season, year, format, status].whereType<Object>().length + genres.length;

  /// For results that couldn't be filtered server-side (MyAnimeList).
  bool matches(Map media) =>
      (season == null || media['season'] == season) &&
      (year == null || media['seasonYear'] == year) &&
      (format == null || media['format'] == format) &&
      (status == null || media['status'] == status) &&
      genres.every((media['genres'] as List).contains);
}

/// AniList SSO (implicit grant) and the GraphQL calls the app needs.
class AniList {
  static const clientId = String.fromEnvironment('ANILIST_CLIENT_ID');
  static const _media =
      'id idMal title{userPreferred romaji english} coverImage{extraLarge color} bannerImage '
      'episodes description averageScore genres format status season seasonYear '
      'nextAiringEpisode{episode} mediaListEntry{progress status}';

  static String? token;
  static Map<String, dynamic>? _viewer;

  static bool get usable => clientId.isNotEmpty;

  static Future<void> load() async {
    token = (await SharedPreferences.getInstance()).getString('anilist_token');
  }

  /// Shows AniList's authorize page in-app and captures the token from the `aniview://auth#access_token=…` redirect.
  static Future<void> login(BuildContext context) async {
    final value = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const _LoginPage(),
      ),
    );
    if (value == null) return; // closed without authorizing
    token = value;
    await (await SharedPreferences.getInstance()).setString(
      'anilist_token',
      value,
    );
  }

  static Future<void> logout() async {
    token = null;
    _viewer = null;
    await (await SharedPreferences.getInstance()).remove('anilist_token');
  }

  static Future<Map<String, dynamic>> query(
    String query, [
    Map<String, dynamic> variables = const {},
  ]) async {
    final res = await http.post(
      Uri.parse('https://graphql.anilist.co'),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'query': query, 'variables': variables}),
    );
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final errors = body['errors'] as List?;
    if (errors != null && errors.isNotEmpty) {
      final message = errors.first['message'] as String;
      if (res.statusCode == 401 || message.contains('Invalid token')) {
        await logout();
      }
      throw Exception(message);
    }
    return body['data'] as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>?> viewer() async {
    if (token == null) return null;
    return _viewer ??= (await query(
      'query{Viewer{id name avatar{large}}}',
    ))['Viewer'];
  }

  static Future<List> trending() async => (await query(
    'query{Page(perPage:20){media(type:ANIME,sort:TRENDING_DESC,isAdult:false){$_media}}}',
  ))['Page']['media'];

  /// AniList season name and year for today (WINTER = Jan–Mar, SPRING, SUMMER, FALL).
  static (String, int) get currentSeason {
    final now = DateTime.now();
    return (
      const ['WINTER', 'SPRING', 'SUMMER', 'FALL'][(now.month - 1) ~/ 3],
      now.year,
    );
  }

  /// Most popular shows of the current season.
  static Future<List> season() async {
    final (season, year) = currentSeason;
    return (await query(
      r'query($s:MediaSeason,$y:Int){Page(perPage:20){media(type:ANIME,season:$s,seasonYear:$y,'
      r'sort:POPULARITY_DESC,isAdult:false){'
      '$_media}}}',
      {'s': season, 'y': year},
    ))['Page']['media'];
  }

  /// One [page] of results and whether there's another. [text] may be empty to browse by [filters] alone.
  static Future<(List, bool)> search(
    String text, [
    SearchFilters filters = const SearchFilters(),
    int page = 1,
  ]) async {
    final data = (await query(
      r'query($page:Int,$s:String,$sort:[MediaSort],$season:MediaSeason,$year:Int,$format:MediaFormat,$status:MediaStatus,$genres:[String]){'
      r'Page(page:$page,perPage:40){pageInfo{hasNextPage} media(search:$s,type:ANIME,isAdult:false,sort:$sort,season:$season,'
      r'seasonYear:$year,format:$format,status:$status,genre_in:$genres){'
      '$_media}}}',
      // AniList reads an explicit null as "must be null", so unset filters are left out.
      {
        'page': page,
        's': text.isEmpty ? null : text,
        'sort':
            filters.sort ?? (text.isEmpty ? 'POPULARITY_DESC' : 'SEARCH_MATCH'),
        'season': filters.season,
        'year': filters.year,
        'format': filters.format,
        'status': filters.status,
        'genres': filters.genres.isEmpty ? null : filters.genres.toList(),
      }..removeWhere((_, v) => v == null),
    ))['Page'];
    return (data['media'] as List, data['pageInfo']['hasNextPage'] == true);
  }

  /// Anime prequels and sequels of a show as (PREQUEL|SEQUEL, media), prequels first.
  static Future<List<(String, Map)>> relations(int id) async {
    final data = await query(
      r'query($id:Int){Media(id:$id){relations{edges{relationType(version:2) node{type '
      '$_media}}}}}',
      {'id': id},
    );
    return [
      for (final e in data['Media']['relations']['edges'])
        if (e['node']['type'] == 'ANIME' &&
            (e['relationType'] == 'PREQUEL' || e['relationType'] == 'SEQUEL'))
          (e['relationType'] as String, e['node'] as Map),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
  }

  /// Watching (incl. rewatching) and planning entries, most recently updated first.
  static Future<Map<String, List>> lists() async {
    final me = await viewer();
    if (me == null) return {};
    final data = await query(
      r'query($u:Int){MediaListCollection(userId:$u,type:ANIME,status_in:[CURRENT,REPEATING,PLANNING],'
      r'sort:UPDATED_TIME_DESC){lists{status entries{media{'
      '$_media}}}}}',
      {'u': me['id']},
    );
    final out = <String, List>{'CURRENT': [], 'PLANNING': []};
    for (final list in data['MediaListCollection']['lists']) {
      out[list['status'] == 'PLANNING' ? 'PLANNING' : 'CURRENT']!.addAll([
        for (final entry in list['entries']) entry['media'],
      ]);
    }
    return out;
  }

  static Future<int> progressOf(int mediaId) async =>
      (await query(r'query($id:Int){Media(id:$id){mediaListEntry{progress}}}', {
        'id': mediaId,
      }))['Media']['mediaListEntry']?['progress'] ??
      0;

  /// Sets a show's list status and progress (adds it to the list if needed); returns the saved entry.
  static Future<Map<String, dynamic>> saveEntry(
    int mediaId, {
    required String status,
    required int progress,
  }) async => (await query(
    r'mutation($m:Int,$s:MediaListStatus,$p:Int){SaveMediaListEntry(mediaId:$m,status:$s,progress:$p){id status progress}}',
    {'m': mediaId, 's': status, 'p': progress},
  ))['SaveMediaListEntry'];

  static Future<void> removeFromList(int mediaId) async {
    final entry = (await query(
      r'query($m:Int){Media(id:$m){mediaListEntry{id}}}',
      {'m': mediaId},
    ))['Media']['mediaListEntry'];
    if (entry == null) return;
    await query(r'mutation($id:Int){DeleteMediaListEntry(id:$id){deleted}}', {
      'id': entry['id'],
    });
  }
}

class _LoginPage extends StatefulWidget {
  const _LoginPage();

  @override
  State<_LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<_LoginPage> {
  bool _done = false;

  NavigationActionPolicy _intercept(WebUri? url) {
    if (url == null || url.scheme != 'aniview') {
      return NavigationActionPolicy.ALLOW;
    }
    if (!_done) {
      _done = true;
      Navigator.pop(
        context,
        Uri.splitQueryString(url.fragment)['access_token'],
      );
    }
    return NavigationActionPolicy.CANCEL;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Sign in with AniList')),
    body: InAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri(
          'https://anilist.co/api/v2/oauth/authorize?client_id=${AniList.clientId}&response_type=token',
        ),
      ),
      initialSettings: InAppWebViewSettings(useShouldOverrideUrlLoading: true),
      shouldOverrideUrlLoading: (_, action) async =>
          _intercept(action.request.url),
    ),
  );
}

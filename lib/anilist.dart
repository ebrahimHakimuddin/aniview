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
    final redirect = await oauthRedirect(
      context,
      'Sign in with AniList',
      'https://anilist.co/api/v2/oauth/authorize?client_id=$clientId&response_type=token',
    );
    final value = redirect == null
        ? null
        : Uri.splitQueryString(redirect.fragment)['access_token'];
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

  static Future<List> search(String text) async => (await query(
    r'query($s:String){Page(perPage:40){media(search:$s,type:ANIME,isAdult:false,sort:SEARCH_MATCH){'
    '$_media}}}',
    {'s': text},
  ))['Page']['media'];

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

  static const _pendingKey = 'anilist_pending';
  static Future<int>? _syncing;

  static Map<String, dynamic> _pending(SharedPreferences prefs) =>
      jsonDecode(prefs.getString(_pendingKey) ?? '{}');

  /// Remembers progress made while AniList couldn't be reached so [syncPending] can push it later.
  static Future<void> queueProgress(Map media, int progress) async {
    final prefs = await SharedPreferences.getInstance();
    final pending = _pending(prefs);
    final existing = pending['${media['id']}']?['progress'] as int? ?? 0;
    if (progress <= existing) return;
    pending['${media['id']}'] = {'media': media, 'progress': progress};
    await prefs.setString(_pendingKey, jsonEncode(pending));
  }

  /// Pushes queued offline progress and returns how many shows were updated. Never rolls AniList back.
  static Future<int> syncPending() =>
      _syncing ??= _syncPending().whenComplete(() => _syncing = null);

  static Future<int> _syncPending() async {
    if (token == null) return 0;
    final prefs = await SharedPreferences.getInstance();
    final pending = _pending(prefs);
    if (pending.isEmpty) return 0;
    var synced = 0;
    for (final MapEntry(:key, :value) in pending.entries.toList()) {
      try {
        final media = value['media'] as Map;
        final progress = value['progress'] as int;
        if (progress > await progressOf(media['id'])) {
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

  static Future<void> saveProgress(Map media, int progress) => query(
    r'mutation($id:Int,$p:Int,$s:MediaListStatus){SaveMediaListEntry(mediaId:$id,progress:$p,status:$s){id}}',
    {
      'id': media['id'],
      'p': progress,
      's': progress == media['episodes'] ? 'COMPLETED' : 'CURRENT',
    },
  );
}

/// Shows [url] in an in-app browser and returns the `aniview://…` redirect it ends on, or null if closed.
Future<Uri?> oauthRedirect(BuildContext context, String title, String url) =>
    Navigator.of(context).push<Uri>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _LoginPage(title: title, url: url),
      ),
    );

class _LoginPage extends StatefulWidget {
  const _LoginPage({required this.title, required this.url});

  final String title, url;

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
      Navigator.pop(context, Uri.parse(url.toString()));
    }
    return NavigationActionPolicy.CANCEL;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(widget.url)),
      initialSettings: InAppWebViewSettings(useShouldOverrideUrlLoading: true),
      shouldOverrideUrlLoading: (_, action) async =>
          _intercept(action.request.url),
    ),
  );
}

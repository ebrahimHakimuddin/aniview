import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

String titleOf(Map media) =>
    media['title']['userPreferred'] ?? media['title']['romaji'] ?? media['title']['english'] ?? '';

/// AniList SSO (implicit grant) and the GraphQL calls the app needs.
class AniList {
  static const clientId = String.fromEnvironment('ANILIST_CLIENT_ID');
  static const _media =
      'id idMal title{userPreferred romaji english} coverImage{extraLarge color} bannerImage '
      'episodes description averageScore genres format status seasonYear '
      'nextAiringEpisode{episode} mediaListEntry{progress status}';

  static String? token;
  static Map<String, dynamic>? _viewer;

  static Future<void> load() async {
    token = (await SharedPreferences.getInstance()).getString('anilist_token');
  }

  /// Shows AniList's authorize page in-app and captures the token from the `aniview://auth#access_token=…` redirect.
  static Future<void> login(BuildContext context) async {
    final value = await Navigator.of(context).push<String>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => const _LoginPage()),
    );
    if (value == null) return; // closed without authorizing
    token = value;
    await (await SharedPreferences.getInstance()).setString('anilist_token', value);
  }

  static Future<void> logout() async {
    token = null;
    _viewer = null;
    await (await SharedPreferences.getInstance()).remove('anilist_token');
  }

  static Future<Map<String, dynamic>> query(String query, [Map<String, dynamic> variables = const {}]) async {
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
      if (res.statusCode == 401 || message.contains('Invalid token')) await logout();
      throw Exception(message);
    }
    return body['data'] as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>?> viewer() async {
    if (token == null) return null;
    return _viewer ??= (await query('query{Viewer{id name avatar{large}}}'))['Viewer'];
  }

  static Future<List> trending() async =>
      (await query('query{Page(perPage:20){media(type:ANIME,sort:TRENDING_DESC,isAdult:false){$_media}}}'))['Page']
          ['media'];

  static Future<List> search(String text) async => (await query(
        r'query($s:String){Page(perPage:40){media(search:$s,type:ANIME,isAdult:false,sort:SEARCH_MATCH){'
        '$_media}}}',
        {'s': text},
      ))['Page']['media'];

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
      out[list['status'] == 'PLANNING' ? 'PLANNING' : 'CURRENT']!
          .addAll([for (final entry in list['entries']) entry['media']]);
    }
    return out;
  }

  static Future<int> progressOf(int mediaId) async =>
      (await query(r'query($id:Int){Media(id:$id){mediaListEntry{progress}}}', {'id': mediaId}))['Media']
          ['mediaListEntry']?['progress'] ??
      0;

  static Future<void> saveProgress(Map media, int progress) => query(
        r'mutation($id:Int,$p:Int,$s:MediaListStatus){SaveMediaListEntry(mediaId:$id,progress:$p,status:$s){id}}',
        {'id': media['id'], 'p': progress, 's': progress == media['episodes'] ? 'COMPLETED' : 'CURRENT'},
      );
}

class _LoginPage extends StatefulWidget {
  const _LoginPage();

  @override
  State<_LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<_LoginPage> {
  bool _done = false;

  NavigationActionPolicy _intercept(WebUri? url) {
    if (url == null || url.scheme != 'aniview') return NavigationActionPolicy.ALLOW;
    if (!_done) {
      _done = true;
      Navigator.pop(context, Uri.splitQueryString(url.fragment)['access_token']);
    }
    return NavigationActionPolicy.CANCEL;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Sign in with AniList')),
        body: InAppWebView(
          initialUrlRequest: URLRequest(
            url: WebUri('https://anilist.co/api/v2/oauth/authorize?client_id=${AniList.clientId}&response_type=token'),
          ),
          initialSettings: InAppWebViewSettings(useShouldOverrideUrlLoading: true),
          shouldOverrideUrlLoading: (_, action) async => _intercept(action.request.url),
        ),
      );
}

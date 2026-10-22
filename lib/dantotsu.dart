import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'anilist.dart';
import 'settings.dart';

/// Dantotsu's shared comments (api.dantotsu.app): comments on AniList shows, tagged with their episode, shared by
/// every app that uses it. Reading needs a session too, made from an AniList sign-in and kept for its ~6 days: the
/// tracker's when it's AniList, else one signed in for comments alone ([signIn]), which leaves the tracker as it is.
class Dantotsu {
  static const _base = 'https://api.dantotsu.app';

  /// The client key its docs publish for every app (https://dantotsu-comment-db.vercel.app/docs.html).
  static const _appAuth = '6*45Qp%W2RS@t38jkXoSKY588Ynj%n';

  /// The 10 rules its docs require an app to show before anyone posts.
  static const rules = [
    'No racism, discrimination, or hate speech.',
    'No spamming or self-promotion.',
    'Absolutely no NSFW content.',
    'English only, no exceptions.',
    'No impersonation, harassment, or abuse.',
    'No illegal content or extreme disrespect towards any fandom.',
    'Do not request or share repositories or extensions.',
    'Spoilers only inside spoiler tags (||like this|| or ~!like this!~), with a warning.',
    'No sexualizing or inappropriate comments about minor characters.',
    "If it's wrong, don't post it!",
  ];

  static const _session = Duration(days: 5); // issued for about 6

  /// The AniList sign-in comments go by: the tracker's, else the one for comments alone.
  static String? get _anilist =>
      AniList.token ??
      (Settings.dantotsuAniList.isEmpty ? null : Settings.dantotsuAniList);

  static bool get signedIn => _anilist != null;

  /// Enough of an AniList token (the end of its signature) to tell it from another, without keeping it twice.
  static String _tail(String token) =>
      token.substring(token.length > 16 ? token.length - 16 : 0);

  /// Whether comments have an AniList sign-in of their own (not the tracker's), which [signOut] removes.
  static bool get ownSignIn =>
      AniList.token == null && Settings.dantotsuAniList.isNotEmpty;

  /// Signs in to AniList for comments alone; false when the page was closed.
  static Future<bool> signIn(BuildContext context) async {
    final token = await AniList.authorize(context);
    if (token == null) return false;
    Settings.dantotsuAniList = token;
    await _token();
    return true;
  }

  static void signOut() {
    Settings.dantotsuAniList = '';
    Settings.dantotsuToken = '';
    Settings.dantotsuUser = '';
    Settings.dantotsuUserName = '';
  }

  /// The Dantotsu session: made again when there's none, it's run out, or another AniList account is signed in.
  static Future<String> _token() async {
    final anilist =
        _anilist ?? (throw Exception('Sign in with AniList to see comments'));
    final at = DateTime.fromMillisecondsSinceEpoch(Settings.dantotsuTokenAt);
    if (Settings.dantotsuToken.isNotEmpty &&
        Settings.dantotsuSource == _tail(anilist) &&
        DateTime.now().difference(at) < _session) {
      return Settings.dantotsuToken;
    }
    final res = await http.post(
      Uri.parse('$_base/authenticate'),
      headers: {'appauth': _appAuth},
      body: {'token': anilist},
    );
    _check(res);
    final json = jsonDecode(res.body);
    Settings.dantotsuToken = json['authToken'];
    Settings.dantotsuTokenAt = DateTime.now().millisecondsSinceEpoch;
    Settings.dantotsuSource = _tail(anilist);
    Settings.dantotsuUser = '${json['user']['user_id']}';
    Settings.dantotsuUserName = '${json['user']['username'] ?? ''}';
    return Settings.dantotsuToken;
  }

  /// The AniList user id comments are posted as (see [isMine]).
  static String get userId => Settings.dantotsuUser;

  static void _check(http.Response res) {
    if (res.statusCode == 429) {
      throw Exception('Too many requests to Dantotsu. Try again in 30 seconds');
    }
    if (res.statusCode >= 300) {
      throw HttpException(
        res.body.length < 200 && res.body.isNotEmpty
            ? res.body
            : 'HTTP ${res.statusCode}',
        uri: res.request?.url,
      );
    }
  }

  /// A request with the session; one that's been turned away gets a new session and goes once more.
  static Future<dynamic> _call(
    String method,
    String path, {
    Map<String, String>? body,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final uri = Uri.parse('$_base/$path');
      final headers = {'appauth': _appAuth, 'Authorization': await _token()};
      final res = await switch (method) {
        'POST' => http.post(uri, headers: headers, body: body),
        'DELETE' => http.delete(uri, headers: headers),
        _ => http.get(uri, headers: headers),
      };
      if (res.statusCode == 401 && attempt == 0) {
        Settings.dantotsuToken = '';
        continue;
      }
      _check(res);
      return res.body.isEmpty ? null : jsonDecode(res.body);
    }
  }

  /// A page of [mediaId]'s comments (on [episode] alone when given), and how many pages there are.
  static Future<(List<Map>, int)> comments(
    int mediaId,
    int page, {
    num? episode,
    bool newest = false,
  }) async {
    final tag = episode != null && episode % 1 == 0 ? episode.toInt() : null;
    final json = await _call(
      'GET',
      'comments/$mediaId/$page?sort=${newest ? 'newest' : 'highest_rated'}'
          '${tag == null ? '' : '&tag=$tag'}',
    );
    return _page(json);
  }

  /// A page of the replies under comment [parent].
  static Future<(List<Map>, int)> replies(int parent, int page) async =>
      _page(await _call('GET', 'comments/parent/$parent/$page'));

  static (List<Map>, int) _page(dynamic json) => (
    (json['comments'] as List? ?? const []).cast<Map>(),
    json['totalPages'] as int? ?? 1,
  );

  /// Posts [content] on [mediaId] (tagged with [episode]), or as a reply to [parent].
  static Future<void> post(
    int mediaId,
    String content, {
    num? episode,
    int? parent,
  }) async {
    await _token(); // for the user id
    await _call(
      'POST',
      'comments',
      body: {
        'user_id': userId,
        'media_id': '$mediaId',
        'content': content,
        if (episode != null && episode % 1 == 0) 'tag': '${episode.toInt()}',
        if (parent != null) 'parent_comment_id': '$parent',
      },
    );
  }

  /// Votes on comment [id]: 1 up, -1 down, 0 takes the vote back.
  static Future<void> vote(int id, int type) =>
      _call('POST', 'comments/vote/$id/$type');

  static Future<void> delete(int id) => _call('DELETE', 'comments/$id');

  /// Reports [comment] on [mediaName] to Dantotsu's moderators.
  static Future<void> report(Map comment, String mediaName) => _call(
    'POST',
    'report/${comment['comment_id']}',
    body: {
      'username': '${comment['username'] ?? ''}',
      'mediaName': mediaName,
      'reporter': Settings.dantotsuUserName,
      'reportedId': '${comment['user_id']}',
    },
  );

  static bool isMine(Map comment) =>
      userId.isNotEmpty && '${comment['user_id']}' == userId;
}

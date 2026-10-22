import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'anilist.dart';
import 'metadata.dart';
import 'settings.dart';
import 'states.dart';
import 'ui.dart';

/// A season of a series as Jellyseerr knows it (TMDB's numbering), and where it stands there.
typedef SeerrSeason = ({int number, int episodes, String? state});

/// A show on Jellyseerr: its TMDB id, where it stands (null when nobody has asked for it), and for a series its
/// seasons with the one the AniList entry most likely is ([suggested]).
typedef SeerrTitle = ({
  int id,
  bool movie,
  String name,
  String? state,
  List<SeerrSeason> seasons,
  int? suggested,
});

/// Requests on the user's Jellyseerr (or Seerr, its successor; same API), signed in with their Jellyfin account so
/// a request is theirs, with their permissions and quotas. The session is Jellyseerr's cookie; no password is kept.
class Jellyseerr {
  Jellyseerr(this.server, this.cookie);

  /// The signed-in Jellyseerr from Settings, or null.
  static Jellyseerr? saved() => Settings.jellyseerrCookie.isEmpty
      ? null
      : Jellyseerr(Settings.jellyseerrServer, Settings.jellyseerrCookie);

  final String server, cookie;

  static Future<void> signIn(
    String address,
    String name,
    String password,
  ) async {
    var server = address.trim().replaceFirst(RegExp(r'/+$'), '');
    if (!server.startsWith('http')) server = 'http://$server';
    final res = await http.post(
      Uri.parse('$server/api/v1/auth/jellyfin'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': name, 'password': password}),
    );
    if (res.statusCode != 200) throw Exception(_message(res));
    final cookie = RegExp(r'connect\.sid=[^;]+')
        .firstMatch(res.headers['set-cookie'] ?? '')?[0];
    if (cookie == null) throw Exception('Jellyseerr sent no session');
    Settings.jellyseerrServer = server;
    Settings.jellyseerrCookie = cookie;
  }

  static void signOut() => Settings.jellyseerrCookie = '';

  static String _message(http.Response res) {
    try {
      if (jsonDecode(res.body)['message'] case final String message) {
        return message;
      }
    } catch (_) {}
    return 'Jellyseerr answered HTTP ${res.statusCode}';
  }

  Future<dynamic> _call(String path, [Object? body]) async {
    final uri = Uri.parse('$server/api/v1/$path');
    final headers = {'Cookie': cookie, 'Content-Type': 'application/json'};
    final res = body == null
        ? await http.get(uri, headers: headers)
        : await http.post(uri, headers: headers, body: jsonEncode(body));
    if (res.statusCode == 401 || (res.statusCode == 403 && body == null)) {
      // An expired session reads as forbidden; a refused request (no permission, over quota) says why instead.
      signOut();
      throw Exception('Sign in to Jellyseerr again in Settings');
    }
    if (res.statusCode >= 300) throw Exception(_message(res));
    return jsonDecode(res.body);
  }

  static String? _state(Object? status) => switch (status) {
    5 => 'Available',
    4 => 'Partly available',
    2 || 3 => 'Requested',
    _ => null,
  };

  /// [media] on Jellyseerr: by ani.zip's TMDB id, else the first search result of its kind. Null when not found.
  Future<SeerrTitle?> find(Map media) async {
    final movie = media['format'] == 'MOVIE';
    Map zip;
    try {
      zip = await mappingsOf(media);
    } catch (_) {
      zip = const {};
    }
    var id = int.tryParse('${zip['mappings']?['themoviedb_id']}');
    if (id == null) {
      final results =
          (await _call(
                'search?query=${Uri.encodeQueryComponent(titleOf(media))}',
              ))['results']
              as List;
      id =
          results
                  .where((r) => r['mediaType'] == (movie ? 'movie' : 'tv'))
                  .firstOrNull?['id']
              as int?;
      if (id == null) return null;
    }
    final json = await _call('${movie ? 'movie' : 'tv'}/$id');
    final info = json['mediaInfo'] as Map? ?? const {};
    final requested = {
      for (final r in info['requests'] as List? ?? const [])
        if (r['status'] != 3) // declined
          for (final s in r['seasons'] as List? ?? const []) s['seasonNumber'],
    };
    final states = {
      for (final s in info['seasons'] as List? ?? const [])
        s['seasonNumber']: _state(s['status']),
    };
    final seasons = <SeerrSeason>[
      for (final s in json['seasons'] as List? ?? const [])
        (
          number: s['seasonNumber'] as int,
          episodes: s['episodeCount'] as int? ?? 0,
          state:
              states[s['seasonNumber']] ??
              (requested.contains(s['seasonNumber']) ? 'Requested' : null),
        ),
    ];
    return (
      id: id,
      movie: movie,
      name: '${json['title'] ?? json['name'] ?? titleOf(media)}',
      state: _state(info['status']),
      seasons: seasons,
      suggested: suggestedSeason(
        seasons,
        (zip['episodes'] as Map?)?['1']?['seasonNumber'] as int?,
      ),
    );
  }

  /// ani.zip's season is TVDB's, which TMDB often splits differently (Jujutsu Kaisen is one season of 59 there):
  /// it's used when Jellyseerr has that season, else the latest.
  static int? suggestedSeason(List<SeerrSeason> seasons, int? tvdb) {
    final regular = [
      for (final s in seasons)
        if (s.number > 0) s.number,
    ];
    if (regular.contains(tvdb)) return tvdb;
    return regular.isEmpty ? null : regular.last;
  }

  Future<void> request(SeerrTitle title, {int? season}) => _call('request', {
    'mediaType': title.movie ? 'movie' : 'tv',
    'mediaId': title.id,
    'seasons': ?(season == null ? null : [season]),
  });
}

/// Asks Jellyseerr for [media]: the movie, or the season picked (the likeliest one first).
Future<void> requestOnJellyseerr(BuildContext context, Map media) async {
  final seerr = Jellyseerr.saved();
  if (seerr == null) return;
  try {
    final title =
        await seerr.find(media) ??
        (throw Exception('Jellyseerr can\'t find ${titleOf(media)}'));
    if (!context.mounted) return;
    int? season;
    if (title.movie) {
      if (title.state != null) {
        return showSuccess(context, '${title.name} · ${title.state}');
      }
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => PanelDialog(
          title: Text('Request ${title.name}?'),
          content: const Text('Jellyseerr adds it to your Jellyfin server'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Request'),
            ),
          ],
        ),
      );
      if (go != true) return;
    } else {
      String label(SeerrSeason s) => [
        s.number == 0 ? 'Specials' : 'Season ${s.number}',
        '${s.episodes} episodes',
        ?s.state,
      ].join(' · ');
      if (title.seasons.isEmpty) {
        throw Exception('Jellyseerr lists no seasons of ${title.name} yet');
      }
      season = await pickOne(
        context,
        'Request which season of ${title.name}?',
        {
          for (final s in title.seasons.where((s) => s.number > 0))
            s.number: label(s),
          for (final s in title.seasons.where((s) => s.number == 0))
            s.number: label(s),
        },
        title.suggested ?? title.seasons.first.number,
      );
      if (season == null || !context.mounted) return;
      final picked = title.seasons.firstWhere((s) => s.number == season);
      if (picked.state != null) {
        return showSuccess(context, label(picked));
      }
    }
    await seerr.request(title, season: season);
    if (context.mounted) {
      showSuccess(
        context,
        'Requested ${title.name}${season == null ? '' : ' · Season $season'}',
      );
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'anilist.dart';
import 'history.dart';
import 'metadata.dart';
import 'settings.dart';
import 'sources.dart';

/// The user's own Jellyfin server, as a site. A show is matched by the ids its library items carry (AniList,
/// AniDB, then TVDB/TMDB/IMDb from ani.zip), else by title. A series holds every season, so a match also names
/// where the AniList entry starts in it (ani.zip's TVDB season and episode; empty for an anime-ordered series) and
/// how many episodes it has: `<series>/<season>/<episode>/<count>`. A movie is `movie/<item>`.
class Jellyfin extends Source {
  Jellyfin({
    required String server,
    required this.token,
    required this.user,
    this.net = const HttpNet(),
  }) : super('Jellyfin', server.replaceFirst(RegExp(r'/+$'), ''));

  /// The signed-in server from Settings, or null.
  static Jellyfin? saved() => Settings.jellyfinToken.isEmpty
      ? null
      : Jellyfin(
          server: Settings.jellyfinServer,
          token: Settings.jellyfinToken,
          user: Settings.jellyfinUser,
        );

  final String token, user;
  final Net net;

  static String _authorization([String? token]) =>
      'MediaBrowser Client="AniView", Device="${Platform.operatingSystem}", '
      'DeviceId="${Settings.jellyfinDevice}", Version="1"${token == null ? '' : ', Token="$token"'}';

  static String _server(String address) {
    final server = address.trim().replaceFirst(RegExp(r'/+$'), '');
    return server.startsWith('http') ? server : 'http://$server';
  }

  static Future<dynamic> _post(String url, [Object? body]) async {
    final res = await http.post(
      Uri.parse(url),
      headers: {
        'Authorization': _authorization(),
        'Content-Type': 'application/json',
      },
      body: body == null ? null : jsonEncode(body),
    );
    if (res.statusCode == 401) throw Exception('Wrong username or password');
    if (res.statusCode != 200) {
      throw Exception('The server answered HTTP ${res.statusCode}');
    }
    return jsonDecode(res.body);
  }

  static void _save(String server, Map session) {
    Settings.jellyfinServer = server;
    Settings.jellyfinToken = session['AccessToken'];
    Settings.jellyfinUser = session['User']['Id'];
    Settings.jellyfinUserName = session['User']['Name'] ?? '';
  }

  /// Signs in and saves the session; throws with a message for the user when the server says no.
  static Future<void> signIn(
    String address,
    String name,
    String password,
  ) async {
    final server = _server(address);
    _save(
      server,
      await _post('$server/Users/AuthenticateByName', {
        'Username': name,
        'Pw': password,
      }),
    );
  }

  /// Quick Connect: [showCode] gets the code to enter in another signed-in Jellyfin app, then this waits until it's
  /// approved there and saves the session. Stops waiting, unsaved, once [cancelled] says so.
  static Future<bool> quickConnect(
    String address, {
    required void Function(String code) showCode,
    required bool Function() cancelled,
  }) async {
    final server = _server(address);
    final enabled = await http.get(Uri.parse('$server/QuickConnect/Enabled'));
    if (enabled.body != 'true') {
      throw Exception('Quick Connect is turned off on this server');
    }
    final start = await _post('$server/QuickConnect/Initiate');
    showCode('${start['Code']}');
    final secret = start['Secret'];
    while (!cancelled()) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final state = jsonDecode(
        (await http.get(
          Uri.parse('$server/QuickConnect/Connect?secret=$secret'),
          headers: {'Authorization': _authorization()},
        )).body,
      );
      if (state['Authenticated'] == true && !cancelled()) {
        _save(
          server,
          await _post('$server/Users/AuthenticateWithQuickConnect', {
            'Secret': secret,
          }),
        );
        return true;
      }
    }
    return false;
  }

  static void signOut() {
    Settings.jellyfinToken = '';
    Settings.jellyfinUser = '';
  }

  Map<String, String> get _headers => {'Authorization': _authorization(token)};

  Future<dynamic> _api(String path) async =>
      jsonDecode(await net.text('$base$path', headers: _headers));

  Future<List> _items(String query) async =>
      (await _api(
            '/Items?userId=$user&Recursive=true&IncludeItemTypes=Series,Movie&$query',
          ))['Items']
          as List;

  /// The whole library, read only when a show isn't found by searching its titles (the server can't look items up
  /// by provider id: `AnyProviderIdEquals` is ignored).
  late final Future<List> _library = _items(
    'Fields=ProviderIds&EnableImages=false',
  );

  @override
  Future<List<SearchResult>> search(String query) async => [
    for (final i in await _items(
      'searchTerm=${Uri.encodeQueryComponent(query)}&Limit=20&Fields=ProductionYear',
    ))
      SearchResult(
        i['Type'] == 'Movie' ? 'movie/${i['Id']}' : '${i['Id']}',
        '${i['Name']}',
        image: '$base/Items/${i['Id']}/Images/Primary?maxHeight=300',
        info: [i['Type'], i['ProductionYear']].whereType<Object>().join(' · '),
      ),
  ];

  @override
  Future<String?> match(Map media) async {
    final movie = media['format'] == 'MOVIE';
    Map zip;
    try {
      zip = await mappingsOf(media);
    } catch (_) {
      zip = const {}; // ani.zip down or unaware of the show: AniList id and titles still match
    }
    final ids = zip['mappings'] as Map? ?? const {};
    // A library names a show by its first season ("Jujutsu Kaisen" for "... 2nd Season"), in any language.
    final suffix = RegExp(
      r'[\s:]*(\(\d{4}\)|\d+(st|nd|rd|th) Season|Season \d+|Part \d+|Cour \d+)$',
      caseSensitive: false,
    );
    final titles = {
      for (final t in [
        media['title']['romaji'],
        media['title']['english'],
        ...?(zip['titles'] as Map?)?.values,
      ])
        if (t is String && t.isNotEmpty) ...[
          t.toLowerCase(),
          t.replaceFirst(suffix, '').toLowerCase(),
        ],
    };
    Map? find(List items) {
      final kind = [
        for (final i in items)
          if ((i['Type'] == 'Movie') == movie) i,
      ];
      Map? by(String provider, Object? id) => id == null
          ? null
          : kind
                .where((i) => '${i['ProviderIds']?[provider]}' == '$id')
                .firstOrNull;
      return by('AniList', media['id']) ??
          by('AniDB', ids['anidb_id']) ??
          by('Tvdb', ids['thetvdb_id']) ??
          by('Tmdb', ids['themoviedb_id']) ??
          by('Imdb', ids['imdb_id']) ??
          kind
              .where((i) => titles.contains('${i['Name']}'.toLowerCase()))
              .firstOrNull;
    }

    final found = await Future.wait([
      for (final t in titles.take(8))
        _items(
          'searchTerm=${Uri.encodeQueryComponent(t)}&Limit=10&Fields=ProviderIds&EnableImages=false',
        ),
    ]);
    final item = find([for (final f in found) ...f]) ?? find(await _library);
    if (item == null) return null;
    if (movie) return 'movie/${item['Id']}';
    // Found by the entry's own AniList or AniDB id, the series is that entry alone (anime-ordered): it starts at its
    // beginning. Otherwise it's TVDB-ordered, and the entry is where ani.zip's TVDB season starts.
    final own = item['ProviderIds'] as Map? ?? const {};
    final anime =
        '${own['AniList']}' == '${media['id']}' ||
        (ids['anidb_id'] != null && '${own['AniDB']}' == '${ids['anidb_id']}');
    final first = anime ? null : (zip['episodes'] as Map?)?['1'] as Map?;
    return '${item['Id']}/${first?['seasonNumber'] ?? ''}/'
        '${first?['episodeNumber'] ?? ''}/${media['episodes'] ?? ''}';
  }

  @override
  Future<List<Episode>> episodesOf(String id) async {
    final [item, ...rest] = id.split('/');
    if (item == 'movie') return [Episode(1, ref: rest.single)];
    final [season, episode, count] = [
      for (final p in [...rest, '', '', ''].take(3)) int.tryParse(p),
    ];
    final all =
        (await _api(
              '/Shows/$item/Episodes?userId=$user&Fields=Overview',
            ))['Items']
            as List;
    // Specials only when the entry is one (an OVA TVDB files under season 0).
    final list = [
      for (final e in all)
        if ((e['ParentIndexNumber'] == 0) == (season == 0)) e,
    ];
    // No season to find (anime-ordered, or ani.zip doesn't know): from the beginning. A season the library lacks
    // is no episodes, not another season's, so the show reads as not on the server (and can be requested).
    final start = season == null
        ? 0
        : list.indexWhere(
            (e) =>
                e['ParentIndexNumber'] == season && e['IndexNumber'] == episode,
          );
    if (start < 0) return [];
    final picked = list.skip(start).take(count ?? list.length).toList();
    return [
      for (final (n, e) in picked.indexed)
        Episode(
          n + 1,
          title: e['Name'],
          overview: e['Overview'],
          thumbnail: '$base/Items/${e['Id']}/Images/Primary?maxHeight=300',
          ref: e['Id'],
        ),
    ];
  }

  @override
  Future<List<VideoStream>> streams(
    Map media,
    Episode episode, {
    required bool dub,
  }) async {
    final item =
        ((await _api(
                  '/Items?userId=$user&ids=${episode.ref}&Fields=MediaSources',
                ))['Items']
                as List)
            .single;
    final source = (item['MediaSources'] as List).first;
    final tracks = source['MediaStreams'] as List? ?? const [];
    // Sub and dub don't apply: the file carries every audio track, picked in the player. [dub] only puts that track's
    // transcode first among the fallbacks.
    final audio = [
      for (final t in tracks)
        if (t['Type'] == 'Audio') t,
    ];
    bool isDefault(Map t) => t['Index'] == source['DefaultAudioStreamIndex'];
    bool isEnglish(Map t) => t['Language'] == 'eng';
    final fallbacks = [...audio]
      ..sort(
        (a, b) => switch ((
          dub ? isEnglish(a) : isDefault(a),
          dub ? isEnglish(b) : isDefault(b),
        )) {
          (true, false) => -1,
          (false, true) => 1,
          _ => 0,
        },
      );
    final id = item['Id'], sourceId = source['Id'];
    List<Subtitle> subtitles({required bool embedded}) => [
      for (final t in tracks)
        if (t['Type'] == 'Subtitle' &&
            t['IsTextSubtitleStream'] == true &&
            (embedded || t['IsExternal'] == true))
          Subtitle(
            '${t['DisplayTitle'] ?? t['Language'] ?? 'Subtitles'}',
            '$base/Videos/$id/$sourceId/Subtitles/${t['Index']}/0/Stream.vtt?ApiKey=$token',
          ),
    ];
    // The server's HLS plays where the file's codecs don't, but with one audio track: one per track, so switching the
    // server switches the language (keeping the spot).
    VideoStream transcoded(Map? track) => VideoStream(
      track == null || audio.length < 2
          ? 'Jellyfin (transcoded)'
          : 'Jellyfin (transcoded · ${track['DisplayTitle'] ?? track['Language'] ?? 'Audio ${track['Index']}'})',
      '$base/Videos/$id/master.m3u8?MediaSourceId=$sourceId'
      '&DeviceId=${Settings.jellyfinDevice}&PlaySessionId=${Random().nextInt(1 << 32)}'
      '${track == null ? '' : '&AudioStreamIndex=${track['Index']}'}'
      '&VideoCodec=h264,hevc&AudioCodec=aac&TranscodingMaxAudioChannels=2'
      '&SegmentContainer=ts&ApiKey=$token',
      _headers,
      subtitles: subtitles(embedded: true),
    );
    final container = '${source['Container'] ?? 'mkv'}'.split(',').first;
    return [
      VideoStream(
        'Jellyfin',
        '$base/Videos/$id/stream.$container?static=true&MediaSourceId=$sourceId&ApiKey=$token',
        _headers,
        subtitles: subtitles(embedded: false),
      ),
      if (fallbacks.isEmpty) transcoded(null),
      for (final track in fallbacks) transcoded(track),
    ];
  }

  /// Tells the server how far episode [item] has been watched, so its own apps resume there and mark it played.
  Future<void> report(String item, Duration position, Duration duration) async {
    final played = WatchHistory.finished(position, duration);
    final res = await http.post(
      Uri.parse('$base/UserItems/$item/UserData?userId=$user'),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'Played': played,
        // Ticks are 100 ns.
        'PlaybackPositionTicks': played ? 0 : position.inMicroseconds * 10,
      }),
    );
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode}', uri: res.request?.url);
    }
  }

  /// The shows added to the server most recently, as AniList shows: by the AniList id an item carries, else
  /// ani.zip's answer for its other ids. Items neither knows are left out.
  Future<List> shows() async {
    final items = await _items(
      'SortBy=DateLastContentAdded,DateCreated&SortOrder=Descending&Limit=30'
      '&Fields=ProviderIds&EnableImages=false',
    );
    final ids = await Future.wait([
      for (final i in items) _aniListId(i['ProviderIds'] as Map? ?? const {}),
    ]);
    return AniList.byIds([...ids.whereType<int>().toSet()]);
  }

  static Future<int?> _aniListId(Map providers) async {
    if (int.tryParse('${providers['AniList']}') case final id?) return id;
    // A TMDB id names a movie or a series, so it's asked last.
    for (final (provider, param) in const [
      ('AniDB', 'anidb_id'),
      ('Tvdb', 'thetvdb_id'),
      ('Imdb', 'imdb_id'),
      ('Tmdb', 'themoviedb_id'),
    ]) {
      if (providers[provider] case final String id) {
        try {
          return jsonDecode(
                await fetch('https://api.ani.zip/mappings?$param=$id'),
              )['mappings']?['anilist_id']
              as int?;
        } catch (_) {} // unknown to ani.zip under this id: try the next
      }
    }
    return null;
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'metadata.dart';
import 'settings.dart';
import 'sources.dart';

/// The user's own Jellyfin server, as a site. A show is matched by the ids its library items carry (AniList,
/// AniDB, then TVDB/TMDB/IMDb from ani.zip), else by title. A series holds every season, so a match also names
/// where the AniList entry starts in it (ani.zip's TVDB season and episode) and how many episodes it has:
/// `<series>/<season>/<episode>/<count>`. A movie is `movie/<item>`.
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

  /// Signs in and saves the session; throws with a message for the user when the server says no.
  static Future<void> signIn(
    String server,
    String name,
    String password,
  ) async {
    server = server.trim().replaceFirst(RegExp(r'/+$'), '');
    if (!server.startsWith('http')) server = 'http://$server';
    final res = await http.post(
      Uri.parse('$server/Users/AuthenticateByName'),
      headers: {
        'Authorization': _authorization(),
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'Username': name, 'Pw': password}),
    );
    if (res.statusCode == 401) throw Exception('Wrong username or password');
    if (res.statusCode != 200) {
      throw Exception('The server answered HTTP ${res.statusCode}');
    }
    final json = jsonDecode(res.body);
    Settings.jellyfinServer = server;
    Settings.jellyfinToken = json['AccessToken'];
    Settings.jellyfinUser = json['User']['Id'];
    Settings.jellyfinUserName = json['User']['Name'] ?? name;
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

  // ponytail: the whole library once per site list; a server with tens of thousands of shows wants a provider-id query
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
    final library = [
      for (final i in await _library)
        if ((i['Type'] == 'Movie') == movie) i,
    ];
    Map zip;
    try {
      zip = await mappingsOf(media);
    } catch (_) {
      zip = const {}; // ani.zip down or unaware of the show: AniList id and titles still match
    }
    final ids = zip['mappings'] as Map? ?? const {};
    Map? by(String provider, Object? id) => id == null
        ? null
        : library
              .where((i) => '${i['ProviderIds']?[provider]}' == '$id')
              .firstOrNull;
    final titles = {
      for (final t in [media['title']['romaji'], media['title']['english']])
        if (t is String) t.toLowerCase(),
    };
    final item =
        by('AniList', media['id']) ??
        by('AniDB', ids['anidb_id']) ??
        by('Tvdb', ids['thetvdb_id']) ??
        by('Tmdb', ids['themoviedb_id']) ??
        by('Imdb', ids['imdb_id']) ??
        library
            .where((i) => titles.contains('${i['Name']}'.toLowerCase()))
            .firstOrNull;
    if (item == null) return null;
    if (movie) return 'movie/${item['Id']}';
    final first = (zip['episodes'] as Map?)?['1'] as Map?;
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
    // An anime-ordered series (one per AniList entry) has no TVDB season to find: it starts at its beginning.
    final start = max(
      0,
      list.indexWhere(
        (e) => e['ParentIndexNumber'] == season && e['IndexNumber'] == episode,
      ),
    );
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
    final audio = [
      for (final t in tracks)
        if (t['Type'] == 'Audio') t,
    ];
    Map? language(String code) =>
        audio.where((t) => t['Language'] == code).firstOrNull;
    final wanted = dub ? language('eng') : language('jpn') ?? audio.firstOrNull;
    if (dub && wanted == null) return [];
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
    final container = '${source['Container'] ?? 'mkv'}'.split(',').first;
    // The file as it is plays the file's own audio, so it's offered when that's the one asked for.
    final direct =
        wanted == null ||
        audio.length == 1 ||
        wanted['Index'] == source['DefaultAudioStreamIndex'];
    return [
      if (direct)
        VideoStream(
          'Jellyfin',
          '$base/Videos/$id/stream.$container?static=true&MediaSourceId=$sourceId&ApiKey=$token',
          _headers,
          subtitles: subtitles(embedded: false),
        ),
      // The server's HLS: plays where the file's codecs don't, and picks the audio track itself.
      VideoStream(
        'Jellyfin (transcoded)',
        '$base/Videos/$id/master.m3u8?MediaSourceId=$sourceId'
            '&DeviceId=${Settings.jellyfinDevice}&PlaySessionId=${Random().nextInt(1 << 32)}'
            '${wanted == null ? '' : '&AudioStreamIndex=${wanted['Index']}'}'
            '&VideoCodec=h264,hevc&AudioCodec=aac&TranscodingMaxAudioChannels=2'
            '&SegmentContainer=ts&ApiKey=$token',
        _headers,
        subtitles: subtitles(embedded: true),
      ),
    ];
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'hls_proxy.dart';
import 'metadata.dart';
import 'settings.dart';
import 'sources.dart';

/// How SeaDex's editors rate a release: the best one for the show, or an alternative to it.
enum Curated { best, alt }

/// A torrent listed on Nyaa, or picked on SeaDex.
class Release {
  const Release(
    this.title,
    this.hash, {
    this.seeders = 0,
    this.trusted = false,
    this.curated,
    this.files,
    this.page,
  });
  final String title, hash;
  final int seeders;
  final bool trusted;

  /// Its rating on SeaDex; null when it isn't there.
  final Curated? curated;

  /// The names of its files, when known before it's added (SeaDex lists them).
  final List<String>? files;

  /// Its page on Nyaa, which shows its seeders, for one found on SeaDex.
  final String? page;

  /// The group that released it: the "[Group]" its title starts with.
  String? get group => RegExp(r'^\[([^\]]+)\]').firstMatch(title)?[1];

  String get magnet =>
      'magnet:?xt=urn:btih:$hash&dn=${Uri.encodeQueryComponent(title)}'
      '&tr=${Uri.encodeQueryComponent('http://nyaa.tracker.wf:7777/announce')}'
      '&tr=${Uri.encodeQueryComponent('udp://tracker.opentrackr.org:1337/announce')}';
}

/// The releases in a Nyaa RSS page.
List<Release> nyaaReleases(String rss) => [
  for (final item in RegExp(r'<item>([\s\S]*?)</item>').allMatches(rss))
    if (_tag(item[1]!, 'nyaa:infoHash') case final hash?)
      Release(
        _unescape(_tag(item[1]!, 'title') ?? ''),
        hash.toLowerCase(),
        seeders: int.tryParse(_tag(item[1]!, 'nyaa:seeders') ?? '') ?? 0,
        trusted: _tag(item[1]!, 'nyaa:trusted') == 'Yes',
      ),
];

/// The releases in SeaDex's answer for a show ([show] names them), those on Nyaa: a private tracker's hash is
/// withheld. SeaDex lists no seeders.
List<Release> seadexReleases(Map json, String show) => [
  for (final entry in json['items'] as List? ?? const [])
    for (final t in entry['expand']?['trs'] as List? ?? const [])
      if (t['tracker'] == 'Nyaa' &&
          RegExp(r'^[0-9a-fA-F]{40}$').hasMatch('${t['infoHash']}'))
        Release(
          [
            '[${t['releaseGroup']}] $show',
            if (t['dualAudio'] == true) '[Dual Audio]',
            // Its files say what the release doesn't: the resolution, which ranks it.
            if (RegExp(
                  r'\b(2160|1080|720|480)p\b',
                ).firstMatch('${(t['files'] as List?)?.firstOrNull?['name']}')
                case final m?)
              '(${m[0]})',
          ].join(' '),
          '${t['infoHash']}'.toLowerCase(),
          curated: t['isBest'] == true ? Curated.best : Curated.alt,
          files: [
            for (final f in t['files'] as List? ?? const [])
              '${f['name']}'.split('/').last,
          ],
          page: '${t['url']}',
        ),
];

/// The seeders and trust a Nyaa torrent page shows.
({int seeders, bool trusted}) nyaaPage(String html) => (
  seeders:
      int.tryParse(
        RegExp(r'Seeders:</div>\s*<div[^>]*>\s*<span[^>]*>(\d+)')
                .firstMatch(html)?[1] ??
            '',
      ) ??
      0,
  trusted: html.contains('panel panel-success'),
);

String? _tag(String xml, String name) =>
    RegExp('<$name>([^<]*)</$name>').firstMatch(xml)?[1]?.trim();

String _unescape(String s) => s
    .replaceAllMapped(
      RegExp(r'&#(\d+);'),
      (m) => String.fromCharCode(int.parse(m[1]!)),
    )
    .replaceAll('&quot;', '"')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');

/// What a release or file name says it holds: the season it names, if any, and its first and last episode (the same
/// for one episode); no episodes when it numbers none (a season pack).
typedef Held = ({int? season, num? from, num? to});

Held episodesIn(String name) {
  final s = name
      .replaceAll(
        RegExp(
          r'\[[0-9a-f]{8}\]|\.(mkv|mp4|avi|webm)$|\b\d{3,4}[pi]\b|\b\d{3,4}x\d{3,4}\b|\b[xh]\.?26[45]\b'
          r'|\b(?:8|10)[- ]?bits?\b|\d\.\d\b|\b(?:19|20)\d\d\b',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll('_', ' ');
  num n(String v) => num.parse(v);
  final se = RegExp(
    r'\bS(\d{1,2})[\s.]?E(\d{1,4}(?:\.5)?)(?:v\d)?(?:\s?-\s?E?(\d{1,4}))?\b',
    caseSensitive: false,
  ).firstMatch(s);
  if (se != null) {
    return (season: int.parse(se[1]!), from: n(se[2]!), to: n(se[3] ?? se[2]!));
  }
  final marker = RegExp(
    r'\bS(\d{1,2})(?:v\d)?\b|\bSeason (\d{1,2})\b|\b(\d{1,2})(?:st|nd|rd|th) Season\b',
    caseSensitive: false,
  ).firstMatch(s);
  final season = marker == null
      ? null
      : int.parse(marker[1] ?? marker[2] ?? marker[3]!);
  // "(01-28)", "01 ~ 12"; never "Title - 05", which is one episode.
  final range = RegExp(
    r'(?<![\w.])(\d{1,4})(?:-|\s?~\s?| to )(\d{1,4})(?![\w.])',
  ).firstMatch(s);
  if (range != null && n(range[1]!) < n(range[2]!)) {
    return (season: season, from: n(range[1]!), to: n(range[2]!));
  }
  final one =
      // The last " - 05": a title may have a " - " of its own.
      RegExp(r'\s-\s(\d{1,4}(?:\.5)?)(?:v\d)?(?=\s|$|\[|\()')
          .allMatches(s)
          .lastOrNull ??
      RegExp(
        r'\bEp?(?:isode)?\.?\s?(\d{1,4})(?:v\d)?\b',
        caseSensitive: false,
      ).firstMatch(s) ??
      RegExp(r'\[(\d{1,4})(?:v\d)?\]').firstMatch(s) ??
      RegExp(r'^\s*(\d{1,4})(?:v\d)?(?=\s|$)').firstMatch(s);
  final v = one == null ? null : n(one[1]!);
  return (season: season, from: v, to: v);
}

/// Whether [held] has episode [n] of the AniList entry, which is TVDB [season] and counts [absolute] from the
/// show's start. A name without a season counts from the start (most groups number sequels on).
// shortcut: with ani.zip down a sequel's "Show - 03" passes for its episode 3, when a release with no season is S1's
bool covers(Held held, num n, {num? absolute, int season = 1}) {
  final want = held.season == null
      ? absolute ?? n
      : held.season == season
      ? n
      : null;
  if (want == null || held.from == null) return false;
  return held.from! <= want && want <= held.to!;
}

/// A season pack that numbers no episodes ("Show - S01", "Show 2nd Season [Batch]"), whose files are looked through
/// for the one wanted. One naming no season counts only when it says it's a batch, and as the first season.
bool _wholeSeason(Held held, String title, int season) =>
    held.from == null &&
    (held.season != null
        ? held.season == season
        : season == 1 &&
              RegExp(r'batch|complete', caseSensitive: false).hasMatch(title));

const _videoExtensions = {'mkv', 'mp4', 'avi', 'webm', 'm4v'};

/// The file in a torrent that holds the episode: the one whose name numbers it, else its only video.
int? pickFile(List<String> names, bool Function(String name) wanted) {
  final videos = [
    for (final (i, name) in names.indexed)
      if (_videoExtensions.contains(name.split('.').last.toLowerCase())) i,
  ];
  return videos.where((i) => wanted(names[i])).firstOrNull ??
      (videos.length == 1 ? videos.single : null);
}

/// A debrid service: it fetches the torrent on its own servers and hands back a plain HTTPS link.
abstract class Debrid {
  /// A link to the file [wanted] picks in [release]; throws when the service can't give one at once (not cached).
  Future<String> link(Release release, bool Function(String name) wanted);

  /// The services the user saved a key for, in the order they're tried.
  static List<Debrid> get saved => [
    if (Settings.torboxKey.isNotEmpty) TorBox(Settings.torboxKey),
    if (Settings.realDebridKey.isNotEmpty) RealDebrid(Settings.realDebridKey),
  ];
}

Future<dynamic> _json(http.BaseRequest request) async {
  final response = await send(request);
  if (response.statusCode >= 300) {
    throw HttpException('HTTP ${response.statusCode}', uri: request.url);
  }
  return response.body.isEmpty ? null : jsonDecode(response.body);
}

class TorBox implements Debrid {
  TorBox(this.key);
  final String key;

  static const _api = 'https://api.torbox.app/v1/api/torrents';
  Map<String, String> get _auth => {'Authorization': 'Bearer $key'};

  Future<dynamic> _get(String path) async {
    final body = await _json(
      http.Request('GET', Uri.parse('$_api/$path'))..headers.addAll(_auth),
    );
    if (body['success'] != true) throw StateError('${body['detail']}');
    return body['data'];
  }

  /// Which of [hashes] TorBox has ready.
  Future<Set<String>> cached(Iterable<String> hashes) async => {
    for (final t
        in await _get('checkcached?hash=${hashes.join(',')}&format=list')
                as List? ??
            const [])
      '${t['hash']}'.toLowerCase(),
  };

  @override
  Future<String> link(Release release, bool Function(String) wanted) async {
    final added = await _json(
      http.MultipartRequest('POST', Uri.parse('$_api/createtorrent'))
        ..headers.addAll(_auth)
        // Nothing is left downloading on the account for a torrent it doesn't have.
        ..fields.addAll({
          'magnet': release.magnet,
          'add_only_if_cached': 'true',
        }),
    );
    if (added['success'] != true) throw StateError('${added['detail']}');
    final id = added['data']['torrent_id'];
    final files =
        (await _get('mylist?id=$id&bypass_cache=true'))['files'] as List;
    final pick = pickFile([
      for (final f in files) '${f['short_name'] ?? f['name']}',
    ], wanted);
    if (pick == null) throw StateError('No such episode in the torrent');
    return '${await _get('requestdl?token=$key&torrent_id=$id&file_id=${files[pick]['id']}')}';
  }
}

class RealDebrid implements Debrid {
  RealDebrid(this.key);
  final String key;

  static const _api = 'https://api.real-debrid.com/rest/1.0';

  /// How long a torrent added gets to show it was cached; replaced in tests.
  @visibleForTesting
  static Duration wait = const Duration(seconds: 1);

  Future<dynamic> _call(
    String method,
    String path, [
    Map<String, String>? form,
  ]) => _json(
    http.Request(method, Uri.parse('$_api/$path'))
      ..headers['Authorization'] = 'Bearer $key'
      ..bodyFields = form ?? const {},
  );

  @override
  Future<String> link(Release release, bool Function(String) wanted) async {
    final id = (await _call('POST', 'torrents/addMagnet', {
      'magnet': release.magnet,
    }))['id'];
    try {
      Future<Map> info() async => await _call('GET', 'torrents/info/$id');
      var torrent = await info();
      for (var i = 0; torrent['status'] == 'magnet_conversion' && i < 10; i++) {
        await Future.delayed(wait);
        torrent = await info();
      }
      final files = torrent['files'] as List;
      final pick = pickFile([
        for (final f in files)
          '${f['path']}'.split('/').last, // without its folders
      ], wanted);
      if (pick == null) throw StateError('No such episode in the torrent');
      await _call('POST', 'torrents/selectFiles/$id', {
        'files': '${files[pick]['id']}',
      });
      // Cached, it's downloaded at once; anything else would make the player wait for Real-Debrid to fetch it.
      for (var i = 0; i < 3; i++) {
        torrent = await info();
        if (torrent['status'] == 'downloaded') break;
        await Future.delayed(wait);
      }
      if (torrent['status'] != 'downloaded') throw StateError('Not cached');
      return (await _call('POST', 'unrestrict/link', {
        'link': (torrent['links'] as List).first,
      }))['download'];
    } catch (_) {
      await _call('DELETE', 'torrents/delete/$id').catchError((_) {});
      rethrow;
    }
  }
}

/// Peer-to-peer streaming through rqbit, a torrent engine shipped beside the app on desktop and run as a local HTTP
/// server, as Stremio runs its own. One torrent at a time: the last one is deleted, with what it fetched, when another
/// starts.
// shortcut: desktop only; Android needs rqbit built for it with the NDK, and iOS can't run a second program.
class PeerEngine {
  /// The rqbit program beside the app's own; replaced in tests.
  @visibleForTesting
  static String program =
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}'
      '${Platform.isWindows ? 'rqbit.exe' : 'rqbit'}';

  /// Where rqbit's API answers once started; set in tests to stand in for it.
  @visibleForTesting
  static Future<String>? api;

  static String? _current;
  static int? _pid;
  static AppLifecycleListener? _exit;

  static bool get available =>
      (Platform.isLinux || Platform.isWindows || Platform.isMacOS) &&
      File(program).existsSync();

  /// Where rqbit streams the file [wanted] picks in [release].
  static Future<String> stream(
    Release release,
    bool Function(String) wanted,
  ) async {
    // A failed start is tried afresh next time.
    final base = await (api ??= _start().catchError((Object e) {
      api = null;
      throw e;
    }));
    Future<dynamic> post(String path, [Object body = '']) => _json(
      http.Request('POST', Uri.parse('$base$path'))
        ..body = body is String ? body : jsonEncode(body)
        ..headers['content-type'] = body is String
            ? 'text/plain'
            : 'application/json', // rqbit refuses JSON sent as anything else
    );
    final files =
        (await post(
              '/torrents?list_only=true',
              release.magnet,
            ))['details']['files']
            as List;
    final pick = pickFile([
      for (final f in files) '${(f['components'] as List?)?.last ?? f['name']}',
    ], wanted);
    if (pick == null) throw StateError('No such episode in the torrent');
    if (_current case final old? when old != release.hash) {
      await post('/torrents/$old/delete').catchError((_) {});
    }
    final added = await post(
      '/torrents?overwrite=true&only_files=$pick',
      release.magnet,
    );
    final id = added['id'];
    // Already added for another episode of the same batch: it fetches this one's file instead. (A torrent just
    // added has it already, and can't be changed while it starts.)
    if (added['details']['files'][pick]['included'] != true) {
      await post('/torrents/$id/update_only_files', {
        'only_files': [pick],
      });
    }
    _current = release.hash;
    return '$base/torrents/$id/stream/$pick';
  }

  static Future<String> _start() async {
    final temp = (await getTemporaryDirectory()).path;
    final pidFile = File('$temp/aniview-rqbit.pid');
    await _stopStale(pidFile);
    final dir = Directory('$temp/aniview-torrents');
    // What an earlier session streamed: nothing keeps it.
    if (await dir.exists()) await dir.delete(recursive: true);
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    // Detached: on Windows a console program started otherwise opens a console window.
    final process = await Process.start(program, [
      '-v', 'warn',
      '--http-api-listen-addr', '127.0.0.1:$port',
      // Connects out only: no listening port to forward, nor a firewall prompt.
      '--disable-tcp-listen', '--disable-upnp-port-forward',
      '--disable-dht-persistence',
      'server', 'start', '--disable-persistence', dir.path,
    ], mode: ProcessStartMode.detachedWithStdio);
    _pid = process.pid;
    final log = <String>[];
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => (log..add(line)).length > 5 ? log.removeAt(0) : null);
    process.stdout.drain<void>().ignore();
    try {
      await pidFile.writeAsString('${process.pid}');
      _exit ??= AppLifecycleListener(
        onExitRequested: () async {
          if (_pid case final pid?) Process.killPid(pid);
          return AppExitResponse.exit;
        },
      );
      final base = 'http://127.0.0.1:$port';
      for (var i = 0; i < 100; i++) {
        try {
          await _json(http.Request('GET', Uri.parse('$base/')));
          return base;
        } catch (_) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }
      throw StateError('The torrent engine didn\'t start: ${log.join(' ')}');
    } catch (_) {
      Process.killPid(process.pid);
      rethrow;
    }
  }

  /// Ends the rqbit an earlier session left running (it closed without asking, or crashed), which would go on
  /// sharing its torrent. Only when that process is still rqbit: its number may have passed to another.
  static Future<void> _stopStale(File pidFile) async {
    try {
      final pid = int.parse(await pidFile.readAsString());
      final listing = Platform.isWindows
          ? await Process.run('tasklist', ['/FI', 'PID eq $pid', '/NH'])
          : await Process.run('ps', ['-p', '$pid', '-o', 'comm=']);
      if ('${listing.stdout}'.contains('rqbit')) Process.killPid(pid);
    } catch (_) {} // none recorded, or nothing to end
  }
}

/// Shows found on Nyaa, played through the user's debrid services when they have the torrent cached, else peer to
/// peer where [PeerEngine] runs.
/// A match is the entry's episode count: torrents aren't listed by show, so every episode it has is offered, and
/// each one's releases are looked up when it plays.
class TorrentSource extends Source {
  TorrentSource({this.net = const HttpNet()})
    : super('Torrents', 'https://nyaa.si');

  final Net net;

  // shortcut: no manual matching; the search titles come from AniList. Search Nyaa here if titles prove unreliable.
  @override
  Future<List<SearchResult>> search(String query) async => const [];

  @override
  Future<String?> match(Map media) async {
    final count =
        media['episodes'] as int? ??
        switch (media['nextAiringEpisode']?['episode']) {
          final int next => next - 1,
          _ => null,
        } ??
        await mappingsOf(media)
            .then((z) => z['episodeCount'] as int?, onError: (_) => null);
    return count == null || count < 1 ? null : '$count';
  }

  @override
  Future<List<Episode>> episodesOf(String id) async => [
    for (var n = 1; n <= int.parse(id); n++) Episode(n, ref: n),
  ];

  @override
  Future<List<VideoStream>> streams(
    Map media,
    Episode episode, {
    required bool dub,
  }) async {
    Map zip;
    try {
      zip = await mappingsOf(media);
    } catch (_) {
      zip = const {};
    }
    final episodes = zip['episodes'] as Map? ?? const {};
    final n = episode.number;
    final absolute =
        episodes[epNumber(n)]?['absoluteEpisodeNumber'] as num? ?? n;
    final season = episodes['1']?['seasonNumber'] as int? ?? 1;
    final show = '${media['id'] ?? 'mal:${media['idMal']}'}';
    final (listed, picks) = await (
      this.releases(media, n, absolute, zip: zip, season: season),
      curatedReleases(media, zip),
    ).wait;
    // A pick found on Nyaa too keeps Nyaa's title and seeders.
    final byHash = {for (final r in listed) r.hash: r};
    final releases = [
      for (final r in picks)
        if (byHash.remove(r.hash) case final on?)
          Release(
            on.title,
            r.hash,
            seeders: on.seeders,
            trusted: on.trusted,
            curated: r.curated,
            files: r.files,
          )
        else
          r,
      ...byHash.values,
    ];

    bool wanted(String file) {
      final held = episodesIn(file);
      return held.from == held.to &&
          covers(held, n, absolute: absolute, season: season);
    }

    bool holds(Release r) {
      if (r.files case final files?) return pickFile(files, wanted) != null;
      final held = episodesIn(r.title);
      return covers(held, n, absolute: absolute, season: season) ||
          _wholeSeason(held, r.title, season);
    }

    final torbox = Debrid.saved.whereType<TorBox>().firstOrNull;
    final found = await Future.wait([
      for (final r in releases)
        if (holds(r) &&
            (!dub ||
                RegExp(
                  r'dual[- ]?audio|\bdub',
                  caseSensitive: false,
                ).hasMatch(r.title)))
          r.page == null ? Future.value(r) : _seeded(r),
    ]);
    final cached = torbox == null || found.isEmpty
        ? const <String>{}
        : await torbox
              .cached(found.map((r) => r.hash))
              .catchError((_) => <String>{});
    // TorBox alone says up front what it can play; Real-Debrid only says so once one is tried.
    final onlyCached =
        torbox != null && Debrid.saved.length == 1 && !PeerEngine.available;
    final ranked = rankReleases(
      found,
      cached,
      group: Settings.torrentGroup(show),
    ).where((r) => !onlyCached || cached.contains(r.hash)).take(6);
    return [
      for (final r in ranked)
        VideoStream(
          _label(r, cached.contains(r.hash)),
          await HlsProxy.deferred(() async {
            final url = await play(r, wanted);
            // The next episodes rank this group first, so a show doesn't change hands halfway.
            if (r.group case final group?) {
              Settings.rememberTorrentGroup(show, group);
            }
            return url;
          }, 'mkv'),
          const {},
        ),
    ];
  }

  /// SeaDex's (releases.moe) picks for the show, found by its AniList id: none for a show AniList doesn't know, or
  /// while SeaDex is down.
  Future<List<Release>> curatedReleases(Map media, Map zip) async {
    final id = media['id'] ?? zip['mappings']?['anilist_id'];
    if (id is! int) return const [];
    try {
      final json = jsonDecode(
        await net.text(
          'https://seadex.moe/api/collections/entries/records'
          '?filter=${Uri.encodeQueryComponent('alID=$id')}&expand=trs&skipTotal=1',
        ),
      );
      final title = media['title'] as Map?;
      return seadexReleases(
        json,
        '${title?['english'] ?? title?['romaji'] ?? ''}'.trim(),
      );
    } catch (_) {
      return const [];
    }
  }

  /// [r] with the seeders its Nyaa page shows, which SeaDex doesn't list; as it was when the page can't be read.
  Future<Release> _seeded(Release r) async {
    if (!r.page!.startsWith('https://nyaa.si/view/')) return r;
    try {
      final page = nyaaPage(await net.text(r.page!));
      return Release(
        r.title,
        r.hash,
        seeders: page.seeders,
        trusted: page.trusted,
        curated: r.curated,
        files: r.files,
      );
    } catch (_) {
      return r;
    }
  }

  /// Nyaa's releases for the show: by title (whole seasons, the most seeded first), and by title and episode.
  Future<List<Release>> releases(
    Map media,
    num n,
    num absolute, {
    Map zip = const {},
    int season = 1,
  }) async {
    String q(String query, [String sort = '']) =>
        '$base/?page=rss&c=1_2&f=0&q=${Uri.encodeQueryComponent(query)}$sort';
    final pages = await Future.wait([
      for (final url in {
        for (final t in searchTitles(media, zip)) ...[
          q(t, '&s=seeders&o=desc'),
          q('$t ${epNumber(absolute).padLeft(2, '0')}'),
          if (absolute != n) q('$t ${epNumber(n).padLeft(2, '0')}'),
          // A sequel's episode named by its season: "Show S2 - 05".
          if (season > 1) q('$t S$season ${epNumber(n).padLeft(2, '0')}'),
        ],
      })
        net.text(url).then(nyaaReleases, onError: (_) => <Release>[]),
    ]);
    final seen = <String>{};
    return [
      for (final page in pages)
        for (final r in page)
          if (seen.add(r.hash)) r,
    ];
  }

  /// The address the release plays from: the first debrid service with it cached, else rqbit's. Throws when neither
  /// can play it, and the player moves on to the next release.
  @visibleForTesting
  static Future<String> play(Release r, bool Function(String) wanted) async {
    Object error = StateError('No debrid service has it cached');
    for (final debrid in Debrid.saved) {
      try {
        return await debrid.link(r, wanted);
      } catch (e) {
        error = e; // not cached there: the next service
      }
    }
    if (!PeerEngine.available) throw error;
    return PeerEngine.stream(r, wanted);
  }
}

/// What Nyaa is searched for, at most [max]: the show's romaji and English titles, then ani.zip's and AniList's
/// synonyms, without the season or year AniList adds; then the same without punctuation, which groups often drop.
List<String> searchTitles(Map media, Map zip, {int max = 4}) {
  final suffix = RegExp(
    r'[\s:]*(\(\d{4}\)|\d+(st|nd|rd|th) Season|Season \d+|Part \d+|Cour \d+)$',
    caseSensitive: false,
  );
  final bases = [
    for (final t in [
      media['title']?['romaji'],
      media['title']?['english'],
      zip['titles']?['x-jat'],
      zip['titles']?['en'],
      ...?(media['synonyms'] as List?),
    ])
      // Nyaa's English-translated releases are named in Latin letters.
      if (t is String && !RegExp(r'[^\u0000-\u024F]').hasMatch(t))
        t.replaceAll('`', "'").replaceFirst(suffix, '').trim(),
  ];
  String plain(String t) => t
      .replaceAll(RegExp(r'''['’"]'''), '')
      .replaceAll(RegExp(r'[:!?,.\-–]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final seen = <String>{};
  return [
    for (final t in [...bases, ...bases.map(plain)])
      if (t.length >= 3 && seen.add(t.toLowerCase())) t,
  ].take(max).toList();
}

/// [releases] best first: cached on the debrid service, from the [group] last played for the show, SeaDex's best
/// then its alternatives, from a trusted uploader, 1080p, one episode rather than a whole season, then the most
/// seeded. A dead torrent is left out unless cached.
List<Release> rankReleases(
  List<Release> releases,
  Set<String> cached, {
  String? group,
}) {
  int resolution(Release r) => r.title.contains('1080')
      ? 3
      : r.title.contains('720')
      ? 2
      : r.title.contains('2160')
      ? 1
      : 0;
  bool single(Release r) {
    final held = episodesIn(r.title);
    return held.from != null && held.from == held.to;
  }

  int curation(Release r) => switch (r.curated) {
    Curated.best => 2,
    Curated.alt => 1,
    null => 0,
  };
  int flag(bool b) => b ? 1 : 0;
  return [
    for (final r in releases)
      if (r.seeders > 0 || cached.contains(r.hash)) r,
  ]..sort(
    (a, b) => [
      flag(cached.contains(b.hash)) - flag(cached.contains(a.hash)),
      flag(group != null && b.group == group) -
          flag(group != null && a.group == group),
      curation(b) - curation(a),
      flag(b.trusted) - flag(a.trusted),
      resolution(b) - resolution(a),
      flag(single(b)) - flag(single(a)),
      b.seeders - a.seeders,
    ].firstWhere((c) => c != 0, orElse: () => 0),
  );
}

String _label(Release r, bool cached) => [
  r.group ?? 'Torrent',
  ?RegExp(r'\b(2160|1080|720|480)p\b').firstMatch(r.title)?[0],
  if (episodesIn(r.title) case (from: final a, to: final b, season: _)
      when a == null || a != b)
    'batch',
  ?switch (r.curated) {
    Curated.best => 'SeaDex best',
    Curated.alt => 'SeaDex alt',
    null => null,
  },
  cached ? 'cached' : '${r.seeders} seeds',
].join(' · ');

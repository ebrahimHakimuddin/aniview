import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http2/http2.dart' hide Settings;
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloudflare.dart';
import 'metadata.dart';
import 'settings.dart';

const userAgent =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36';

/// The supported anime streaming sites from everythingmoe's ranking at build time, in rank order: loaded once, and loaded
/// afresh on the next ask after a failed load.
class Sites {
  static Future<List<Source>>? _current;

  /// Where the list comes from; replaced in tests.
  @visibleForTesting
  static Future<List<Source>> Function() load = topSources;

  /// The same future until a load fails, so a FutureBuilder can hold on to it.
  static Future<List<Source>> all() =>
      _current ??= load().catchError((Object e) {
        _current = null;
        throw e;
      });

  /// The site saved under [name] (history, downloads), if it's still among the top sites.
  static Future<Source?> named(String name) async =>
      (await all()).where((s) => s.name == name).firstOrNull;

  /// The one chosen in Settings, else the highest ranked.
  static Source? preferred(List<Source> sites) =>
      sites.where((s) => s.name == Settings.preferredSource).firstOrNull ??
      sites.firstOrNull;
}

const _topSitesDefine = String.fromEnvironment('TOP_SITES');
final _topSites = _topSitesDefine.isEmpty
    ? throw StateError(
        r'Built without --dart-define=TOP_SITES="$(fvm dart tool/top_sites.dart)"',
      )
    : _topSitesDefine.split(';');

class CloudflareChallenge implements Exception {
  CloudflareChallenge(this.url);
  final String url;
  @override
  String toString() =>
      'Cloudflare verification required for ${Uri.parse(url).host}';
}

class Episode {
  const Episode(
    this.number, {
    this.title,
    this.thumbnail,
    this.overview,
    required this.ref,
  });
  final num number;
  final String? title, thumbnail, overview;
  final Object ref; // site-specific handle used to resolve streams

  Episode withInfo(EpisodeInfo? info) => info == null
      ? this
      : Episode(
          number,
          // Sites often fill in placeholder titles like "Episode 1"; prefer the real one when ani.zip has it.
          title: title == null || RegExp(r'^Episode \d+$').hasMatch(title!)
              ? info.title ?? title
              : title,
          thumbnail: info.image ?? thumbnail,
          overview: overview ?? info.overview,
          ref: ref,
        );

  Map<String, dynamic> toJson() => {
    'number': number,
    'title': title,
    'thumbnail': thumbnail,
    'overview': overview,
    'ref': ref,
  };

  factory Episode.fromJson(Map json) => Episode(
    json['number'],
    title: json['title'],
    thumbnail: json['thumbnail'],
    overview: json['overview'],
    ref: json['ref'],
  );
}

class Subtitle {
  const Subtitle(this.label, this.url);
  final String label, url;
}

class VideoStream {
  const VideoStream(
    this.label,
    this.url,
    this.headers, {
    this.subtitles = const [],
    this.skips = const [],
  });
  final String label, url;
  final Map<String, String> headers;
  final List<Subtitle> subtitles; // soft subs, picked in the player
  final List<SkipTime> skips; // intro/outro times the site itself provides

  bool get isLocal => !url.startsWith('http'); // a downloaded episode on disk
  bool get isHls => Uri.parse(url).path.endsWith('.m3u8');
}

/// A show as listed on a site, used to fix a wrong automatic match.
class SearchResult {
  const SearchResult(this.id, this.title, {this.image, this.info});
  final String id, title;
  final String? image, info;
}

abstract class Source {
  Source(this.name, this.base);
  final String name, base;

  String get label => name;

  Future<List<SearchResult>> search(String query);

  /// The site's id for [media] when it can be matched confidently, else null.
  Future<String?> match(Map media);

  Future<List<Episode>> episodesOf(String id);

  Future<List<VideoStream>> streams(
    Map media,
    Episode episode, {
    required bool dub,
  });
}

String epNumber(num n) => n % 1 == 0 ? '${n.toInt()}' : '$n';

String _matchKey(Source source, Map media) =>
    'match:${source.name}:${media['id']}';

/// Episodes of [media] on [source] — the user's manual pick first, else the automatic match —
/// with titles and artwork from ani.zip.
Future<List<Episode>> loadEpisodes(Source source, Map media) async {
  final info = episodeInfo(media);
  final prefs = await SharedPreferences.getInstance();
  final id =
      prefs.getString(_matchKey(source, media)) ?? await source.match(media);
  if (id == null) return [];
  final episodes = await source.episodesOf(id);
  final art = await info;
  return [for (final e in episodes) e.withInfo(art[epNumber(e.number)])];
}

Future<void> setMatch(Source source, Map media, String id) async =>
    (await SharedPreferences.getInstance()).setString(
      _matchKey(source, media),
      id,
    );

Future<void> clearMatches() async {
  final prefs = await SharedPreferences.getInstance();
  for (final key
      in prefs.getKeys().where((k) => k.startsWith('match:')).toList()) {
    await prefs.remove(key);
  }
}

/// Every plain HTTP request the sites make; a MockClient in tests.
@visibleForTesting
http.Client httpClient = http.Client();

/// Hosts whose Cloudflare turns away HTTP/1.1 (all package:http speaks), e.g. animepahe's kwik player and its CDN.
final _h2Hosts = <String>{};

Future<http.Response> _get(String url, Map<String, String>? headers) async {
  final uri = Uri.parse(url);
  final all = {'User-Agent': userAgent, ...?headers};
  if (!_h2Hosts.contains(uri.host)) {
    final res = await httpClient.get(uri, headers: all);
    if (res.statusCode == 200) return res;
    if (res.statusCode != 403) {
      throw HttpException('HTTP ${res.statusCode}', uri: uri);
    }
  }
  final (status, response, body) = await h2Get(uri, all);
  if (status != 200) throw HttpException('HTTP $status', uri: uri);
  _h2Hosts.add(uri.host);
  return http.Response.bytes(
    body,
    status,
    headers: {'content-type': ?response['content-type']},
  );
}

Future<String> fetch(String url, {Map<String, String>? headers}) async =>
    (await _get(url, headers)).body;

Future<Uint8List> fetchBytes(
  String url, {
  Map<String, String>? headers,
}) async => (await _get(url, headers)).bodyBytes;

/// everythingmoe's ranking, fetched when the app is built by tool/top_sites.dart.
Future<List<Source>> topSources() async => [
  for (final [name, origin] in _topSites.map((s) => s.split('|')))
    // ponytail: unknown sites are skipped; add an adapter here when the ranking brings in a new one
    ?switch (Uri.parse(origin).host) {
      final h when h.contains('anikoto') => Anikoto(name, origin),
      final h when h.contains('animepahe') => AnimePahe(name, origin),
      final h when h.contains('reanime') => ReAnime(name, origin),
      _ => null,
    },
];

Iterable<String> _searchTitles(Map media) =>
    {media['title']['romaji'], media['title']['english']}.whereType<String>();

Map<String, String> _dataAttrs(String tag) => {
  for (final m in RegExp(r'data-([\w-]+)="([^"]*)"').allMatches(tag))
    m[1]!: m[2]!,
};

String _decodeHtml(String s) => s
    .replaceAll('&#039;', "'")
    .replaceAll('&quot;', '"')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');

String _info(List<Object?> parts) => parts.whereType<Object>().join(' · ');

/// megaplay embed -> HLS via getSourcesNew, with every subtitle track.
Future<List<VideoStream>> megaplay(
  String label,
  String embed, {
  required String referer,
}) async {
  final page = await fetch(embed, headers: {'Referer': referer});
  final id = RegExp(r'data-id="(\d+)"').firstMatch(page)?[1];
  if (id == null) return [];
  final uri = Uri.parse(embed);
  final server = uri.queryParameters['s'];
  final json = jsonDecode(
    await fetch(
      '${uri.origin}/stream/getSourcesNew?id=$id${server == null ? '' : '&s=$server'}',
      headers: {'X-Requested-With': 'XMLHttpRequest', 'Referer': embed},
    ),
  );
  if (json['enc'] is! String) return [];
  final file = decodeMegaplaySource(json['enc'])['file'] as String?;
  if (file == null) return [];
  final headers = {'Referer': '${uri.origin}/', 'User-Agent': userAgent};
  // Some of megaplay's CDN hosts answer 403 to anything but its own player (and which one a server gets
  // rotates), while the player only tries the first stream, so drop the ones that don't load.
  try {
    await fetch(file, headers: headers);
  } on HttpException {
    return [];
  }
  return [
    VideoStream(
      label,
      file,
      headers,
      subtitles: [
        for (final track in json['tracks'] as List? ?? const [])
          if (track['kind'] == 'captions' && track['file'] is String)
            Subtitle('${track['label'] ?? 'Unknown'}', track['file']),
      ],
      skips: [
        if (_range(json['intro']) case (final start, final end))
          SkipTime(SkipType.intro, start, end),
        if (_range(json['outro']) case (final start, final end))
          SkipTime(SkipType.outro, start, end),
      ],
    ),
  ];
}

/// getSourcesNew's `enc`: base64url AES-256-CBC JSON, key and IV from megaplay's newclient.min.js
/// (`trustAesKey`/`trustAesIv`, the key zero-padded to 32 bytes).
Map decodeMegaplaySource(String enc) {
  Uint8List pad(String s, int n) =>
      Uint8List(n)..setAll(0, utf8.encode(s).take(n));
  final cipher =
      PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))..init(
        false,
        PaddedBlockCipherParameters(
          ParametersWithIV(
            KeyParameter(pad('i?LMTAx0Q6,:}50U', 32)),
            pad("W0;27ToaUpl_P%'c", 16),
          ),
          null,
        ),
      );
  return jsonDecode(
    utf8.decode(cipher.process(base64Url.decode(base64Url.normalize(enc)))),
  );
}

(Duration, Duration)? _range(Object? json) {
  if (json is! Map ||
      json['start'] is! num ||
      json['end'] is! num ||
      json['end'] == 0) {
    return null;
  }
  return (
    Duration(seconds: (json['start'] as num).toInt()),
    Duration(seconds: (json['end'] as num).toInt()),
  );
}

class Anikoto extends Source {
  Anikoto(super.name, super.base);

  final _episodes = <String, List<Episode>>{};

  Map<String, String> get _ajax => {
    'X-Requested-With': 'XMLHttpRequest',
    'Referer': '$base/',
  };

  @override
  Future<List<SearchResult>> search(String query) async {
    final html = await fetch(
      '$base/filter?keyword=${Uri.encodeQueryComponent(query)}',
    );
    return [
      for (final item in html.split('<div class="item ').skip(1))
        if (RegExp(r'<a class="name d-title" href="([^"]+)"[^>]*>([^<]+)</a>')
                .firstMatch(item)
            case final m?)
          SearchResult(
            m[1]!,
            _decodeHtml(m[2]!.trim()),
            image: RegExp(r'<img src="([^"]+)"').firstMatch(item)?[1],
            info: RegExp(r'<div class="right">([^<]+)</div>')
                .firstMatch(item)?[1]
                ?.trim(),
          ),
    ];
  }

  @override
  Future<String?> match(Map media) async {
    for (final title in _searchTitles(media)) {
      for (final result in (await search(title)).take(5)) {
        final episodes = await episodesOf(result.id);
        // Each episode carries its MAL id, so only the right show is accepted.
        final mal = episodes.firstOrNull?.ref as Map?;
        if (mal != null &&
            (media['idMal'] == null || mal['mal'] == '${media['idMal']}')) {
          return result.id;
        }
      }
    }
    return null;
  }

  @override
  Future<List<Episode>> episodesOf(String id) async {
    if (_episodes[id] case final cached?) return cached;
    final page = await fetch(id);
    final showId = RegExp(r'id="watch-main"[^>]*?data-id="(\d+)"')
        .firstMatch(page)?[1];
    if (showId == null) return [];
    final html =
        jsonDecode(
              await fetch('$base/ajax/episode/list/$showId', headers: _ajax),
            )['result']
            as String;
    return _episodes[id] = RegExp(r'<a [^>]*data-num="[^>]*>')
        .allMatches(html)
        .map((m) => _dataAttrs(m[0]!))
        .map((a) => Episode(num.tryParse(a['num'] ?? '') ?? 0, ref: a))
        .toList();
  }

  @override
  Future<List<VideoStream>> streams(
    Map media,
    Episode episode, {
    required bool dub,
  }) async {
    final ids = (episode.ref as Map)['ids'];
    final html =
        jsonDecode(
              await fetch(
                '$base/ajax/server/list?servers=$ids',
                headers: _ajax,
              ),
            )['result']
            as String;
    final block =
        RegExp(
          'data-type="${dub ? 'dub' : 'sub'}">(.*?)</ul>',
          dotAll: true,
        ).firstMatch(html)?[1] ??
        '';
    final servers = RegExp(r'data-link-id="([^"]+)"[^>]*>([^<]+)<')
        .allMatches(block);
    final resolved = await Future.wait(
      servers.map((server) async {
        try {
          final result = jsonDecode(
            await fetch('$base/ajax/server?get=${server[1]}', headers: _ajax),
          )['result'];
          final url = result['url'] as String;
          // ponytail: only megaplay embeds are resolved; other hosts are skipped until an extractor is added
          return url.contains('megaplay')
              ? await megaplay(server[2]!.trim(), url, referer: '$base/')
              : <VideoStream>[];
        } catch (_) {
          return <VideoStream>[];
        }
      }),
    );
    return resolved.expand((s) => s).toList();
  }
}

class ReAnime extends Source {
  ReAnime(super.name, super.base);

  @override
  Future<List<SearchResult>> search(String query) async {
    final json = jsonDecode(
      await fetch(
        '$base/api/v1/search?limit=20&q=${Uri.encodeQueryComponent(query)}',
      ),
    );
    return [
      for (final r in json['results'] as List? ?? const [])
        // The id keeps the entry's AniList id too, so streams follow a manual pick.
        SearchResult(
          '${r['anime_id']}|${r['anilist_id'] ?? ''}',
          '${r['title']?['english'] ?? r['title']?['romaji'] ?? r['anime_id']}',
          image: r['cover_image']?['large'],
          info: _info([
            r['format'],
            r['season_year'],
            if (r['episodes'] != null) '${r['episodes']} eps',
          ]),
        ),
    ];
  }

  @override
  Future<String?> match(Map media) async {
    for (final title in _searchTitles(media)) {
      final hit = (await search(title))
          .where((r) => r.id.endsWith('|${media['id']}'))
          .firstOrNull;
      if (hit != null) return hit.id;
    }
    return null;
  }

  @override
  Future<List<Episode>> episodesOf(String id) async {
    final [animeId, anilistId] = id.split('|');
    final data =
        jsonDecode(
              await fetch('$base/api/v1/anime/$animeId/episodes?limit=5000'),
            )['data']
            as List? ??
        const [];
    return [
      for (final e in data)
        Episode(
          e['episode_number'],
          title: (e['title'] as String?)?.nullIfEmpty,
          thumbnail: (e['thumbnail'] as String?)?.nullIfEmpty,
          ref: anilistId,
        ),
    ];
  }

  // Re:ANIME's own flixcloud servers ship encrypted payloads; megaplay serves the same episode by AniList id.
  @override
  Future<List<VideoStream>> streams(
    Map media,
    Episode episode, {
    required bool dub,
  }) async {
    final embed =
        'https://megaplay.buzz/stream/ani/${(episode.ref as String).nullIfEmpty ?? media['id']}'
        '/${epNumber(episode.number)}/${dub ? 'dub' : 'sub'}';
    final found = await Future.wait([
      for (final (label, server) in [('HD-1', 'tcdn'), ('HD-2', 'bcdn')])
        megaplay(
          label,
          '$embed?s=$server',
          referer: '$base/',
        ).catchError((Object _) => <VideoStream>[]),
    ]);
    return found.expand((s) => s).toList();
  }
}

/// animepahe sits behind a Cloudflare JavaScript challenge: the in-app browser clears it once and the clearance is
/// reused over HTTP/2 ([clearedFetch]). Its kwik player and CDN only refuse HTTP/1.1, which [fetch] handles.
class AnimePahe extends Source {
  AnimePahe(super.name, super.base);

  Future<dynamic> _api(String query) async =>
      jsonDecode(await clearedFetch('$base/api?$query'));

  @override
  Future<List<SearchResult>> search(String query) async {
    final json = await _api('m=search&q=${Uri.encodeQueryComponent(query)}');
    return [
      for (final r in json['data'] as List? ?? const [])
        SearchResult(
          '${r['session']}',
          '${r['title']}',
          image: r['poster'],
          info: _info([
            r['type'],
            r['year'],
            if (r['episodes'] != null) '${r['episodes']} eps',
          ]),
        ),
    ];
  }

  @override
  Future<String?> match(Map media) async {
    final links = RegExp(
      'anilist\\.co/anime/${media['id']}\\b|myanimelist\\.net/anime/${media['idMal'] ?? 'none'}\\b',
    );
    for (final title in _searchTitles(media)) {
      for (final result in (await search(title)).take(3)) {
        if (links.hasMatch(await clearedFetch('$base/anime/${result.id}'))) {
          return result.id;
        }
      }
    }
    return null;
  }

  @override
  Future<List<Episode>> episodesOf(String id) async {
    final raw = <Map>[];
    for (var page = 1, last = 1; page <= last; page++) {
      final json = await _api('m=release&id=$id&sort=episode_asc&page=$page');
      last = json['last_page'] ?? 1;
      raw.addAll((json['data'] as List? ?? const []).cast<Map>());
    }
    if (raw.isEmpty) return [];
    // animepahe keeps counting across seasons (S2 starts at 13); renumber from 1.
    final offset = ((raw.first['episode'] as num) - 1).clamp(
      0,
      double.infinity,
    );
    return [
      for (final e in raw)
        Episode(
          (e['episode'] as num) - offset,
          thumbnail: e['snapshot'],
          ref: '$id/${e['session']}',
        ),
    ];
  }

  @override
  Future<List<VideoStream>> streams(
    Map media,
    Episode episode, {
    required bool dub,
  }) async {
    final play = await clearedFetch(
      '$base/play/${episode.ref}',
      referer: '$base/',
    );
    final buttons =
        RegExp(r'<button[^>]*data-src="[^"]*"[^>]*>')
            .allMatches(play)
            .map((m) => _dataAttrs(m[0]!))
            .where((b) => (b['audio'] == 'eng') == dub)
            .toList()
          ..sort(
            (a, b) => (int.tryParse(b['resolution'] ?? '') ?? 0).compareTo(
              int.tryParse(a['resolution'] ?? '') ?? 0,
            ),
          );
    final resolved = await Future.wait(
      buttons.map((button) async {
        try {
          final kwik = Uri.parse(button['src']!);
          final html = await fetch('$kwik', headers: {'Referer': '$base/'});
          final m3u8 = RegExp(r'''https?://[^'"\\\s]+\.m3u8[^'"\\\s]*''')
              .firstMatch(unpack(html))?[0];
          if (m3u8 == null) return null;
          return VideoStream(
            '${button['fansub'] ?? 'Kwik'} ${button['resolution']}p',
            m3u8,
            {'Referer': '${kwik.origin}/', 'User-Agent': userAgent},
          );
        } catch (_) {
          return null;
        }
      }),
    );
    return resolved.nonNulls.toList();
  }
}

/// Expands Dean Edwards' p.a.c.k.e.r `eval(function(p,a,c,k,e,d){...}('...',a,c,'...'.split('|')))` scripts.
String unpack(String js) {
  final m = RegExp(
    r"\}\('(.*)',\s*(\d+),\s*(\d+),\s*'(.*?)'\.split\('\|'\)",
    dotAll: true,
  ).firstMatch(js);
  if (m == null) return js;
  final radix = int.parse(m[2]!),
      count = int.parse(m[3]!),
      words = m[4]!.split('|');
  String encode(int n) =>
      (n < radix ? '' : encode(n ~/ radix)) +
      (n % radix > 35
          ? String.fromCharCode(n % radix + 29)
          : (n % radix).toRadixString(36));
  final dict = {
    for (var i = 0; i < count; i++)
      encode(i): i < words.length && words[i].isNotEmpty ? words[i] : encode(i),
  };
  return m[1]!
      .replaceAll(r"\'", "'")
      .replaceAllMapped(RegExp(r'\b\w+\b'), (w) => dict[w[0]] ?? w[0]!);
}

/// One HTTP/2 GET. package:http speaks only HTTP/1.1, which Cloudflare turns away on some sites (animepahe).
/// [extra] overrides the default user agent; names are lowercased as HTTP/2 requires.
// ponytail: a new connection per request (HLS segments included); pool ClientTransportConnections per host if
// segment loads get slow
Future<(int, Map<String, String>, Uint8List)> h2Get(
  Uri uri, [
  Map<String, String> extra = const {},
]) async {
  final headers = {
    'user-agent': userAgent,
    for (final MapEntry(:key, :value) in extra.entries)
      key.toLowerCase(): value,
  };
  final socket = await SecureSocket.connect(
    uri.host,
    443,
    supportedProtocols: const ['h2'],
    timeout: const Duration(seconds: 15),
  );
  final connection = ClientTransportConnection.viaSocket(socket);
  try {
    final stream = connection.makeRequest([
      Header.ascii(':method', 'GET'),
      Header.ascii(
        ':path',
        uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path,
      ),
      Header.ascii(':scheme', 'https'),
      Header.ascii(':authority', uri.host),
      for (final MapEntry(:key, :value) in headers.entries)
        Header.ascii(key, value),
    ], endStream: true);
    final response = <String, String>{};
    final body = BytesBuilder(copy: false);
    await for (final message in stream.incomingMessages.timeout(
      const Duration(seconds: 30),
    )) {
      switch (message) {
        case HeadersStreamMessage(:final headers):
          for (final h in headers) {
            response[utf8.decode(h.name)] = utf8.decode(h.value);
          }
        case DataStreamMessage(:final bytes):
          body.add(bytes);
      }
    }
    return (
      int.tryParse(response[':status'] ?? '') ?? 0,
      response,
      body.takeBytes(),
    );
  } finally {
    // terminate, not finish: finish waits forever on a stream abandoned by the timeout.
    await connection.terminate();
  }
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}

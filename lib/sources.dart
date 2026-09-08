import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http2/http2.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'anilist.dart';
import 'metadata.dart';

const userAgent =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36';

/// The top 3 supported anime streaming sites from everythingmoe, fetched once on app start.
Future<List<Source>> sites = topSources();

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
  final info = episodeInfo(media['id']);
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

final _client = http.Client();

Future<http.Response> _get(String url, Map<String, String>? headers) async {
  final uri = Uri.parse(url);
  final res = await _client.get(
    uri,
    headers: {'User-Agent': userAgent, ...?headers},
  );
  if (res.statusCode != 200) {
    throw HttpException('HTTP ${res.statusCode}', uri: uri);
  }
  return res;
}

Future<String> fetch(String url, {Map<String, String>? headers}) async =>
    (await _get(url, headers)).body;

Future<Uint8List> fetchBytes(
  String url, {
  Map<String, String>? headers,
}) async => (await _get(url, headers)).bodyBytes;

/// (name, origin) of the entries in everythingmoe's "Anime Streaming" section, in rank order.
List<(String, String)> parseTopSites(String html) {
  final start = html.indexOf('id="sec-anime"');
  if (start == -1) {
    throw const FormatException(
      'everythingmoe layout changed: no anime section',
    );
  }
  final end = html.indexOf('id="sec-', start + 1);
  final section = html.substring(start, end == -1 ? html.length : end);
  return RegExp(
        r'class="section-item">\d+\.\s*<a href="[^"]*" data-link="([^"]+)"[^>]*>(?:<img[^>]*>)?\s*([^<]+)</a>',
      )
      .allMatches(section)
      .map((m) => (m[2]!.trim(), Uri.parse(m[1]!).origin))
      .toList();
}

Future<List<Source>> topSources() async => [
  for (final (name, origin) in parseTopSites(
    await fetch('https://everythingmoe.com/'),
  ))
    // ponytail: unknown sites are skipped; add an adapter here when the ranking brings in a new one
    ?switch (Uri.parse(origin).host) {
      final h when h.contains('anikoto') => Anikoto(name, origin),
      final h when h.contains('reanime') => ReAnime(name, origin),
      final h when h.contains('miruro') => Miruro(name, origin),
      _ => null,
    },
].take(3).toList();

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

/// megaplay embed -> plain HLS via getSourcesNew (no decryption needed), with every subtitle track.
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
  final sources = json['sources'];
  final file =
      (sources is List ? sources.firstOrNull : sources)?['file'] as String?;
  if (file == null) return [];
  return [
    VideoStream(
      label,
      file,
      {'Referer': '${uri.origin}/', 'User-Agent': userAgent},
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
  }) => megaplay(
    'Megaplay',
    'https://megaplay.buzz/stream/ani/${(episode.ref as String).nullIfEmpty ?? media['id']}'
        '/${epNumber(episode.number)}/${dub ? 'dub' : 'sub'}',
    referer: '$base/',
  );
}

typedef _MiruroConfig = ({
  List<int> pipeKey,
  List<int> proxyKey,
  String proxy,
  String? version,
});

/// Miruro, keyed by AniList id and aggregating several providers. Its API answers only over HTTP/2 ([_h2Get]);
/// HLS plays through Miruro's own stream proxy, mp4 directly with the provider's Referer.
class Miruro extends Source {
  Miruro(super.name, super.base);

  @override
  String get label => '$name (WIP)';

  static const _apiHeaders = {
    'referer': 'https://www.miruro.to/watch',
    'sec-fetch-site': 'same-origin',
    'sec-fetch-mode': 'cors',
    'sec-fetch-dest': 'empty',
  };

  Future<_MiruroConfig>? _config;

  /// Keys and proxy from the site's env2.js, so a key rotation on their side doesn't need an app update.
  Future<_MiruroConfig> get _settings =>
      _config ??= _loadConfig().catchError((Object e, StackTrace stack) {
        _config = null; // retry on the next request
        Error.throwWithStackTrace(e, stack);
      });

  Future<_MiruroConfig> _loadConfig() async {
    final (_, _, env) = await _h2Get(Uri.parse('$base/env2.js'));
    final raw = RegExp(r'JSON\.parse\(("(?:[^"\\]|\\.)*")\)')
        .firstMatch(utf8.decode(env))?[1];
    if (raw == null) {
      throw const FormatException('Miruro changed its config script');
    }
    final values = jsonDecode(jsonDecode(raw) as String) as Map;
    final (_, headers, _) = await _h2Get(
      Uri.parse('$base/api/secure/jwks'),
      _apiHeaders,
    );
    final proxy = '${values['VITE_PROXY_A'] ?? values['VITE_PROXY_B'] ?? ''}';
    return (
      pipeKey: _hex('${values['VITE_PIPE_OBF_KEY'] ?? ''}'),
      proxyKey: _hex('${values['VITE_PROXY_OBF_KEY'] ?? ''}'),
      proxy: proxy.endsWith('/') ? proxy : '$proxy/',
      version: headers['x-protocol-version'],
    );
  }

  Future<dynamic> _pipe(String path, Map<String, Object?> query) async {
    final c = await _settings;
    final envelope = base64Url
        .encode(
          utf8.encode(
            jsonEncode({
              'path': path,
              'method': 'GET',
              'query': query,
              'body': null,
              'version': ?c.version,
            }),
          ),
        )
        .replaceAll('=', '');
    final uri = Uri.parse('$base/api/secure/pipe?e=$envelope');
    final (status, headers, body) = await _h2Get(uri, _apiHeaders);
    if (status != 200) throw HttpException('HTTP $status', uri: uri);
    return decodeMiruroReply(body, headers['x-obfuscated'], c.pipeKey);
  }

  // Miruro is keyed by AniList id, so the picker lists AniList's own results.
  @override
  Future<List<SearchResult>> search(String query) async => [
    for (final m in await AniList.search(query))
      SearchResult(
        '${m['id']}',
        titleOf(m),
        image: m['coverImage']?['large'],
        info: _info([
          m['format'],
          m['seasonYear'],
          if (m['episodes'] != null) '${m['episodes']} eps',
        ]),
      ),
  ];

  @override
  Future<String?> match(Map media) async => '${media['id']}';

  @override
  Future<List<Episode>> episodesOf(String id) async {
    final json = await _pipe('episodes', {'anilistId': int.tryParse(id) ?? id});
    // episode number → sub/dub → provider → that provider's episode id
    final refs = <num, Map<String, Map<String, String>>>{};
    final details = <num, Map>{};
    for (final MapEntry(key: provider, value: p)
        in (json['providers'] as Map? ?? const {}).entries) {
      for (final MapEntry(key: audio, value: list)
          in ((p as Map)['episodes'] as Map? ?? const {}).entries) {
        if (audio != 'sub' && audio != 'dub') continue;
        for (final e in (list as List).cast<Map>()) {
          if (e['number'] is! num || e['id'] is! String) continue;
          final number = e['number'] as num;
          ((refs[number] ??= {})[audio as String] ??= {})[provider as String] =
              e['id'];
          details[number] ??= e;
        }
      }
    }
    return [
      for (final n in refs.keys.toList()..sort())
        Episode(
          n,
          title: details[n]!['title'],
          thumbnail: details[n]!['image'],
          overview: details[n]!['description'],
          ref: refs[n]!,
        ),
    ];
  }

  @override
  Future<List<VideoStream>> streams(
    Map media,
    Episode episode, {
    required bool dub,
  }) async {
    final c = await _settings;
    final category = dub ? 'dub' : 'sub';
    final ids = (episode.ref as Map)[category] as Map? ?? const {};
    final found = await Future.wait([
      for (final MapEntry(key: provider, value: id) in ids.entries)
        _pipe('sources', {
              'episodeId': id,
              'provider': provider,
              'category': category,
              'anilistId': media['id'],
            })
            .then((json) => _parseSources(c, '$provider', json))
            .catchError(
              (Object _) => <VideoStream>[],
            ), // providers are often down
    ]);
    final all = found.expand((s) => s);
    // HLS first: it goes through Miruro's proxy, while direct mp4 links expire more often.
    return [...all.where((s) => s.isHls), ...all.where((s) => !s.isHls)];
  }

  List<VideoStream> _parseSources(
    _MiruroConfig c,
    String provider,
    dynamic json,
  ) {
    final streams = (json['streams'] as List? ?? const []).cast<Map>();
    final referer = '${streams.firstOrNull?['referer'] ?? ''}';
    final subtitles = [
      for (final t in json['subtitles'] as List? ?? const [])
        if (t['file'] is String)
          Subtitle(
            '${t['label'] ?? t['language'] ?? 'Subtitles'}',
            miruroProxyUrl(c.proxy, c.proxyKey, t['file'], referer, 'sub.vtt'),
          ),
    ];
    return [
      for (final s in streams)
        if (s['url'] is String && (s['type'] == 'hls' || s['type'] == 'mp4'))
          VideoStream(
            [
              s['server'] ?? provider,
              s['quality'],
            ].whereType<Object>().join(' '),
            s['type'] == 'hls'
                ? miruroProxyUrl(
                    c.proxy,
                    c.proxyKey,
                    s['url'],
                    '${s['referer'] ?? ''}',
                    'pl.m3u8',
                  )
                : s['url'],
            s['type'] == 'hls'
                ? const {}
                : {'Referer': '${s['referer'] ?? ''}', 'User-Agent': userAgent},
            subtitles: subtitles,
          ),
    ];
  }
}

/// A Miruro pipe reply: base64url, XORed with the pipe key when [obfuscated] is "2", then gzip or zlib JSON.
dynamic decodeMiruroReply(List<int> body, String? obfuscated, List<int> key) {
  if (obfuscated == null) return jsonDecode(utf8.decode(body));
  var bytes = base64Url.decode(base64Url.normalize(ascii.decode(body).trim()));
  if (obfuscated == '2') bytes = _xor(bytes, key);
  return jsonDecode(
    utf8.decode(bytes[0] == 0x1f ? gzip.decode(bytes) : zlib.decode(bytes)),
  );
}

/// [url] through Miruro's stream proxy, which sends [referer] upstream: `<proxy><url>~<referer>/<file>`.
String miruroProxyUrl(
  String proxy,
  List<int> key,
  String url,
  String referer,
  String file,
) {
  String obfuscate(String s) =>
      base64Url.encode(_xor(utf8.encode(s), key)).replaceAll('=', '');
  return '$proxy${obfuscate(url)}${referer.isEmpty ? '' : '~${obfuscate(referer)}'}/$file';
}

Uint8List _xor(List<int> bytes, List<int> key) => Uint8List.fromList([
  for (var i = 0; i < bytes.length; i++)
    key.isEmpty ? bytes[i] : bytes[i] ^ key[i % key.length],
]);

List<int> _hex(String s) => [
  for (var i = 0; i + 1 < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
];

/// One HTTP/2 GET. package:http speaks only HTTP/1.1, which Cloudflare turns away on Miruro's API.
// ponytail: a new connection per request; keep one ClientTransportConnection open if Miruro calls get chatty
Future<(int, Map<String, String>, Uint8List)> _h2Get(
  Uri uri, [
  Map<String, String> extra = const {},
]) async {
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
      Header.ascii('user-agent', userAgent),
      for (final MapEntry(:key, :value) in extra.entries)
        Header.ascii(key, value),
    ], endStream: true);
    final response = <String, String>{};
    final body = <int>[];
    await for (final message in stream.incomingMessages.timeout(
      const Duration(seconds: 30),
    )) {
      switch (message) {
        case HeadersStreamMessage(:final headers):
          for (final h in headers) {
            response[utf8.decode(h.name)] = utf8.decode(h.value);
          }
        case DataStreamMessage(:final bytes):
          body.addAll(bytes);
      }
    }
    return (
      int.tryParse(response[':status'] ?? '') ?? 0,
      response,
      Uint8List.fromList(body),
    );
  } finally {
    // terminate, not finish: finish waits forever on a stream abandoned by the timeout.
    await connection.terminate();
  }
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}

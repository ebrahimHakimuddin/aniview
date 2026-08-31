import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'cloudflare.dart';
import 'metadata.dart';

const userAgent =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36';

/// Top 3 anime streaming sites from everythingmoe, fetched once on app start.
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

/// (name, origin) of the first three entries in everythingmoe's "Anime Streaming" section.
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
      .take(3)
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
      final h when h.contains('animepahe') => AnimePahe(name, origin),
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

/// animepahe and its kwik player sit behind Cloudflare, which rejects Dart's HTTP client even with a clearance
/// cookie, so every request goes through the in-app browser ([browserFetch]).
class AnimePahe extends Source {
  AnimePahe(super.name, super.base);

  Future<dynamic> _api(String query) async =>
      jsonDecode(await browserFetch('$base/api?$query', text: true));

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
        if (links.hasMatch(await browserFetch('$base/anime/${result.id}'))) {
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
    final play = await browserFetch(
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
          final html = await browserFetch('$kwik', referer: '$base/');
          final m3u8 = RegExp(r'''https?://[^'"\\\s]+\.m3u8[^'"\\\s]*''')
              .firstMatch(unpack(html))?[0];
          if (m3u8 == null) return null;
          return VideoStream(
            '${button['fansub'] ?? 'Kwik'} ${button['resolution']}p',
            m3u8,
            {'Referer': '${kwik.origin}/', 'User-Agent': userAgent},
          );
        } on CloudflareChallenge {
          rethrow;
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

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}

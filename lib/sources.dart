import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const userAgent =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36';

/// Per-host cookie + matching User-Agent captured after the user clears a Cloudflare challenge.
final cfHeaders = <String, Map<String, String>>{};

/// Top 3 anime streaming sites from everythingmoe, fetched once on app start.
Future<List<Source>> sites = topSources();

class CloudflareChallenge implements Exception {
  CloudflareChallenge(this.url);
  final String url;
  @override
  String toString() => 'Cloudflare verification required for ${Uri.parse(url).host}';
}

class Episode {
  const Episode(this.number, {this.title, this.thumbnail, required this.ref});
  final num number;
  final String? title, thumbnail;
  final Object ref; // site-specific handle used to resolve streams
}

class VideoStream {
  const VideoStream(this.label, this.url, this.headers, {this.subtitle, this.intro});
  final String label, url;
  final Map<String, String> headers;
  final String? subtitle;
  final (int start, int end)? intro; // seconds
}

abstract class Source {
  Source(this.name, this.base);
  final String name, base;
  Future<List<Episode>> episodes(Map media);
  Future<List<VideoStream>> streams(Map media, Episode episode, {required bool dub});
}

String epNumber(num n) => n % 1 == 0 ? '${n.toInt()}' : '$n';

final _client = http.Client();

Future<String> fetch(String url, {Map<String, String>? headers}) async {
  final uri = Uri.parse(url);
  final res = await _client.get(uri, headers: {'User-Agent': userAgent, ...?cfHeaders[uri.host], ...?headers});
  // Managed challenges set cf-mitigated; bot-score blocks only show Cloudflare's "Attention Required" page.
  if ((res.statusCode == 403 || res.statusCode == 503) && res.headers['server'] == 'cloudflare') {
    throw CloudflareChallenge(url);
  }
  if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: uri);
  return res.body;
}

/// (name, origin) of the first three entries in everythingmoe's "Anime Streaming" section.
List<(String, String)> parseTopSites(String html) {
  final start = html.indexOf('id="sec-anime"');
  if (start == -1) throw const FormatException('everythingmoe layout changed: no anime section');
  final end = html.indexOf('id="sec-', start + 1);
  final section = html.substring(start, end == -1 ? html.length : end);
  return RegExp(r'class="section-item">\d+\.\s*<a href="[^"]*" data-link="([^"]+)"[^>]*>(?:<img[^>]*>)?\s*([^<]+)</a>')
      .allMatches(section)
      .take(3)
      .map((m) => (m[2]!.trim(), Uri.parse(m[1]!).origin))
      .toList();
}

Future<List<Source>> topSources() async => [
      for (final (name, origin) in parseTopSites(await fetch('https://everythingmoe.com/')))
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

Map<String, String> _dataAttrs(String tag) =>
    {for (final m in RegExp(r'data-([\w-]+)="([^"]*)"').allMatches(tag)) m[1]!: m[2]!};

/// megaplay embed -> plain HLS via getSourcesNew (no decryption needed).
Future<List<VideoStream>> megaplay(String label, String embed, {required String referer}) async {
  final page = await fetch(embed, headers: {'Referer': referer});
  final id = RegExp(r'data-id="(\d+)"').firstMatch(page)?[1];
  if (id == null) return [];
  final uri = Uri.parse(embed);
  final server = uri.queryParameters['s'];
  final json = jsonDecode(await fetch(
    '${uri.origin}/stream/getSourcesNew?id=$id${server == null ? '' : '&s=$server'}',
    headers: {'X-Requested-With': 'XMLHttpRequest', 'Referer': embed},
  ));
  final sources = json['sources'];
  final file = (sources is List ? sources.firstOrNull : sources)?['file'] as String?;
  if (file == null) return [];
  final subtitle = (json['tracks'] as List? ?? []).where((t) => t['kind'] == 'captions').firstOrNull?['file'];
  final intro = json['intro'];
  return [
    VideoStream(
      label,
      file,
      {'Referer': '${uri.origin}/', 'User-Agent': userAgent},
      subtitle: subtitle,
      intro: intro == null || intro['end'] == 0 ? null : ((intro['start'] as num).toInt(), (intro['end'] as num).toInt()),
    ),
  ];
}

class Anikoto extends Source {
  Anikoto(super.name, super.base);

  Map<String, String> get _ajax => {'X-Requested-With': 'XMLHttpRequest', 'Referer': '$base/'};

  @override
  Future<List<Episode>> episodes(Map media) async {
    for (final title in _searchTitles(media)) {
      final search = await fetch('$base/filter?keyword=${Uri.encodeQueryComponent(title)}');
      final candidates = RegExp(r'<a class="name d-title" href="([^"]+)"').allMatches(search).take(5);
      for (final candidate in candidates) {
        final page = await fetch(candidate[1]!);
        final id = RegExp(r'id="watch-main"[^>]*?data-id="(\d+)"').firstMatch(page)?[1];
        if (id == null) continue;
        final html = jsonDecode(await fetch('$base/ajax/episode/list/$id', headers: _ajax))['result'] as String;
        final attrs = RegExp(r'<a [^>]*data-num="[^>]*>').allMatches(html).map((m) => _dataAttrs(m[0]!)).toList();
        // Each episode carries its MAL id, so we only accept the right show.
        if (attrs.isEmpty || (media['idMal'] != null && attrs.first['mal'] != '${media['idMal']}')) continue;
        return [for (final a in attrs) Episode(num.tryParse(a['num'] ?? '') ?? 0, ref: a)];
      }
    }
    return [];
  }

  @override
  Future<List<VideoStream>> streams(Map media, Episode episode, {required bool dub}) async {
    final ids = (episode.ref as Map)['ids'];
    final html = jsonDecode(await fetch('$base/ajax/server/list?servers=$ids', headers: _ajax))['result'] as String;
    final block = RegExp('data-type="${dub ? 'dub' : 'sub'}">(.*?)</ul>', dotAll: true).firstMatch(html)?[1] ?? '';
    final servers = RegExp(r'data-link-id="([^"]+)"[^>]*>([^<]+)<').allMatches(block);
    final resolved = await Future.wait(servers.map((server) async {
      try {
        final result = jsonDecode(await fetch('$base/ajax/server?get=${server[1]}', headers: _ajax))['result'];
        final url = result['url'] as String;
        // ponytail: only megaplay embeds are resolved; other hosts are skipped until an extractor is added
        return url.contains('megaplay') ? await megaplay(server[2]!.trim(), url, referer: '$base/') : <VideoStream>[];
      } catch (_) {
        return <VideoStream>[];
      }
    }));
    return resolved.expand((s) => s).toList();
  }
}

class ReAnime extends Source {
  ReAnime(super.name, super.base);

  @override
  Future<List<Episode>> episodes(Map media) async {
    for (final title in _searchTitles(media)) {
      final search = jsonDecode(await fetch('$base/api/v1/search?limit=10&q=${Uri.encodeQueryComponent(title)}'));
      final hit = (search['results'] as List? ?? []).where((r) => r['anilist_id'] == media['id']).firstOrNull;
      if (hit == null) continue;
      final data = jsonDecode(await fetch('$base/api/v1/anime/${hit['anime_id']}/episodes?limit=5000'))['data'] as List;
      return [
        for (final e in data)
          Episode(
            e['episode_number'],
            title: (e['title'] as String?)?.nullIfEmpty,
            thumbnail: (e['thumbnail'] as String?)?.nullIfEmpty,
            ref: e,
          ),
      ];
    }
    return [];
  }

  // Re:ANIME's own flixcloud servers ship encrypted payloads; megaplay serves the same episode by AniList id.
  @override
  Future<List<VideoStream>> streams(Map media, Episode episode, {required bool dub}) => megaplay(
        'Megaplay',
        'https://megaplay.buzz/stream/ani/${media['id']}/${epNumber(episode.number)}/${dub ? 'dub' : 'sub'}',
        referer: '$base/',
      );
}

/// Sits behind Cloudflare: [fetch] throws [CloudflareChallenge] until the user clears it once.
class AnimePahe extends Source {
  AnimePahe(super.name, super.base);

  @override
  Future<List<Episode>> episodes(Map media) async {
    String? session;
    search:
    for (final title in _searchTitles(media)) {
      final results = jsonDecode(await fetch('$base/api?m=search&q=${Uri.encodeQueryComponent(title)}'))['data'];
      for (final result in (results as List? ?? []).take(3)) {
        final page = await fetch('$base/anime/${result['session']}');
        if (RegExp('anilist\\.co/anime/${media['id']}\\b').hasMatch(page)) {
          session = result['session'];
          break search;
        }
      }
    }
    if (session == null) return [];

    final raw = <Map>[];
    for (var page = 1, last = 1; page <= last; page++) {
      final json = jsonDecode(await fetch('$base/api?m=release&id=$session&sort=episode_asc&page=$page'));
      last = json['last_page'] ?? 1;
      raw.addAll((json['data'] as List? ?? []).cast<Map>());
    }
    if (raw.isEmpty) return [];
    // animepahe keeps counting across seasons (S2 starts at 13); renumber from 1.
    final offset = ((raw.first['episode'] as num) - 1).clamp(0, double.infinity);
    return [
      for (final e in raw)
        Episode((e['episode'] as num) - offset, thumbnail: e['snapshot'], ref: '$session/${e['session']}'),
    ];
  }

  @override
  Future<List<VideoStream>> streams(Map media, Episode episode, {required bool dub}) async {
    final play = await fetch('$base/play/${episode.ref}', headers: {'Referer': '$base/'});
    final buttons = RegExp(r'<button[^>]*data-src="[^"]*"[^>]*>')
        .allMatches(play)
        .map((m) => _dataAttrs(m[0]!))
        .where((b) => (b['audio'] == 'eng') == dub)
        .toList()
      ..sort((a, b) => (int.tryParse(b['resolution'] ?? '') ?? 0).compareTo(int.tryParse(a['resolution'] ?? '') ?? 0));
    final out = <VideoStream>[];
    for (final button in buttons) {
      final kwik = Uri.parse(button['src']!);
      final html = await fetch('$kwik', headers: {'Referer': '$base/'});
      final m3u8 = RegExp(r'''https?://[^'"\\\s]+\.m3u8[^'"\\\s]*''').firstMatch(unpack(html))?[0];
      if (m3u8 == null) continue;
      out.add(VideoStream(
        '${button['fansub'] ?? 'Kwik'} ${button['resolution']}p',
        m3u8,
        {'Referer': '${kwik.origin}/', 'User-Agent': cfHeaders[kwik.host]?['User-Agent'] ?? userAgent},
      ));
    }
    return out;
  }
}

/// Expands Dean Edwards' p.a.c.k.e.r `eval(function(p,a,c,k,e,d){...}('...',a,c,'...'.split('|')))` scripts.
String unpack(String js) {
  final m = RegExp(r"\}\('(.*)',\s*(\d+),\s*(\d+),\s*'(.*?)'\.split\('\|'\)", dotAll: true).firstMatch(js);
  if (m == null) return js;
  final radix = int.parse(m[2]!), count = int.parse(m[3]!), words = m[4]!.split('|');
  String encode(int n) =>
      (n < radix ? '' : encode(n ~/ radix)) +
      (n % radix > 35 ? String.fromCharCode(n % radix + 29) : (n % radix).toRadixString(36));
  final dict = {
    for (var i = 0; i < count; i++) encode(i): i < words.length && words[i].isNotEmpty ? words[i] : encode(i),
  };
  return m[1]!.replaceAll(r"\'", "'").replaceAllMapped(RegExp(r'\b\w+\b'), (w) => dict[w[0]] ?? w[0]!);
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}

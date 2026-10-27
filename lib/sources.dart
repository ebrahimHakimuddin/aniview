import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloudflare.dart';
import 'jellyfin.dart';
import 'metadata.dart';
import 'net.dart';
import 'platform.dart';
import 'settings.dart';

export 'net.dart';

/// Built-in sites in preferred order (see [topSources]), loaded once and loaded
/// afresh on the next ask after a failed load.
class Sites {
  static Future<List<Source>>? _current;

  /// Where the list comes from; replaced in tests.
  @visibleForTesting
  static Future<List<Source>> Function() load = topSources;

  /// The same future until a load fails, so a FutureBuilder can hold on to it. Installed extensions come after
  /// the top sites.
  static Future<List<Source>> all() => _current ??=
      Future(() async {
        // Extensions load beside the top sites, and never hold them up or take them down: one that fails or stalls is
        // left out of this answer, and asked for again on the next [all].
        final extensions = _extensionSources();
        final sites = await load();
        final (installed, loaded) = await extensions;
        if (!loaded) _current = null;
        // The user's own server first: what's there is theirs to watch.
        return [?Jellyfin.saved(), ...sites, ...installed];
      }).catchError((Object e) {
        _current = null;
        throw e;
      });

  /// How long the installed extensions get; replaced in tests.
  @visibleForTesting
  static Duration extensionsPatience = const Duration(seconds: 15);

  static Future<(List<Source>, bool)> _extensionSources() async {
    try {
      return (
        await ExtensionSource.installed().timeout(extensionsPatience),
        true,
      );
    } catch (_) {
      return (<Source>[], false);
    }
  }

  /// Picks up extensions installed or removed since the list was loaded.
  static void reload() => _current = null;

  /// The site saved under [name] (history, downloads), if it's still among the top sites.
  static Future<Source?> named(String name) async =>
      (await all()).where((s) => s.name == name).firstOrNull;

  /// The last site selected, else the highest ranked when it is no longer available.
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
    this.audios = const [],
    this.skips = const [],
    this._hls = false,
    this.key,
    this.audioLanguage,
  });
  final String label, url;
  final Map<String, String> headers;
  final List<Subtitle> subtitles; // soft subs, picked in the player
  final List<Subtitle> audios; // audio as files of their own (label and url, like a subtitle), picked in the player
  final List<SkipTime> skips; // intro/outro times the site itself provides
  final bool _hls; // a playlist whose address doesn't end in .m3u8

  /// The AES-128 key the segments open with, when the site's own player works it out rather than fetching it.
  final Uint8List? key;

  /// Preferred HLS audio rendition, when a multilingual master has the wrong default.
  final String? audioLanguage;

  /// The same stream, known to be an HLS playlist though its address doesn't say.
  VideoStream get asPlaylist => VideoStream(
    label,
    url,
    headers,
    subtitles: subtitles,
    audios: audios,
    skips: skips,
    hls: true,
    key: key,
    audioLanguage: audioLanguage,
  );

  bool get isLocal => !url.startsWith('http'); // a downloaded episode on disk
  bool get isHls => _hls || Uri.parse(url).path.endsWith('.m3u8');
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
  final episodes = seasonNumbered(await source.episodesOf(id), media);
  final art = await info;
  return [for (final e in episodes) e.withInfo(art[epNumber(e.number)])];
}

/// [episodes] numbered from 1 when the site keeps counting across seasons (a season 2 of 12 listed as 26–37), so
/// progress, skip times and artwork go by the season's own numbers. A list that only lacks its first few episodes
/// stays as it is.
List<Episode> seasonNumbered(List<Episode> episodes, Map media) {
  final total =
      media['episodes'] as int? ??
      media['nextAiringEpisode']?['episode'] as int?;
  if (episodes.isEmpty || total == null) return episodes;
  final first = episodes.map((e) => e.number).reduce(min);
  final last = episodes.map((e) => e.number).reduce(max);
  if (first <= 1 || last <= total) return episodes;
  return [
    for (final e in episodes)
      Episode(
        e.number - (first.ceil() - 1),
        title: e.title,
        thumbnail: e.thumbnail,
        overview: e.overview,
        ref: e.ref,
      ),
  ];
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

/// Supported ranked sites, followed by AnimeStream when absent from the ranking.
/// animepahe remains available for saved episodes and manual use, marked unstable.
Future<List<Source>> topSources() async => sourcesFromRanking(_topSites);

@visibleForTesting
List<Source> sourcesFromRanking(Iterable<String> ranking) {
  final sites = <Source>[
    for (final [name, origin] in ranking.map((s) => s.split('|')))
      ?switch (Uri.parse(origin).host) {
        final h when h.contains('anikoto') => Anikoto(name, origin),
        final h when h.contains('animepahe') => AnimePahe(name, origin),
        'ani.pm' => AniPm(name, origin),
        'kaa.lt' || 'kaa.to' => KickAssAnime(name, 'https://kaa.lt'),
        final h when h.contains('uniquestream') => AnimeStream(name, origin),
        _ => null,
      },
  ];
  if (!sites.any((source) => source is AnimeStream)) {
    sites.add(AnimeStream('AnimeStream', 'https://anime.uniquestream.net'));
  }
  return [
    ...sites.where((source) => source is! AnimePahe),
    ...sites.whereType<AnimePahe>(),
  ];
}

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
  Net net = const HttpNet(),
}) async {
  final page = await net.text(embed, headers: {'Referer': referer});
  final id = RegExp(r'data-id="(\d+)"').firstMatch(page)?[1];
  if (id == null) return [];
  final uri = Uri.parse(embed);
  final server = uri.queryParameters['s'];
  final json = jsonDecode(
    await net.text(
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
    await net.text(file, headers: headers);
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

/// KickAssAnime's catalogue and current VidStreaming (Astro) player.
class KickAssAnime extends Source {
  KickAssAnime(super.name, super.base, {this.net = const HttpNet()});

  final Net net;
  Map<String, String> get _headers => {
    'Referer': '$base/',
    'User-Agent': userAgent,
  };

  Future<List<dynamic>> _search(String query) async {
    return jsonDecode(
      await postJson('$base/api/search', {'query': query}, headers: _headers),
    ) as List;
  }

  @override
  Future<List<SearchResult>> search(String query) async => [
    for (final item in await _search(query))
      SearchResult(
        item['slug'],
        item['title_en'] ?? item['title'],
        info: _info([item['year'], item['type']]),
      ),
  ];

  @override
  Future<String?> match(Map media) async {
    String key(String title) =>
        title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final titles = _searchTitles(media).toList();
    final keys = titles.map(key).toSet();
    for (final title in titles) {
      final matches = (await _search(title)).where(
        (item) => [
          item['title'],
          item['title_en'],
        ].whereType<String>().any((t) => keys.contains(key(t))),
      );
      // Never guess between remakes or seasons sharing a title.
      if (matches.length == 1) return matches.single['slug'] as String;
    }
    return null;
  }

  Future<List<Episode>> _episodes(String id, String language) async {
    Future<Map> page(int number) async => jsonDecode(
      await net.text(
        '$base/api/show/$id/episodes?lang=$language&page=$number',
        headers: _headers,
      ),
    ) as Map;
    final first = await page(1);
    final rows = <dynamic>[...?first['result']];
    for (final p in first['pages'] as List? ?? []) {
      if (p['number'] != 1) {
        rows.addAll((await page(p['number']))['result'] as List);
      }
    }
    return [
      for (final row in rows)
        Episode(
          row['episode_number'],
          ref: {
            'show': id,
            'episode': 'ep-${row['episode_string']}-${row['slug']}',
            'language': language,
            'number': row['episode_number'],
          },
        ),
    ]..sort((a, b) => a.number.compareTo(b.number));
  }

  @override
  Future<List<Episode>> episodesOf(String id) => _episodes(id, 'ja-JP');

  @override
  Future<List<VideoStream>> streams(
    Map media,
    Episode episode, {
    required bool dub,
  }) async {
    var ref = episode.ref as Map;
    final language = dub ? 'en-US' : 'ja-JP';
    if (ref['language'] != language) {
      final translated = (await _episodes(
        ref['show'],
        language,
      )).where((e) => (e.ref as Map)['number'] == ref['number']).firstOrNull;
      if (translated == null) return [];
      ref = translated.ref as Map;
    }
    final detail = jsonDecode(
      await net.text(
        '$base/api/show/${ref['show']}/episode/${ref['episode']}',
        headers: _headers,
      ),
    );
    if (detail['language'] != language) return [];
    final streams = <VideoStream>[];
    for (final server in detail['servers'] as List? ?? []) {
      try {
        final embed = Uri.parse(base).resolve(server['src'] as String);
        final html = await net.text('$embed', headers: _headers);
        for (final island in RegExp(
          r'<astro-island\b[^>]*>',
        ).allMatches(html)) {
          final props = RegExp(r'props="([^"]*)"').firstMatch(island[0]!);
          if (props == null) continue;
          final data = _astroObject(jsonDecode(_decodeHtml(props[1]!)) as Map);
          if (data['manifest'] case final String manifest) {
            final url = embed.resolve(manifest);
            if (url.scheme != 'https' && url.scheme != 'http') continue;
            streams.add(
              VideoStream(
                server['name'] as String? ?? 'VidStreaming',
                '$url',
                {
                  'Referer': '${embed.origin}/',
                  'Origin': embed.origin,
                  'User-Agent': userAgent,
                },
                subtitles: [
                  for (final sub in data['subtitles'] as List? ?? [])
                    if (sub is Map && sub['src'] is String)
                      Subtitle(
                        sub['name'] as String? ??
                            sub['language'] as String? ??
                            'Subtitle',
                        '${embed.resolve(sub['src'])}',
                      ),
                ],
                hls: true,
                audioLanguage: dub ? 'eng' : 'jpn',
              ),
            );
          }
        }
      } on HttpException {
        // Another server can still work.
      } on FormatException {
        // Older/unsupported player pages are not playable sources.
      }
    }
    return streams;
  }

  static Map<String, dynamic> _astroObject(Map value) => {
    for (final entry in value.entries)
      entry.key as String: _astroValue(entry.value),
  };

  static dynamic _astroValue(dynamic value) {
    if (value is! List || value.isEmpty) return null;
    final payload = value.length > 1 ? value[1] : null;
    return switch (value.first) {
      0 => payload is Map ? _astroObject(payload) : payload,
      1 => (payload as List).map(_astroValue).toList(),
      _ => null,
    };
  }
}

class Anikoto extends Source {
  Anikoto(super.name, super.base, {this.net = const HttpNet()});

  final Net net;
  final _episodes = <String, List<Episode>>{};

  Map<String, String> get _ajax => {
    'X-Requested-With': 'XMLHttpRequest',
    'Referer': '$base/',
  };

  @override
  Future<List<SearchResult>> search(String query) async {
    final html = await net.text(
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
    final page = await net.text(id);
    final showId = RegExp(r'id="watch-main"[^>]*?data-id="(\d+)"')
        .firstMatch(page)?[1];
    if (showId == null) return [];
    final html =
        jsonDecode(
              await net.text('$base/ajax/episode/list/$showId', headers: _ajax),
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
              await net.text(
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
            await net.text(
              '$base/ajax/server?get=${server[1]}',
              headers: _ajax,
            ),
          )['result'];
          final url = result['url'] as String;
          // ponytail: only megaplay embeds are resolved; other hosts are skipped until an extractor is added
          return url.contains('megaplay')
              ? await megaplay(
                  server[2]!.trim(),
                  url,
                  referer: '$base/',
                  net: net,
                )
              : <VideoStream>[];
        } catch (_) {
          return <VideoStream>[];
        }
      }),
    );
    return resolved.expand((s) => s).toList();
  }
}

/// ani.pm lists shows with their AniList and MAL ids; an episode plays through a settlar.io embed session, whose HLS
/// address doesn't end in .m3u8 and carries the subtitles as renditions.
class AniPm extends Source {
  AniPm(super.name, super.base, {this.net = const HttpNet()});

  final Net net;

  @override
  Future<List<SearchResult>> search(String query) async {
    final json = jsonDecode(
      await net.text(
        '$base/api/anime/search?q=${Uri.encodeQueryComponent(query)}',
      ),
    );
    return [
      for (final r in json['items'] as List? ?? const [])
        // The id keeps the site and both trackers' ids, so match can check them without another call.
        SearchResult(
          '${r['source']}/${r['routeId']}|${r['anilistId'] ?? ''}|${r['malId'] ?? ''}',
          '${r['title']}',
          image: r['poster'] == null ? null : '$base${r['poster']}',
          info: _info([
            r['type'],
            r['year'],
            if (r['episodeCount'] != null) '${r['episodeCount']} eps',
          ]),
        ),
    ];
  }

  @override
  Future<String?> match(Map media) async {
    for (final title in _searchTitles(media)) {
      for (final r in await search(title)) {
        final [_, anilist, mal] = r.id.split('|');
        if (anilist == '${media['id']}' ||
            (media['idMal'] != null && mal == '${media['idMal']}')) {
          return r.id;
        }
      }
    }
    return null;
  }

  @override
  Future<List<Episode>> episodesOf(String id) async {
    final show = id.split('|').first;
    final json = jsonDecode(
      await net.text('$base/api/anime/series/${show.split('-').last}'),
    );
    return [
      for (final e in json['episodes'] as List? ?? const [])
        Episode(
          e['number'] as num,
          title: (e['title'] as String?)?.nullIfEmpty,
          thumbnail: e['thumbnail'] == null ? null : '$base${e['thumbnail']}',
          ref: show,
        ),
    ];
  }

  @override
  Future<List<VideoStream>> streams(
    Map media,
    Episode episode, {
    required bool dub,
  }) async {
    final lang = dub ? 'dub' : 'sub', number = epNumber(episode.number);
    final boot = jsonDecode(
      await net.text(
        '$base/api/anime/playback-bootstrap/${episode.ref}?ep=$number&lang=$lang&core=0',
      ),
    );
    // Asked for the dub of an episode only subbed, it answers the sub.
    if (boot['effectiveLanguage'] != lang || boot['settlarSelection'] == null) {
      return [];
    }
    final preview = jsonDecode(
      await net.text(
        '$base/api/anime/settlar/preview-session?selection=${Uri.encodeQueryComponent(boot['settlarSelection'])}'
        '&provider=anipm&ep=$number&channel=$lang&telemetry=0',
      ),
    );
    final embed = Uri.parse(preview['embedUrl'] as String);
    final session = jsonDecode(
      await net.text(
        '${embed.origin}/api/embed/session?t=${Uri.encodeQueryComponent(embed.queryParameters['t']!)}',
      ),
    );
    if (session['source'] is! String) return [];
    Duration at(Object? s) =>
        Duration(milliseconds: ((s as num) * 1000).round());
    return [
      VideoStream(
        'Settlar',
        session['source'],
        {'User-Agent': userAgent},
        hls: session['kind'] == 'hls',
        skips: [
          for (final (key, type) in [
            ('op', SkipType.intro),
            ('ed', SkipType.outro),
          ])
            if (boot['skip']?[key] case {'start': num s, 'end': num e})
              SkipTime(type, at(s), at(e)),
        ],
      ),
    ];
  }
}

/// Names for AnimeStream's subtitle locales, starting with the language as the subtitle setting picks by.
const _languages = {
  'en-US': 'English',
  'es-419': 'Spanish (Latin America)',
  'es-ES': 'Spanish (Spain)',
  'pt-BR': 'Portuguese (Brazil)',
  'fr-FR': 'French',
  'de-DE': 'German',
  'it-IT': 'Italian',
  'ar-SA': 'Arabic',
  'ru-RU': 'Russian',
  'zh-CN': 'Chinese (Simplified)',
  'zh-HK': 'Chinese (Traditional)',
  'th-TH': 'Thai',
  'id-ID': 'Indonesian',
  'ms-MY': 'Malay',
  'vi-VN': 'Vietnamese',
  'pl-PL': 'Polish',
  'hi-IN': 'Hindi',
  'ta-IN': 'Tamil',
  'te-IN': 'Telugu',
};

/// AnimeStream (uniquestream) keeps a show's seasons in one series; a season is picked by its MAL id where the site
/// has one, else season 1 for a series of the same title. Its CDN wants the site as Referer, and the key its playlists
/// name is wrapped for its own player: the real one is the media id.
class AnimeStream extends Source {
  AnimeStream(super.name, super.base, {this.net = const HttpNet()});

  final Net net;

  Future<Uint8List?> _playlistKey(String playlist, String mediaId) async {
    final headers = {'Referer': '$base/', 'User-Agent': userAgent};
    var uri = Uri.parse(playlist);
    for (var depth = 0; depth < 4; depth++) {
      final body = await net.text('$uri', headers: headers);
      final key = RegExp(r'#EXT-X-KEY:.*URI="([^"]+)"').firstMatch(body);
      if (key != null) {
        final keyUri = uri.resolve(key[1]!);
        if (!keyUri.path.endsWith('/key.bin')) return null;
        final wrapped = await net.text(
          '$keyUri',
          headers: {...headers, 'x-am-media-id': mediaId},
        );
        // The site's player unwraps key.bin using SHA-256-derived AES key/IV.
        Uint8List digest(String prefix) => SHA256Digest()
            .process(Uint8List.fromList(utf8.encode('$prefix$mediaId')))
            .sublist(0, 16);
        final cipher =
            PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
              ..init(
                false,
                PaddedBlockCipherParameters(
                  ParametersWithIV(KeyParameter(digest('key')), digest('iv')),
                  null,
                ),
              );
        final result = cipher.process(base64.decode(wrapped.trim()));
        if (result.length != 16) {
          throw const FormatException('Invalid AnimeStream HLS key length');
        }
        return result;
      }
      final variant = RegExp(r'#EXT-X-STREAM-INF:[^\r\n]*[\r\n]+([^\r\n]+)')
          .firstMatch(body);
      if (variant == null) return null;
      uri = uri.resolve(variant[1]!.trim());
    }
    throw const FormatException('AnimeStream playlist nesting exceeds limit');
  }

  Future<dynamic> _api(String path) async =>
      jsonDecode(await net.text('$base/api/v1/$path'));

  @override
  Future<List<SearchResult>> search(String query) async => [
    for (final r
        in (await _api(
                  'search?query=${Uri.encodeQueryComponent(query)}',
                ))['series']
                as List? ??
            const [])
      SearchResult(
        '${r['content_id']}',
        '${r['title']}',
        image: r['image'],
        info: _info([
          if (r['subbed'] == true) 'Sub',
          if (r['dubbed'] == true) 'Dub',
        ]),
      ),
  ];

  @override
  Future<String?> match(Map media) async {
    final titles = {for (final t in _searchTitles(media)) t.toLowerCase()};
    // Its search knows a series by the first season's title; "… 2nd Season" finds nothing.
    final suffix = RegExp(
      r'[\s:]*(\d+(st|nd|rd|th) Season|Season \d+|Part \d+)$',
      caseSensitive: false,
    );
    for (final title in {
      for (final t in _searchTitles(media)) ...[t, t.replaceFirst(suffix, '')],
    }) {
      for (final r in (await search(title)).take(3)) {
        final seasons =
            (await _api('series/${r.id}'))['seasons'] as List? ?? const [];
        // ponytail: a later season the site has no MAL id for is only found by a manual pick
        final season =
            seasons
                .where(
                  (s) =>
                      media['idMal'] != null &&
                      s['mal_id'] == '${media['idMal']}',
                )
                .firstOrNull ??
            (titles.contains(r.title.toLowerCase())
                ? seasons.where((s) => s['season_number'] == 1).firstOrNull
                : null);
        if (season != null) return '${r.id}/${season['content_id']}';
      }
    }
    return null;
  }

  @override
  Future<List<Episode>> episodesOf(String id) async {
    // A manual pick is the series alone: its first season.
    final season = id.contains('/')
        ? id.split('/').last
        : ((await _api('series/$id'))['seasons'] as List).first['content_id'];
    final episodes = [];
    for (var page = 1; ; page++) {
      final list = await _api(
        'season/$season/episodes?page=$page&limit=20&order_by=asc',
      ) as List;
      episodes.addAll(list);
      if (list.length < 20) break; // its most per page
    }
    return [
      for (final e in episodes)
        if (e['is_clip'] != true)
          Episode(
            e['episode_number'] as num,
            title: (e['title'] as String?)?.nullIfEmpty,
            thumbnail: e['image'],
            ref: e['content_id'],
          ),
    ];
  }

  @override
  Future<List<VideoStream>> streams(
    Map media,
    Episode episode, {
    required bool dub,
  }) async {
    final locale = dub ? 'en-US' : 'ja-JP';
    final play = await _api('episode/${episode.ref}/media/dash/$locale');
    final hls = play['hls'];
    // Without the audio asked for, it answers another one.
    if (hls?['locale'] != locale ||
        hls['playlist'] is! String ||
        play['media_id'] is! String) {
      return [];
    }
    final id = play['media_id'] as String;
    return [
      VideoStream(
        'AnimeStream',
        hls['playlist'],
        {'Referer': '$base/', 'User-Agent': userAgent},
        key: await _playlistKey(hls['playlist'], id),
        subtitles: [
          for (final s in hls['subtitles'] as List? ?? const [])
            Subtitle(_languages[s['language']] ?? '${s['language']}', s['url']),
        ],
      ),
    ];
  }
}

/// animepahe sits behind a Cloudflare JavaScript challenge: the in-app browser clears it once and the clearance is
/// reused over HTTP/2 ([cleared]). Its kwik player and CDN only refuse HTTP/1.1, which [net] handles.
class AnimePahe extends Source {
  AnimePahe(super.name, super.base, {Net? cleared, this.net = const HttpNet()})
    : cleared = cleared ?? CloudflareNet();

  final Net cleared, net;

  @override
  String get label => '$name · Unstable';

  Future<dynamic> _api(String query) async =>
      jsonDecode(await cleared.text('$base/api?$query'));

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
        if (links.hasMatch(await cleared.text('$base/anime/${result.id}'))) {
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
    final play = await cleared.text(
      '$base/play/${episode.ref}',
      headers: {'Referer': '$base/'},
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
          final html = await net.text('$kwik', headers: {'Referer': '$base/'});
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

/// An installed extension's source as the Android side lists it.
typedef HostSource = ({
  String id,
  String pkg,
  String version,
  String name,
  String lang,
  String baseUrl,
});

/// The installed Aniyomi extensions, run by the Android side (Extensions.kt). A site's Cloudflare check the extension
/// couldn't pass itself is a [CloudflareChallenge]; other failures are a [PlatformException] with the reason. Listing
/// calls answer nothing off Android.
abstract class ExtensionHost {
  /// What the app uses; replaced in tests.
  static ExtensionHost current = const ChannelExtensionHost();

  /// Every source of every installed extension (an extension can add several).
  Future<List<HostSource>> sources();

  Future<List<SearchResult>> search(String id, String query);

  /// As the extension lists them (usually newest first), with the numbers it states: -1 when it states none.
  Future<List<Episode>> episodes(String id, String url);

  /// The streams of an episode this host listed.
  Future<List<VideoStream>> videos(String id, Episode episode);

  /// Hands the APK at [path] to Android, which only loads it if it's signed with [fingerprint].
  Future<void> install(String path, String fingerprint);

  Future<void> uninstall(String pkg);
}

/// [ExtensionHost] over the platform channel.
class ChannelExtensionHost implements ExtensionHost {
  /// [android] is whether the Android side is there; [Platform.isAndroid] unless a test says otherwise.
  const ChannelExtensionHost({this.android});

  final bool? android;

  Future<Object?> _call(String method, [Map<String, String>? args]) async {
    try {
      return await AndroidApp.extensions(method, args);
    } on PlatformException catch (e) {
      // The site's Cloudflare check the extension couldn't pass itself: the app's verification page can.
      if (e.code != 'cloudflare') rethrow;
      throw CloudflareChallenge(e.details as String);
    }
  }

  Future<List> _list(String method, [Map<String, String>? args]) async =>
      (android ?? Platform.isAndroid) ? await _call(method, args) as List : [];

  @override
  Future<List<HostSource>> sources() async => [
    for (final s in await _list('list'))
      (
        id: s['id'],
        pkg: s['pkg'],
        version: s['version'],
        name: s['name'],
        lang: s['lang'] ?? '',
        baseUrl: s['baseUrl'] ?? '',
      ),
  ];

  @override
  Future<List<SearchResult>> search(String id, String query) async => [
    for (final a in await _list('search', {'id': id, 'query': query}))
      SearchResult(a['url'], a['title'], image: a['thumbnail']),
  ];

  @override
  Future<List<Episode>> episodes(String id, String url) async => [
    for (final e in await _list('episodes', {
      'id': id,
      'url': url,
      'title': '',
    }))
      Episode(
        e['number'] as num,
        title: e['name'],
        thumbnail: e['preview'],
        overview: e['summary'],
        ref: {'url': e['url'], 'name': e['name']},
      ),
  ];

  @override
  Future<List<VideoStream>> videos(String id, Episode episode) async {
    final ref = episode.ref as Map;
    return [
      for (final v in await _list('videos', {
        'id': id,
        'url': ref['url'],
        'name': ref['name'] ?? '',
      }))
        VideoStream(
          v['title'],
          v['url'],
          {...?(v['headers'] as Map?)?.cast<String, String>()},
          subtitles: [
            for (final t in v['subtitles']) Subtitle(t['lang'], t['url']),
          ],
          audios: [
            for (final t in v['audios'] ?? const [])
              Subtitle(t['lang'], t['url']),
          ],
          skips: [
            for (final t in v['timestamps'])
              if (_extensionSkips[t['type']] case final type?)
                SkipTime(
                  type,
                  Duration(milliseconds: ((t['start'] as num) * 1000).round()),
                  Duration(milliseconds: ((t['end'] as num) * 1000).round()),
                ),
          ],
        ),
    ];
  }

  @override
  Future<void> install(String path, String fingerprint) =>
      _call('install', {'path': path, 'fingerprint': fingerprint});

  @override
  Future<void> uninstall(String pkg) => _call('uninstall', {'pkg': pkg});
}

const _extensionSkips = {
  'Opening': SkipType.intro,
  'MixedOp': SkipType.intro,
  'Ending': SkipType.outro,
  'Recap': SkipType.recap,
};

/// A source from an installed Aniyomi extension, run through the [ExtensionHost].
/// Extensions left out, offered and installed: the sites AniView reaches itself (see [topSources]), which would only duplicate them, Re:Anime, which
/// AniView no longer offers, and torrent extensions, which need Aniyomi's torrent utilities.
// ponytail: matched by package name; read a manifest flag if more torrent extensions appear
const _hiddenExtensions = {
  'anikoto',
  'animepahe',
  'reanime',
  'hentaitorrent',
  'nyaatorrent',
  'ptorrent',
};

bool hiddenExtension(String pkg) =>
    _hiddenExtensions.contains(pkg.split('.').last);

class ExtensionSource extends Source {
  ExtensionSource(this.id, super.name, super.base, {ExtensionHost? host})
    : host = host ?? ExtensionHost.current;

  final String id;
  final ExtensionHost host;

  /// The sources of every installed extension; none off Android. One installed before it was hidden stays out.
  static Future<List<Source>> installed() async => [
    for (final s in await ExtensionHost.current.sources())
      if (!hiddenExtension(s.pkg))
        ExtensionSource(
          s.id,
          const {'en', 'all', ''}.contains(s.lang)
              ? s.name
              : '${s.name} (${s.lang.toUpperCase()})',
          s.baseUrl,
        ),
  ];

  @override
  Future<List<SearchResult>> search(String query) => host.search(id, query);

  /// Only a result titled exactly as the show (ignoring case and punctuation): extensions carry no AniList or MAL
  /// id to check against, and a wrong show is worse than none, which leaves the pick to the user.
  @override
  Future<String?> match(Map media) async {
    String key(String s) =>
        s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final titles = _searchTitles(media).map(key).toSet();
    for (final title in _searchTitles(media)) {
      for (final result in await search(title)) {
        if (titles.contains(key(result.title))) return result.id;
      }
    }
    return null;
  }

  @override
  Future<List<Episode>> episodesOf(String id) async {
    final episodes = await host.episodes(this.id, id);
    // Extensions say what number an episode is, but some say nothing (-1) or the same for all, and numbers are what
    // picks, downloads and progress go by. Then it's the position that counts: they list newest first.
    final numbered =
        episodes.every((e) => e.number >= 0) &&
        episodes.map((e) => e.number).toSet().length == episodes.length;
    if (numbered) return episodes..sort((a, b) => a.number.compareTo(b.number));
    return [
      for (final (i, e) in episodes.reversed.indexed)
        Episode(
          i + 1,
          title: e.title,
          thumbnail: e.thumbnail,
          overview: e.overview,
          ref: e.ref,
        ),
    ];
  }

  @override
  Future<List<VideoStream>> streams(
    Map media,
    Episode episode, {
    required bool dub,
  }) async {
    final streams = await host.videos(id, episode);
    // Leave explicit language fallback to PlaybackSession so the setting and
    // recorded language agree. Unlabelled streams may carry multiple audio tracks.
    final dubLabel = RegExp(r'\bdub(?:bed)?\b', caseSensitive: false);
    final subLabel = RegExp(r'\bsub(?:bed)?\b', caseSensitive: false);
    final wanted = dub ? dubLabel : subLabel;
    final picked = streams.where((s) => wanted.hasMatch(s.label)).toList();
    return picked.isNotEmpty
        ? picked
        : streams
              .where(
                (s) =>
                    !dubLabel.hasMatch(s.label) && !subLabel.hasMatch(s.label),
              )
              .toList();
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

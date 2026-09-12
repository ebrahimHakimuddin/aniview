import 'dart:convert';
import 'dart:io';

import 'sources.dart';

class EpisodeInfo {
  const EpisodeInfo({this.title, this.image, this.overview});
  final String? title, image, overview;
}

/// ani.zip's entry for a show, looked up by AniList id when there is one and by MAL id otherwise.
Future<Map<String, dynamic>> _mappings(Map media) async {
  final query = media['id'] is int
      ? 'anilist_id=${media['id']}'
      : 'mal_id=${media['idMal']}';
  return jsonDecode(await fetch('https://api.ani.zip/mappings?$query'));
}

/// The AniList and MAL ids of a show, from whichever one it already has. Both are null when ani.zip
/// doesn't know the show; throws when ani.zip can't be reached. ani.zip is a separate service, so this
/// still answers while AniList itself is down.
Future<(int?, int?)> idsOf(Map media) async {
  try {
    final ids = (await _mappings(media))['mappings'] as Map? ?? const {};
    return (ids['anilist_id'] as int?, ids['mal_id'] as int?);
  } on HttpException catch (e) {
    if (e.message == 'HTTP 404') return (null, null);
    rethrow;
  }
}

/// Per-episode titles, synopses and artwork from ani.zip, keyed by episode number ("1", "2", …).
Future<Map<String, EpisodeInfo>> episodeInfo(Map media) async {
  try {
    final json = await _mappings(media);
    final episodes = json['episodes'] as Map<String, dynamic>? ?? const {};
    return {
      for (final MapEntry(:key, :value) in episodes.entries)
        key: EpisodeInfo(
          title: value['title']?['en'] as String?,
          image: value['image'] as String?,
          overview: (value['overview'] ?? value['summary']) as String?,
        ),
    };
  } catch (_) {
    return const {}; // artwork is optional; the list still works without it
  }
}

enum SkipType { intro, outro, recap }

class SkipTime {
  const SkipTime(this.type, this.start, this.end);
  final SkipType type;
  final Duration start, end;

  bool contains(Duration position) =>
      position >= start && position < end - const Duration(seconds: 1);
}

const _skipTypes = {
  'op': SkipType.intro,
  'mixed-op': SkipType.intro,
  'ed': SkipType.outro,
  'mixed-ed': SkipType.outro,
  'recap': SkipType.recap,
};

/// Community intro/outro/recap timestamps from AniSkip. [length] helps it pick times submitted for the same cut.
Future<List<SkipTime>> aniSkip(int? malId, num episode, Duration length) async {
  if (malId == null) return const [];
  try {
    final json = jsonDecode(
      await fetch(
        'https://api.aniskip.com/v2/skip-times/$malId/${epNumber(episode)}'
        '?types=op&types=ed&types=mixed-op&types=mixed-ed&types=recap&episodeLength=${length.inSeconds}',
      ),
    );
    final seen = <SkipType>{};
    return [
      for (final result in json['results'] as List? ?? const [])
        if (_skipTypes[result['skipType']] case final type? when seen.add(type))
          SkipTime(
            type,
            _seconds(result['interval']['startTime']),
            _seconds(result['interval']['endTime']),
          ),
    ];
  } catch (_) {
    return const []; // AniSkip answers 404 when nobody has submitted times for the episode
  }
}

Duration _seconds(num seconds) =>
    Duration(milliseconds: (seconds * 1000).round());

import 'dart:convert';

import 'sources.dart';

class EpisodeInfo {
  const EpisodeInfo({this.title, this.image, this.overview});
  final String? title, image, overview;
}

/// Per-episode titles, synopses and artwork from ani.zip, keyed by episode number ("1", "2", …).
Future<Map<String, EpisodeInfo>> episodeInfo(int anilistId) async {
  try {
    final json = jsonDecode(await fetch('https://api.ani.zip/mappings?anilist_id=$anilistId'));
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

  bool contains(Duration position) => position >= start && position < end - const Duration(seconds: 1);
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
    final json = jsonDecode(await fetch(
      'https://api.aniskip.com/v2/skip-times/$malId/${epNumber(episode)}'
      '?types=op&types=ed&types=mixed-op&types=mixed-ed&types=recap&episodeLength=${length.inSeconds}',
    ));
    final seen = <SkipType>{};
    return [
      for (final result in json['results'] as List? ?? const [])
        if (_skipTypes[result['skipType']] case final type? when seen.add(type))
          SkipTime(type, _seconds(result['interval']['startTime']), _seconds(result['interval']['endTime'])),
    ];
  } catch (_) {
    return const []; // AniSkip answers 404 when nobody has submitted times for the episode
  }
}

Duration _seconds(num seconds) => Duration(milliseconds: (seconds * 1000).round());

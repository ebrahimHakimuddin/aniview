import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net.dart';

/// What an episode is besides canon, by Anime Filler List.
enum EpisodeKind {
  filler('Filler'),
  mixed('Mixed'); // part canon, part filler

  const EpisodeKind(this.label);
  final String label;
}

/// Filler from Anime Filler List (animefillerlist.com): its show matched by AniList's English or romaji title,
/// episodes by number (it lists a show's whole run, as AniList does long shows). Kept on the device for a week; a
/// show it doesn't list has none.
// ponytail: a later season AniList lists apart (numbered from 1) doesn't match; map seasons if people miss it
class Filler {
  static const _site = 'https://www.animefillerlist.com';
  static const _keep = Duration(days: 7);
  static final _loaded = <Object, Future<Map<num, EpisodeKind>>>{};

  /// [media]'s filler and mixed episodes by number; empty when the site doesn't list it or can't be reached.
  static Future<Map<num, EpisodeKind>> of(
    Map media, {
    Net net = const HttpNet(),
  }) {
    final key = media['id'] ?? Filler.titlesOf(media).join();
    return _loaded.putIfAbsent(
      key,
      () => _of(media, net).catchError((Object _) {
        _loaded.remove(key); // asked again next time
        return <num, EpisodeKind>{};
      }),
    );
  }

  static Future<Map<num, EpisodeKind>> _of(Map media, Net net) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'filler:${media['id']}';
    if (_fresh(prefs.getString(key)) case final Map saved) {
      return {
        for (final MapEntry(:key, :value) in (saved['kinds'] as Map).entries)
          num.parse(key): EpisodeKind.values.byName(value),
      };
    }
    final slug = showSlug(await _shows(prefs, net), media);
    final kinds = slug == null
        ? <num, EpisodeKind>{}
        : episodeKinds(await net.text('$_site/shows/$slug'));
    await prefs.setString(
      key,
      jsonEncode({
        'at': DateTime.now().millisecondsSinceEpoch,
        'kinds': {for (final e in kinds.entries) '${e.key}': e.value.name},
      }),
    );
    return kinds;
  }

  static Map? _fresh(String? saved) {
    if (saved == null) return null;
    final json = jsonDecode(saved) as Map;
    final at = DateTime.fromMillisecondsSinceEpoch(json['at'] as int? ?? 0);
    return DateTime.now().difference(at) < _keep ? json : null;
  }

  /// Every show the site lists, as (slug, name).
  static Future<List<(String, String)>> _shows(
    SharedPreferences prefs,
    Net net,
  ) async {
    if (_fresh(prefs.getString('filler_shows')) case final Map saved) {
      return [
        for (final [slug, name] in saved['shows'] as List)
          (slug as String, name as String),
      ];
    }
    final shows = showList(await net.text('$_site/shows'));
    await prefs.setString(
      'filler_shows',
      jsonEncode({
        'at': DateTime.now().millisecondsSinceEpoch,
        'shows': [
          for (final (slug, name) in shows) [slug, name],
        ],
      }),
    );
    return shows;
  }

  static Iterable<String> titlesOf(Map media) => [
    media['title']?['english'],
    media['title']?['romaji'],
  ].whereType<String>();
}

/// The shows on the site's show list page, as (slug, name).
@visibleForTesting
List<(String, String)> showList(String html) => [
  for (final m in RegExp(
    r'<a href="/shows/([^"/]+)">([^<]+)</a>',
  ).allMatches(html))
    (m[1]!, _unescape(m[2]!)),
];

String _unescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&#039;', "'")
    .replaceAll('&quot;', '"')
    .trim();

/// The slug of [media] among [shows]: a name, or the other name it gives in brackets ("Gintama (Silver Soul)"),
/// that reads like its English or romaji title.
@visibleForTesting
String? showSlug(List<(String, String)> shows, Map media) {
  // Spelling aside: "Shippuuden" is "Shippuden", "Kyou" is "Kyo", punctuation and case don't count.
  String norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]'), '')
      .replaceAll('uu', 'u')
      .replaceAll('ou', 'o')
      .replaceAll('oo', 'o');
  final titles = {for (final t in Filler.titlesOf(media)) norm(t)};
  final names = [
    for (final (slug, name) in shows)
      (slug, RegExp(r'^(.*?)\s*(?:\((.*)\))?$').firstMatch(name)!),
  ];
  // Its own name first: "One Pace (One Piece)" is another show that only mentions it.
  for (final group in [1, 2]) {
    for (final (slug, name) in names) {
      if (name[group] case final n? when titles.contains(norm(n))) return slug;
    }
  }
  return null;
}

/// A show page's filler and mixed episodes by number.
@visibleForTesting
Map<num, EpisodeKind> episodeKinds(String html) => {
  for (final m in RegExp(
    r'<tr class="(filler|mixed_canon/filler)\b[^"]*" id="eps-(\d+)"',
  ).allMatches(html))
    int.parse(m[2]!): m[1] == 'filler' ? EpisodeKind.filler : EpisodeKind.mixed,
};

// Opt-in live check: fvm flutter test tool/source_health_test.dart --reporter expanded
// Uses real HTTP and samples Attack on Titan episode 1. AnimePahe's native
// browser clearance and installed Android extensions require device validation.
import 'dart:convert';
import 'dart:io';

import 'package:aniview/sources.dart';
import 'package:flutter_test/flutter_test.dart';

const media = {
  'id': 16498,
  'idMal': 16498,
  'episodes': 25,
  'title': {'romaji': 'Shingeki no Kyojin', 'english': 'Attack on Titan'},
};

String safeError(Object error) =>
    '$error'.replaceAll(RegExp(r'https?://[^\s,)]+'), '<source URL>');

Future<void> checkMedia(VideoStream stream) async {
  final net = const HttpNet();
  var url = stream.url;
  for (var level = 0; level < 3; level++) {
    final body = await net
        .text(url, headers: stream.headers)
        .timeout(const Duration(seconds: 25));
    if (!body.trimLeft().startsWith('#EXTM3U')) {
      throw const FormatException('Expected an HLS playlist');
    }
    final lines = const LineSplitter()
        .convert(body)
        .map((s) => s.trim())
        .toList();
    final next = lines.firstWhere((s) => s.isNotEmpty && !s.startsWith('#'));
    final target = Uri.parse(url).resolve(next).toString();
    if (body.contains('#EXT-X-STREAM-INF')) {
      url = target;
      continue;
    }
    final bytes = await net
        .bytes(target, headers: stream.headers)
        .timeout(const Duration(seconds: 25));
    if (bytes.length < 188) throw const FormatException('Empty media segment');
    return;
  }
  throw const FormatException('Too many nested playlists');
}

void main() {
  for (final source in [
    Anikoto('Anikoto', 'https://anikototv.to'),
    AnimePahe('animepahe', 'https://animepahe.pw', cleared: const HttpNet()),
    AniPm('ani.pm', 'https://ani.pm'),
    AnimeStream('AnimeStream', 'https://anime.uniquestream.net'),
  ]) {
    test(
      '${source.name}: search, match, episodes, sub/dub and media',
      () async {
        var stage = 'search';
        try {
          var hits = <SearchResult>[];
          for (final title in ['Shingeki no Kyojin', 'Attack on Titan']) {
            hits = await source
                .search(title)
                .timeout(const Duration(seconds: 40));
            if (hits.isNotEmpty) break;
          }
          expect(hits, isNotEmpty);
          stdout.writeln('${source.name}: search=${hits.length}');
          stage = 'match';
          final id = await source
              .match(media)
              .timeout(const Duration(seconds: 60));
          expect(id, isNotNull);
          stage = 'episodes';
          final episodes = await source
              .episodesOf(id!)
              .timeout(const Duration(seconds: 60));
          expect(
            episodes.map((e) => e.number),
            containsAll(List.generate(25, (i) => i + 1)),
          );
          final first = episodes.firstWhere((e) => e.number == 1);
          stdout.writeln(
            '${source.name}: matched; episodes=${episodes.length}',
          );
          for (final dub in [false, true]) {
            final audio = dub ? 'dub' : 'sub';
            stage = '$audio streams';
            final streams = await source
                .streams(media, first, dub: dub)
                .timeout(const Duration(seconds: 60));
            expect(streams, isNotEmpty);
            stdout.writeln('${source.name}: $audio streams=${streams.length}');
            stage = '$audio media';
            await checkMedia(streams.first);
            stdout.writeln('${source.name}: $audio playlist and segment OK');
          }
        } catch (error) {
          stdout.writeln('${source.name}: FAIL at $stage: ${safeError(error)}');
          fail(safeError(error));
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }
}

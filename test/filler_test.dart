import 'package:aniview/filler.dart';
import 'package:aniview/history.dart';
import 'package:aniview/playback.dart';
import 'package:aniview/sources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // As animefillerlist.com writes its show list and an episode table.
  const shows =
      '<a href="/shows/certain-magical-index">A Certain Magical Index (Toaru Majutsu No Index)</a>'
      '<a href="/shows/naruto">Naruto</a><a href="/shows/naruto-shippuden">Naruto Shippuden</a>'
      '<a href="/shows/one-pace">One Pace (One Piece)</a><a href="/shows/one-piece">One Piece</a>'
      '<a href="/shows/gintama">Gintama &amp; Friends</a>';
  const table =
      '<tr class="manga_canon odd" id="eps-55"><td class="Number">55</td></tr>'
      '<tr class="filler even" id="eps-57"><td class="Number">57</td></tr>'
      '<tr class="mixed_canon/filler odd" id="eps-58"><td class="Number">58</td></tr>'
      '<tr class="anime_canon even" id="eps-59"><td class="Number">59</td></tr>';

  test(
    'a show is found by its English or romaji title, however it\'s spelled',
    () {
      final list = showList(shows);
      expect(list.last, ('gintama', 'Gintama & Friends'));
      Map media(String romaji, [String? english]) => {
        'title': {'romaji': romaji, 'english': english},
      };
      expect(showSlug(list, media('Naruto: Shippuuden')), 'naruto-shippuden');
      expect(showSlug(list, media('NARUTO')), 'naruto');
      // Its own name before another show's brackets.
      expect(showSlug(list, media('ONE PIECE')), 'one-piece');
      // The other name it gives in brackets.
      expect(
        showSlug(list, media('Toaru Majutsu no Index')),
        'certain-magical-index',
      );
      expect(
        showSlug(list, media('Boruto', 'Boruto: Naruto Next Generations')),
        isNull,
      );
    },
  );

  test('filler and mixed episodes are read off the show page', () {
    expect(episodeKinds(table), {
      57: EpisodeKind.filler,
      58: EpisodeKind.mixed,
    });
  });

  final episodes = [for (var n = 1; n <= 5; n++) Episode(n, ref: '$n')];

  test('up next passes over filler, unless only filler is left', () {
    expect(EpisodePlan(episodes, progress: 1, skip: {2, 3}).upNext?.number, 4);
    expect(EpisodePlan(episodes, progress: 1).upNext?.number, 2);
    expect(EpisodePlan(episodes, progress: 3, skip: {4, 5}).upNext?.number, 4);
  });

  test("the player's next episode passes over filler", () {
    final session = PlaybackSession(episodes, 0, downloaded: (_) => null)
      ..skipped = {2, 3};
    expect(session.nextIndex, 3);
    expect(session.hasNext, isTrue);
    session.index = 3;
    session.skipped = {5};
    expect(session.nextIndex, 4); // only filler left: the next one anyway
  });
}

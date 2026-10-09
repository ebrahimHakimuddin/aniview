import 'package:aniview/downloads.dart';
import 'package:aniview/episode_actions.dart';
import 'package:aniview/sources.dart';
import 'package:flutter_test/flutter_test.dart';

class _Source extends Source {
  _Source(String name) : super(name, 'https://source.test');
  @override
  Future<List<SearchResult>> search(String query) async => [];
  @override
  Future<String?> match(Map media) async => 'show';
  @override
  Future<List<Episode>> episodesOf(String id) async => [];
  @override
  Future<List<VideoStream>> streams(
    Map media,
    Episode episode, {
    required bool dub,
  }) async => [];
}

void main() {
  const media = {'id': 7};
  final episodes = [for (var n = 1; n <= 4; n++) Episode(n, ref: '$n')];
  final items = Downloads.instance.items;
  tearDown(items.clear);

  void downloaded(
    num number,
    String source, {
    bool dub = false,
    DownloadStatus status = DownloadStatus.done,
  }) => items.add(
    Download(
      media: media,
      source: source,
      number: number,
      dub: dub,
      ref: '$number',
      status: status,
    ),
  );

  ShowEpisodes open({Source? site, bool signedIn = true}) =>
      ShowEpisodes(media, episodes, site: site, dub: false, signedIn: signedIn);

  test('offline, only downloaded episodes play, in either audio', () {
    downloaded(2, 'A', dub: true);
    downloaded(4, 'B');
    final eps = open();
    expect(eps.playable.map((e) => e.number), [2, 4]);
    expect(eps.start(episodes[0]), isNull);
    expect(open(site: _Source('Live')).playable, episodes);
  });

  test('an offline episode is remembered under the site its own download came from', () {
    downloaded(2, 'A');
    downloaded(4, 'B');
    final start = open().start(episodes[3])!;
    expect((start.index, start.sourceName), (1, 'B'));
    expect(open(site: _Source('Live')).start(episodes[3])!.sourceName, 'Live');
  });

  test('a failed download is offered again, from the site open now', () {
    downloaded(1, 'Old', status: DownloadStatus.failed);
    downloaded(2, 'A', status: DownloadStatus.downloading);
    downloaded(3, 'A');
    final eps = open(site: _Source('Live'));
    List<EpisodeAction> of(int i) =>
        eps.actionsFor(episodes[i], watched: false);
    expect(of(0), contains(EpisodeAction.retryDownload));
    expect(of(1), isNot(contains(EpisodeAction.download)));
    expect(of(2), contains(EpisodeAction.deleteDownload));
    expect(of(3), contains(EpisodeAction.download));
    // Offline nothing can be fetched.
    expect(
      open().actionsFor(episodes[0], watched: false),
      isNot(contains(EpisodeAction.retryDownload)),
    );
  });

  test('marking watched needs a tracker, and discussion needs AniList', () {
    final eps = open(site: _Source('Live'));
    expect(
      eps.actionsFor(episodes[0], watched: true),
      containsAllInOrder([EpisodeAction.play, EpisodeAction.markUnwatched]),
    );
    expect(
      eps.actionsFor(episodes[0], watched: false),
      contains(EpisodeAction.discuss),
    );
    final signedOut = open(site: _Source('Live'), signedIn: false);
    final actions = signedOut.actionsFor(episodes[0], watched: false);
    expect(actions, isNot(contains(EpisodeAction.markWatched)));
    expect(
      ShowEpisodes(
        {'idMal': 3},
        episodes,
        site: _Source('Live'),
        dub: false,
        signedIn: true,
      ).actionsFor(episodes[0], watched: false),
      isNot(contains(EpisodeAction.discuss)),
    );
  });
}

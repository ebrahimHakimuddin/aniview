import 'anilist.dart';
import 'downloads.dart';
import 'sources.dart';

/// Something a show page offers for one of its episodes (see [ShowEpisodes.actionsFor]).
enum EpisodeAction {
  play,
  markWatched,
  markUnwatched,
  download,
  retryDownload,
  deleteDownload,
  discuss,
  select,
}

/// A show's episodes as its page has them open: listed by [site] (null offline, when only downloads play) in [dub].
/// Decides which of them play, where playing one starts, and what each one offers; every layout of the page asks
/// here and only chooses which of the [EpisodeAction]s it shows.
class ShowEpisodes {
  ShowEpisodes(
    this.media,
    this.episodes, {
    required this.site,
    required this.dub,
    required this.signedIn,
  });

  final Map media;
  final List<Episode> episodes;

  /// The site streaming them; null offline.
  final Source? site;
  final bool dub;

  /// Whether a tracker is signed in, which marking episodes watched needs.
  final bool signedIn;

  Downloads get _downloads => Downloads.instance;

  /// The download that plays [e] offline, in either audio (see [Downloads.toPlay]).
  Download? _offline(Episode e) =>
      _downloads.toPlay(media, e.number, dub: dub, online: false);

  /// What the player gets: everything from a site, else only the downloaded episodes.
  late final List<Episode> playable = site != null
      ? episodes
      : [
          for (final e in episodes)
            if (_offline(e) != null) e,
        ];

  bool canPlay(Episode e) => site != null || playable.contains(e);

  /// Where playing [e] starts in [playable], and the site it's remembered under: the [site] streaming it, else the
  /// one its download came from. Null when it can't play (offline and not downloaded).
  ({List<Episode> episodes, int index, String? sourceName})? start(Episode e) {
    if (!canPlay(e)) return null;
    return (
      episodes: playable,
      index: playable.indexOf(e),
      sourceName: site?.name ?? _offline(e)?.source,
    );
  }

  /// Everything [e] offers, in the order they're listed; [watched] is its state in the page's [EpisodePlan].
  List<EpisodeAction> actionsFor(Episode e, {required bool watched}) {
    final download = _downloads.entry(media, e.number, dub);
    return [
      if (canPlay(e)) EpisodeAction.play,
      if (signedIn)
        watched ? EpisodeAction.markUnwatched : EpisodeAction.markWatched,
      if (site != null && download == null) EpisodeAction.download,
      // From the site open now, not the one that couldn't download it.
      if (site != null && download?.status == DownloadStatus.failed)
        EpisodeAction.retryDownload,
      if (download?.status == DownloadStatus.done) EpisodeAction.deleteDownload,
      if (Show(media).onAniList) EpisodeAction.discuss,
      EpisodeAction.select,
    ];
  }

  String label(EpisodeAction action) => switch (action) {
    EpisodeAction.play => 'Play',
    EpisodeAction.markWatched => 'Mark watched up to here',
    EpisodeAction.markUnwatched => 'Mark as unwatched',
    EpisodeAction.download => 'Download ${dub ? 'dub' : 'sub'}',
    EpisodeAction.retryDownload => 'Retry download',
    EpisodeAction.deleteDownload => 'Delete download',
    EpisodeAction.discuss => 'Discussion',
    EpisodeAction.select => 'Select',
  };
}

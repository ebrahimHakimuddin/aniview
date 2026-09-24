import 'downloads.dart';
import 'history.dart';
import 'metadata.dart';
import 'settings.dart';
import 'sources.dart';

/// The next episode offered near the end: [countdown] when it will start by itself.
typedef UpNext = ({Episode next, Duration remaining, bool countdown});

/// What OK on a TV remote does with the controls hidden.
sealed class OkAction {}

class PlayNext extends OkAction {}

class SkipTo extends OkAction {
  SkipTo(this.position);
  final Duration position;
}

class PlayPause extends OkAction {}

/// The player's decisions about an episode, apart from painting it: where it plays from and where it starts
/// ([open]), which server to fall back to, which subtitles to show, when it counts as watched, when to save the
/// spot, which skip applies, when to offer or start the next episode, and where a held left/right on a TV remote
/// lands. Fed positions and events; the player screen acts on its answers.
class PlaybackSession {
  PlaybackSession(
    this.episodes,
    this.index, {
    this.media = const {},
    this.dub = false,
    this.site = 'Downloads',
    this.fetch,
    VideoStream? Function(Episode)? downloaded,
  }) : downloaded =
           downloaded ??
           ((e) {
             final d = Downloads.instance.toPlay(
               media,
               e.number,
               dub: dub,
               online: fetch != null,
             );
             return d == null ? null : Downloads.instance.streamFor(d);
           });

  final List<Episode> episodes;
  int index;
  final Map media;
  final bool dub;

  /// The site's name, for messages.
  final String site;

  /// An episode's servers on the site; null when it can't be reached, and only downloads play.
  final Future<List<VideoStream>> Function(Episode)? fetch;

  /// An episode's download, when one plays instead of the site.
  final VideoStream? Function(Episode) downloaded;

  /// Whether the episode playing comes from a download.
  bool fromDownload = false;

  /// The servers found for this episode, and the one playing.
  List<VideoStream> streams = [];
  VideoStream? current;

  /// The site's skip times, replaced by AniSkip's when it has them.
  List<SkipTime> skips = [];
  bool upNextDismissed = false;

  final _autoSkipped = <SkipTime>{};
  bool _watched = false;
  Duration _savedAt = Duration.zero;
  Duration? _scrubTo;
  bool _scrubbed = false;

  Episode get episode => episodes[index];
  bool get hasNext => index + 1 < episodes.length;

  /// Moves to episode [i], with nothing loaded, watched or dismissed yet.
  void start(int i) {
    index = i;
    streams = [];
    current = null;
    skips = [];
    upNextDismissed = false;
    _autoSkipped.clear();
    _watched = false;
    fromDownload = false;
  }

  /// Starts episode [i]: its download or else the site's servers become [streams] (the player opens the first), and
  /// the answer is where to start: [at] when given, else the saved spot when resuming. Null when another episode
  /// was started meanwhile, and nothing changed. Throws when it can't be played.
  Future<({Duration? at})?> open(int i, {Duration? at}) async {
    start(i);
    final target = episode;
    final from = at ?? await WatchHistory.resumePoint(media, target.number);
    final download = downloaded(target);
    final List<VideoStream> found;
    if (download != null) {
      found = [download];
    } else if (fetch case final fetch?) {
      found = await fetch(target);
    } else {
      throw Exception(
        "Episode ${epNumber(target.number)} isn't downloaded and $site can't be reached",
      );
    }
    if (index != i) return null;
    if (found.isEmpty) {
      throw Exception(
        'No ${dub ? 'dub' : 'sub'} servers for this episode on $site',
      );
    }
    streams = found;
    fromDownload = download != null;
    return (at: from);
  }

  /// Whether a player error means [current] failed to load (nothing to play yet: [duration] still zero), rather
  /// than a hiccup once it's playing. Then the next server ([fallback]) gets a try.
  bool stalled(Duration duration) =>
      current != null && duration == Duration.zero;

  /// The subtitles to show for [stream], by the language in Settings: that language, else English, else the
  /// first. [off] when Settings turns them off; a null [track] leaves the stream's own (embedded or burned in).
  ({bool off, Subtitle? track}) subtitleFor(VideoStream stream) {
    final language = Settings.subtitleLanguage;
    if (language == 'Off') return (off: true, track: null);
    Subtitle? byLanguage(String l) =>
        stream.subtitles.where((s) => s.label.startsWith(l)).firstOrNull;
    return (
      off: false,
      track:
          byLanguage(language) ??
          byLanguage('English') ??
          stream.subtitles.firstOrNull,
    );
  }

  /// Where another video app left the episode, from what it reported back: the end when it played through.
  static ({Duration position, Duration duration}) externalStop(Map? result) {
    final duration = Duration(milliseconds: result?['duration'] as int? ?? 0);
    return (
      position: result?['completed'] == true
          ? duration
          : Duration(milliseconds: result?['position'] as int? ?? 0),
      duration: duration,
    );
  }

  /// Plays [stream]; its own skip times apply until AniSkip's arrive.
  void playing(VideoStream stream) {
    current = stream;
    if (skips.isEmpty) skips = stream.skips;
  }

  /// The server to try after the current one failed to load; null when none are left.
  VideoStream? fallback() {
    final next = current == null ? -1 : streams.indexOf(current!) + 1;
    return next > 0 && next < streams.length ? streams[next] : null;
  }

  /// True once per episode: the moment it counts as watched.
  bool reachedWatched(Duration position, Duration duration) {
    if (_watched || current == null) return false;
    return _watched = WatchHistory.finished(position, duration);
  }

  /// Whether the spot has moved enough (10 s) since it was last saved.
  bool dueForSave(Duration position) {
    if ((position - _savedAt).abs() < const Duration(seconds: 10)) return false;
    _savedAt = position;
    return true;
  }

  SkipTime? activeSkip(Duration position) =>
      skips.where((s) => s.contains(position)).firstOrNull;

  /// The skip for the on-screen button at [position].
  SkipTime? skipButton(Duration position) =>
      Settings.skipMode == SkipMode.button ? activeSkip(position) : null;

  /// The skip to take by itself at [position], each one once (seeking back into it plays it).
  SkipTime? autoSkip(Duration position) {
    if (Settings.skipMode != SkipMode.auto) return null;
    final skip = activeSkip(position);
    return skip != null && _autoSkipped.add(skip) ? skip : null;
  }

  /// The next episode is offered during the outro or the last 20 s, counting down when auto-next is on.
  UpNext? upNext(Duration position, Duration duration) {
    if (!hasNext || upNextDismissed || duration <= Duration.zero) return null;
    final remaining = duration - position;
    const end = Duration(seconds: 20);
    final inOutro = skips.any(
      (s) => s.type == SkipType.outro && s.contains(position),
    );
    if (!inOutro && remaining > end) return null;
    return (
      next: episodes[index + 1],
      remaining: remaining,
      countdown: Settings.autoNext && remaining <= end,
    );
  }

  /// Whether finishing the episode starts the next one.
  bool get advancesOnFinish => hasNext && Settings.autoNext && !upNextDismissed;

  /// OK takes the up-next offer, else the on-screen skip, else plays or pauses.
  OkAction ok(Duration position, Duration duration) {
    if (upNext(position, duration) != null) return PlayNext();
    if (skipButton(position) case final skip?) return SkipTo(skip.end);
    return PlayPause();
  }

  int _streak = 0;
  Duration? _streakTo;
  DateTime _streakAt = DateTime(0);

  /// A seek button (or double tap) for [seconds]: where to land, and the running total to show. Presses the same
  /// way within 1.2 s add up (+10s, +20s, +30s), each from where the last one landed, since mpv reports the new
  /// position late.
  ({Duration to, int total}) step(
    Duration position,
    Duration duration,
    int seconds, {
    DateTime? now,
  }) {
    now ??= DateTime.now();
    final adding =
        _streakTo != null &&
        _streak.sign == seconds.sign &&
        now.difference(_streakAt) < const Duration(milliseconds: 1200);
    _streak = adding ? _streak + seconds : seconds;
    _streakAt = now;
    final to = _streakTo = press(
      adding ? _streakTo! : position,
      duration,
      seconds,
    );
    return (to: to, total: _streak);
  }

  /// Left/right pressed: where to seek right away, [seconds] from [position].
  Duration press(Duration position, Duration duration, int seconds) =>
      _scrubTo = clamp(position + Duration(seconds: seconds), duration);

  /// Left/right still held: moves the target without seeking (seeking ~20 times a second makes mpv stutter).
  /// Null when there was no press to follow.
  Duration? hold(Duration duration, int seconds) {
    final to = _scrubTo;
    if (to == null) return null;
    _scrubbed = true;
    return _scrubTo = clamp(to + Duration(seconds: seconds), duration);
  }

  /// Left/right released: where to seek when it was held, else null (the press already seeked).
  Duration? release() {
    final to = _scrubbed ? _scrubTo : null;
    _scrubTo = null;
    _scrubbed = false;
    return to;
  }

  /// Where resuming episode [number] of a [WatchRecord] from [source] opens: that site's episode list when it has
  /// the episode, else the downloads. Throws, saying why, when neither has it; [listed] is whether [source] is still
  /// one of the top sites.
  static (List<Episode>, int) resumeIn(
    num number, {
    required List<Episode> site,
    required List<Episode> downloaded,
    required String source,
    required bool listed,
  }) {
    final episodes = site.any((e) => e.number == number) ? site : downloaded;
    final index = episodes.indexWhere((e) => e.number == number);
    if (index == -1) {
      throw Exception(
        listed
            ? 'Episode ${epNumber(number)} is not on $source yet'
            : '$source is no longer one of the top sites',
      );
    }
    return (episodes, index);
  }

  /// [t] kept within the episode.
  static Duration clamp(Duration t, Duration duration) {
    if (t < Duration.zero) return Duration.zero;
    return duration > Duration.zero && t > duration ? duration : t;
  }
}

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

/// The player's decisions about an episode as it plays, apart from painting it: which server to fall back to, when
/// the episode counts as watched, when to save the spot, which skip applies, when to offer or start the next
/// episode, and where a held left/right on a TV remote lands. Fed positions and events; the player screen acts on
/// its answers.
class PlaybackSession {
  PlaybackSession(this.episodes, this.index);

  final List<Episode> episodes;
  int index;

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

  /// [t] kept within the episode.
  static Duration clamp(Duration t, Duration duration) {
    if (t < Duration.zero) return Duration.zero;
    return duration > Duration.zero && t > duration ? duration : t;
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';

import 'analytics.dart';
import 'anilist.dart';
import 'cloudflare.dart';
import 'downloads.dart';
import 'history.dart';
import 'hls_proxy.dart';
import 'metadata.dart';
import 'settings.dart';
import 'sources.dart';
import 'states.dart';
import 'tracker.dart';
import 'tv.dart';
import 'ui.dart';
import 'platform.dart';
import 'playback.dart';

/// Full-screen player with Dantotsu-style gestures: double-tap seek, optional swipe seek and brightness (left) /
/// volume (right) swipes, hold for 2×, lock, episode drawer, server/subtitle/speed pickers, AniSkip with
/// intro/outro markers on the seek bar. Downloaded episodes always play from disk.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.media,
    required this.source,
    required this.episodes,
    required this.index,
    required this.dub,
    this.sourceName,
  });

  final Map media;
  final Source?
  source; // null when playing downloads while the site is unreachable
  final String? sourceName;
  final List<Episode> episodes;
  final int index;
  final bool dub;

  /// Whether a player is open, when the remote's search key does nothing.
  static bool showing = false;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  // mpv-android's defaults: a 64MB cache, zero-copy decoding where the chip allows it and mpv's `fast` profile
  // (bilinear scaling, no dithering), which TV GPUs need to keep up at 1080p.
  final player = Player(
    configuration: const PlayerConfiguration(bufferSize: 64 * 1024 * 1024),
  );
  late final controller = VideoController(
    player,
    configuration: Settings.directVideo
        ? const VideoControllerConfiguration(
            vo: 'mediacodec_embed',
            hwdec: 'mediacodec',
          )
        : const VideoControllerConfiguration(
            hwdec: 'mediacodec,mediacodec-copy',
          ),
  );
  final _scaffold = GlobalKey<ScaffoldState>();
  late final session = PlaybackSession(
    widget.episodes,
    widget.index,
    media: widget.media,
    dub: widget.dub,
    site: _sourceName,
    fetch: switch (widget.source) {
      final source? => (e) => withCloudflare(
        context,
        () => source.streams(widget.media, e, dub: widget.dub),
      ),
      null => null,
    },
  );
  int? _skipsRequested;
  String subtitle = 'Auto';
  Object? error;
  String? hint;
  IconData? hintIcon;
  bool controls = true, locked = false;

  /// Fit, fill (crop) or stretch.
  BoxFit fit = BoxFit.contain;
  double rate = Settings.speed, brightness = .5, volume = 1, doubleTapX = 0;
  // The phone's media volume as 0–1.

  Duration? seekTarget;
  Duration? _startAt; // where the current server was asked to start
  Timer? _hideTimer, _hintTimer;
  late final List<StreamSubscription> _subs;
  final _playFocus = FocusNode();
  // Out of traversal: it spans the screen, so the D-pad would otherwise land on it between buttons.
  final _keys = FocusNode(debugLabel: 'player keys', skipTraversal: true);
  final _controlsNode = FocusNode(skipTraversal: true, canRequestFocus: false);

  /// The seek bar alone, shown for a moment while seeking with the controls hidden.
  bool _timelineShown = false;
  Timer? _timelineTimer;

  void _showTimeline() {
    _timelineTimer?.cancel();
    setState(() => _timelineShown = true);
    _timelineTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _timelineShown = false);
    });
  }

  /// Into the controls: play/pause, or while a video loads (no play button yet) the first control there is.
  void _focusControls() {
    if (_playFocus.context != null) return _playFocus.requestFocus();
    _controlsNode.traversalDescendants.firstOrNull?.requestFocus();
  }

  int _shownSecond = -1;
  // Home on a TV or switching apps may be the last chance: the app can be closed from there.
  late final _lifecycle = AppLifecycleListener(onHide: _saveHistory);

  int get index => session.index;
  List<VideoStream> get streams => session.streams;
  VideoStream? get current => session.current;
  List<SkipTime> get skips => session.skips;
  Episode get episode => session.episode;
  bool get hasNext => session.hasNext;
  String get _sourceName =>
      widget.sourceName ?? widget.source?.name ?? 'Downloads';

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    PlayerScreen.showing = true;
    if (player.platform case final NativePlayer mpv) {
      mpv.command(['apply-profile', 'fast']).ignore();
    }
    onRemoteSeek = (to) =>
        player.seek(PlaybackSession.clamp(to, player.state.duration));
    _lifecycle;
    ScreenBrightness().application.then((v) => brightness = v).ignore();
    Analytics.screen('/player', title: 'Player');
    _subs = [
      player.stream.position.listen(_onPosition),
      player.stream.duration.listen(_onDuration),
      player.stream.playing.listen((_) {
        _refresh();
        _publish();
      }),
      player.stream.buffering.listen((_) => _refresh()),
      player.stream.tracks.listen((_) => _refresh()),
      // A stream that never loads would otherwise spin on "Loading video…" forever.
      player.stream.error.listen((e) {
        if (!mounted || !session.stalled(player.state.duration)) return;
        // Aggregated sources often list dead servers; move on before giving up.
        if (session.fallback() case final next?) {
          _hint(
            '${current!.label} failed · trying ${next.label}',
            icon: Icons.dns_rounded,
          );
          _play(next, at: _startAt);
        } else {
          setState(() => error = Exception(e));
        }
      }),
      player.stream.completed.listen((done) {
        if (done && session.advancesOnFinish) {
          _load(index + 1);
        }
      }),
    ];
    _load(index);
    _scheduleHide();
  }

  /// TV remote: with the controls hidden, left/right seek, OK plays/pauses and up/down bring the controls
  /// up; with them showing, the D-pad moves between buttons. Media keys work either way.
  bool _onKey(KeyEvent event) {
    if (!isTv || !mounted) return false;
    // Releasing a held left/right lands the scrub with one seek.
    if (event is KeyUpEvent) {
      if (session.release() case final to?) {
        player.seek(to);
        seekTarget = null;
        _showTimeline();
      }
      return false;
    }
    // Leave keys alone while a menu, dialog or the episode list is open, or for the error's buttons.
    if (error != null ||
        ModalRoute.of(context)?.isCurrent != true ||
        _scaffold.currentState?.isEndDrawerOpen == true) {
      return false;
    }
    final key = event.logicalKey;
    final seek = Settings.seekSeconds;
    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      player.playOrPause();
    } else if (key == LogicalKeyboardKey.mediaFastForward) {
      _seekBy(seek);
    } else if (key == LogicalKeyboardKey.mediaRewind) {
      _seekBy(-seek);
    } else if (key == LogicalKeyboardKey.mediaTrackNext && hasNext) {
      _load(index + 1);
    } else if (controls && !locked) {
      _scheduleHide(); // browsing the controls keeps them up
      // Nothing inside has focus yet (just opened): start on play/pause.
      if (!_keys.hasPrimaryFocus) return false;
      _focusControls();
    } else if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      _scrub(event);
    } else if (event is KeyDownEvent &&
        (key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown)) {
      if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) {
        switch (error == null
            ? session.ok(player.state.position, player.state.duration)
            : PlayPause()) {
          case PlayNext():
            _load(index + 1);
            return true;
          case SkipTo(:final position):
            player.seek(position);
            return true;
          case PlayPause():
            player.playOrPause();
        }
      }
      setState(() {
        controls = true;
        locked = false;
      });
      _scheduleHide();
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusControls());
    } else {
      return false;
    }
    return true;
  }

  /// Left/right: a step per press, or a scrub while held that lands on release (see [_onKey]).
  void _scrub(KeyEvent event) {
    final seek = Settings.seekSeconds;
    final step = event.logicalKey == LogicalKeyboardKey.arrowLeft
        ? -seek
        : seek;
    final held = event is KeyRepeatEvent
        ? session.hold(player.state.duration, step)
        : null;
    if (held != null) {
      seekTarget = held;
      _showTimeline();
      _hint(formatDuration(held), icon: step > 0 ? _forwardIcon : _replayIcon);
    } else {
      _seekBy(step);
    }
  }

  @override
  void dispose() {
    _playFocus.dispose();
    _keys.dispose();
    _controlsNode.dispose();
    _lifecycle.dispose();
    PlayerScreen.showing = false;
    nowPlaying.value = null;
    onRemoteSeek = null;
    _saveHistory();
    for (final sub in _subs) {
      sub.cancel();
    }
    _hideTimer?.cancel();
    _hintTimer?.cancel();
    _timelineTimer?.cancel();
    player.dispose();
    ScreenBrightness().resetApplicationScreenBrightness();
    SystemChrome.setPreferredOrientations([]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _load(int i, {Duration? at}) async {
    _saveHistory(); // where the outgoing episode stopped, before index moves on
    setState(() {
      session.start(i);
      error = null;
      _skipsRequested = null;
    });
    // The previous episode keeps emitting its (near-end) position while servers load, which would count the new one as watched.
    await player.stop();
    if (!mounted) return;
    try {
      final opened = await session.open(i, at: at);
      if (!mounted || opened == null) return;
      Analytics.event('episode_play', {
        'media_id': widget.media['id'],
        'episode': episode.number,
        'source': _sourceName,
        'dub': widget.dub,
        'downloaded': session.fromDownload,
      });
      if (Settings.externalPlayer) {
        final stopped = await _playExternal(streams.first, at: opened.at);
        if (!mounted) return;
        if (stopped == null) {
          throw Exception('No video player app is installed');
        }
        return Navigator.pop(context);
      }
      await _play(streams.first, at: opened.at);
    } catch (e) {
      if (mounted && index == i) setState(() => error = e);
    }
  }

  Future<void> _play(VideoStream stream, {Duration? at}) async {
    _startAt = at;
    setState(() => session.playing(stream));
    final resume = at != null && at > Duration.zero ? at : null;
    await player.open(
      // HLS goes through the local proxy; direct files (mp4) get their headers from mpv itself.
      Media(
        stream.isLocal || !stream.isHls
            ? stream.url
            : await HlsProxy.url(stream.url, stream.headers),
        httpHeaders: stream.isHls ? null : stream.headers,
        // mpv starts the file here; a seek right after opening is often dropped while a stream is still loading.
        start: resume,
      ),
    );
    // open() returns before mpv has loaded the file, and seeking or adding a subtitle track before that is dropped.
    if (player.state.duration == Duration.zero) {
      await player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 20), onTimeout: () => Duration.zero);
    }
    if (!mounted || current != stream) return;
    // Some streams ignore the start position; land there anyway.
    if (resume != null &&
        player.state.position < resume - const Duration(seconds: 3)) {
      await player.seek(resume);
    }
    await _applySubtitle(stream);
    await player.setRate(rate);
  }

  /// Hands [stream] to another video app and records where it stopped like our own player would. Returns that
  /// position (zero when the app doesn't report it), or null when no app can play it.
  Future<Duration?> _playExternal(VideoStream stream, {Duration? at}) async {
    setState(() => session.current = stream);
    // Other apps can't send the stream's headers or read app storage, so both go through the local proxy.
    final dir = stream.isLocal ? File(stream.url).parent.path : null;
    Future<String> address(String url) => dir != null
        ? HlsProxy.localFile(dir, url.split('/').last)
        : HlsProxy.url(
            url,
            stream.headers,
            ext: stream.isHls && url == stream.url
                ? 'm3u8'
                : Uri.parse(url).path.split('.').last,
          );
    try {
      final result = await AndroidApp.playExternal(
        url: stream.isHls ? await address(stream.url) : stream.url,
        headers: stream.isHls ? null : stream.headers, // MX Player only
        title: '${titleOf(widget.media)} · Episode ${epNumber(episode.number)}',
        position: at ?? Duration.zero,
        subtitles: [
          for (final s in stream.subtitles)
            {'label': s.label, 'url': await address(s.url)},
        ],
      );
      final (:position, :duration) = PlaybackSession.externalStop(result);
      _checkWatched(position, duration);
      _saveHistory(position, duration);
      return position;
    } on PlatformException catch (e) {
      _hint(e.message ?? 'No video player app', icon: Icons.error_outline);
      return null;
    }
  }

  Future<void> _applySubtitle(VideoStream stream) async {
    final pick = session.subtitleFor(stream);
    if (pick.off) return _setSubtitle(SubtitleTrack.no(), 'Off');
    if (pick.track case final track?) return _setExternal(stream, track);
    return _setSubtitle(
      SubtitleTrack.auto(),
      'Auto',
    ); // embedded or burned-in subs
  }

  /// Subtitle hosts refuse requests without the stream's Referer, which mpv doesn't send, so go through the proxy.
  Future<void> _setExternal(VideoStream stream, Subtitle s) async =>
      _setSubtitle(
        SubtitleTrack.uri(
          stream.isLocal
              ? s.url
              : await HlsProxy.url(
                  s.url,
                  stream.headers,
                  ext: Uri.parse(s.url).path.split('.').last,
                ),
          title: s.label,
        ),
        s.label,
      );

  Future<void> _setSubtitle(SubtitleTrack track, String label) async {
    await player.setSubtitleTrack(track);
    if (mounted) setState(() => subtitle = label);
  }

  void _onPosition(Duration position) {
    _checkWatched(position, player.state.duration);
    if (session.autoSkip(position) case final skip?) {
      player.seek(skip.end);
      _hint('Skipped ${_skipName(skip.type)}');
    }
    if (session.dueForSave(position)) _saveHistory();
    if (position.inSeconds != _shownSecond) {
      _shownSecond = position.inSeconds;
      _refresh();
      _publish();
    }
  }

  /// What's playing, for the phone remote.
  void _publish() {
    if (current == null) return;
    final title = episode.title;
    nowPlaying.value = (
      title: titleOf(widget.media),
      episode:
          'Episode ${epNumber(episode.number)}${title == null ? '' : ' · $title'}',
      paused: !player.state.playing,
      position: player.state.position,
      duration: player.state.duration,
    );
  }

  void _checkWatched(Duration position, Duration duration) {
    if (session.reachedWatched(position, duration)) {
      Analytics.event('episode_watched', {
        'media_id': widget.media['id'],
        'episode': episode.number,
      });
      _syncProgress();
    }
  }

  /// Once the length is known, ask AniSkip; its community times replace the site's own when found.
  void _onDuration(Duration duration) {
    if (duration <= Duration.zero ||
        _skipsRequested == index ||
        Settings.skipMode == SkipMode.off) {
      return;
    }
    final requested = _skipsRequested = index;
    aniSkip(widget.media['idMal'], episode.number, duration).then((found) {
      if (mounted && index == requested && found.isNotEmpty) {
        setState(() => session.skips = found);
      }
    });
  }

  void _saveHistory([Duration? position, Duration? duration]) {
    position ??= player.state.position;
    duration ??= player.state.duration;
    if (current == null) return;
    WatchHistory.played(
      widget.media,
      source: _sourceName,
      episodes: widget.episodes,
      index: index,
      position: position,
      duration: duration,
      dub: widget.dub,
    );
  }

  Future<void> _syncProgress() async {
    final number = episode.number.toInt();
    switch (await Tracker.watched(widget.media, number)) {
      case SyncResult.skipped:
        break;
      case SyncResult.saved:
        _hint(
          'Progress updated · Episode $number',
          icon: Icons.check_circle_rounded,
        );
      case SyncResult.queued:
        _hint(
          'Saved · syncs next time you open the app',
          icon: Icons.cloud_off_rounded,
        );
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && player.state.playing) setState(() => controls = false);
    });
  }

  void _toggleControls() {
    setState(() => controls = !controls);
    if (controls) _scheduleHide();
  }

  void _hint(String text, {IconData? icon, bool sticky = false}) {
    _hintTimer?.cancel();
    if (!mounted) return;
    setState(() {
      hint = text;
      hintIcon = icon;
    });
    if (!sticky) {
      _hintTimer = Timer(
        const Duration(milliseconds: 1500),
        () => mounted ? setState(() => hint = null) : null,
      );
    }
  }

  Duration _clamp(Duration t) =>
      PlaybackSession.clamp(t, player.state.duration);

  void _seekBy(int seconds) {
    HapticFeedback.selectionClick();
    final (:to, :total) = session.step(
      player.state.position,
      player.state.duration,
      seconds,
    );
    player.seek(to);
    if (!controls) _showTimeline();
    _hint(
      total > 0 ? '+${total}s' : '${total}s',
      icon: total > 0 ? _forwardIcon : _replayIcon,
    );
  }

  void _verticalDrag(DragUpdateDetails d, Size size) {
    final delta = -d.delta.dy / (size.height * .8);
    if (d.localPosition.dx < size.width / 2) {
      brightness = (brightness + delta).clamp(0.0, 1.0);
      ScreenBrightness().setApplicationScreenBrightness(brightness);
      _hint(
        '${(brightness * 100).round()}%',
        icon: Icons.brightness_6_rounded,
        sticky: true,
      );
    } else {
      volume = (volume + delta).clamp(0.0, 1.0);
      AndroidApp.setVolume(volume).ignore();
      _hint(
        '${(volume * 100).round()}%',
        icon: volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
        sticky: true,
      );
    }
  }

  void _clearHint([Object? _]) => _hint(hint ?? '', icon: hintIcon);

  IconData get _replayIcon => switch (Settings.seekSeconds) {
    5 => Icons.replay_5_rounded,
    10 => Icons.replay_10_rounded,
    30 => Icons.replay_30_rounded,
    _ => Icons.replay_rounded,
  };

  IconData get _forwardIcon => switch (Settings.seekSeconds) {
    5 => Icons.forward_5_rounded,
    10 => Icons.forward_10_rounded,
    30 => Icons.forward_30_rounded,
    _ => Icons.forward_rounded,
  };

  /// The video, rebuilt only when the picture fit changes: the rest of the screen refreshes every second.
  Widget? _video;
  BoxFit? _videoFit;

  Widget get _videoView {
    if (_video == null || _videoFit != fit) {
      _videoFit = fit;
      _video = Video(
        controller: controller,
        controls: NoVideoControls,
        fit: fit,
        subtitleViewConfiguration: SubtitleViewConfiguration(
          // media_kit otherwise shrinks text relative to a 1920×1080 view, making it tiny on phones.
          textScaler: TextScaler.noScaling,
          style: TextStyle(
            fontSize: Settings.subtitleSize,
            color: Colors.white,
            shadows: const [Shadow(blurRadius: 8), Shadow(blurRadius: 2)],
          ),
        ),
      );
    }
    return _video!;
  }

  @override
  Widget build(BuildContext context) {
    // With the controls hidden, the remote's keys go to the player itself (see _onKey).
    if (isTv && !controls && !_keys.hasPrimaryFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            !controls &&
            ModalRoute.of(context)?.isCurrent == true &&
            _scaffold.currentState?.isEndDrawerOpen != true) {
          _keys.requestFocus();
        }
      });
    }
    return Focus(
      focusNode: _keys,
      autofocus: isTv,
      onKeyEvent: (_, event) =>
          _onKey(event) ? KeyEventResult.handled : KeyEventResult.ignored,
      child: Theme(
        // Controls sit on video, so they're white whatever the theme's accents.
        data: Theme.of(context).copyWith(
          iconButtonTheme: IconButtonThemeData(
            style: _onVideo(
              IconButton.styleFrom(
                foregroundColor: Colors.white,
                disabledForegroundColor: Colors.white30,
              ),
            ),
          ),
        ),
        child: _player(context),
      ),
    );
  }

  Widget _player(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final position = player.state.position;
    final skip = session.skipButton(position);
    final loading =
        error == null && (current == null || player.state.buffering);
    final swipes = !locked && Settings.swipeGestures;
    final upNext = _upNext(position);

    // On TV, Back first hides the controls, like Netflix.
    return PopScope(
      canPop: !(isTv && controls && !locked),
      // Saved on the way out, not in dispose: the page underneath reloads history as soon as this pops.
      // Paused too, or it plays on through the exit animation over whatever comes next.
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) return setState(() => controls = false);
        _saveHistory();
        player.pause();
        // Rotate back now rather than after the route is gone, so the page underneath isn't shown sideways.
        SystemChrome.setPreferredOrientations([]);
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      },
      child: Scaffold(
        key: _scaffold,
        backgroundColor: Colors.black,
        endDrawerEnableOpenDragGesture: false, // horizontal swipes seek
        endDrawer: Drawer(
          width: 400,
          child: _EpisodeList(
            episodes: widget.episodes,
            current: index,
            media: widget.media,
            dub: widget.dub,
            online: widget.source != null,
            onSelect: (i) {
              _scaffold.currentState?.closeEndDrawer();
              if (i != index) _load(i);
            },
          ),
        ),
        body: Stack(
          fit: StackFit.expand,
          children: [
            _videoView,
            IgnorePointer(
              child: AnimatedOpacity(
                opacity: controls && !locked ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0xB3000000),
                        Color(0x1A000000),
                        Color(0x1A000000),
                        Color(0xE6000000),
                      ],
                      stops: [0, .28, .6, 1],
                    ),
                  ),
                ),
              ),
            ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
              onDoubleTapDown: locked
                  ? null
                  : (d) => doubleTapX = d.localPosition.dx,
              onDoubleTap: locked
                  ? null
                  : () => _seekBy(
                      doubleTapX < size.width / 2
                          ? -Settings.seekSeconds
                          : Settings.seekSeconds,
                    ),
              onLongPressStart: locked
                  ? null
                  : (_) {
                      HapticFeedback.mediumImpact();
                      player.setRate(2);
                      _hint(
                        '2× speed',
                        icon: Icons.fast_forward_rounded,
                        sticky: true,
                      );
                    },
              onLongPressEnd: locked
                  ? null
                  : (_) {
                      player.setRate(rate);
                      _clearHint();
                    },
              onVerticalDragStart: !swipes
                  ? null
                  // may have changed with the volume keys
                  : (_) => AndroidApp.volume()
                        .then((v) => volume = v ?? volume)
                        .ignore(),
              onVerticalDragUpdate: !swipes
                  ? null
                  : (d) => _verticalDrag(d, size),
              onVerticalDragEnd: !swipes ? null : _clearHint,
              onHorizontalDragStart: !swipes
                  ? null
                  : (_) => seekTarget = player.state.position,
              onHorizontalDragUpdate: !swipes
                  ? null
                  : (d) {
                      seekTarget = _clamp(
                        seekTarget! +
                            Duration(milliseconds: (d.delta.dx * 250).round()),
                      );
                      final diff = (seekTarget! - position).inSeconds;
                      _hint(
                        '${formatDuration(seekTarget!)}  (${diff >= 0 ? '+' : ''}${diff}s)',
                        sticky: true,
                      );
                    },
              onHorizontalDragEnd: !swipes
                  ? null
                  : (_) {
                      player.seek(seekTarget!);
                      seekTarget = null;
                      _clearHint();
                    },
            ),
            if (loading)
              const IgnorePointer(
                child: Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              ),
            if (hint != null)
              IgnorePointer(
                child: Align(
                  alignment: const Alignment(0, -.6),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .72),
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (hintIcon != null) ...[
                            Icon(hintIcon, size: 20, color: Colors.white),
                            const SizedBox(width: 8),
                          ],
                          Text(
                            hint!,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            IgnorePointer(
              ignoring: !controls,
              // Hidden controls can't hold D-pad focus.
              child: ExcludeFocus(
                excluding: !controls,
                child: AnimatedOpacity(
                  opacity: controls ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Focus(
                    focusNode: _controlsNode,
                    child: locked
                        ? _lockedOverlay()
                        : isTv
                        ? _tvOverlay(position, loading)
                        : _overlay(position, loading),
                  ),
                ),
              ),
            ),
            if (_timelineShown && !controls && !locked && error == null)
              Positioned(
                left: isTv ? tvMargin : 16,
                right: isTv ? tvMargin : 16,
                bottom: isTv ? 24 : 16,
                child: IgnorePointer(
                  child: SafeArea(top: false, child: _timeline(position)),
                ),
              ),
            if (upNext != null && !locked && !controls)
              Positioned(
                right: isTv ? tvMargin : 24,
                bottom: isTv ? 32 : 24,
                // OK takes the offer on TV (see _onKey), so it never holds focus.
                child: ExcludeFocus(excluding: isTv, child: upNext),
              )
            else if (skip != null &&
                !locked &&
                !controls) // the controls have their own
              Positioned(
                right: isTv ? tvMargin : 24,
                bottom: isTv ? 48 : 32,
                child: ExcludeFocus(
                  excluding: isTv,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                    ),
                    onPressed: () => player.seek(skip.end),
                    icon: const Icon(Icons.fast_forward_rounded),
                    label: Text(
                      'Skip ${_skipName(skip.type)}${isTv ? ' · OK' : ''}',
                    ),
                  ),
                ),
              ),
            if (error != null) _errorView(),
          ],
        ),
      ),
    );
  }

  /// Offers the next episode during the outro or the last 20 seconds; cancelling also stops auto-play.
  Widget? _upNext(Duration position) {
    if (error != null) return null;
    final offer = session.upNext(position, player.state.duration);
    if (offer == null) return null;
    final (:next, :remaining, :countdown) = offer;
    return SizedBox(
      width: 340,
      child: Material(
        color: const Color(0xE6141218),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            SizedBox(
              width: 120,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Artwork(
                  next.thumbnail,
                  placeholder: Center(
                    child: Text(
                      epNumber(next.number),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Colors.white54,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      countdown
                          ? 'Next in ${remaining.inSeconds}s'
                          : 'Up next${isTv ? ' · press OK' : ''}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      'Episode ${epNumber(next.number)}${next.title == null ? '' : ' · ${next.title}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (!isTv)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () =>
                                setState(() => session.upNextDismissed = true),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => _load(index + 1),
                            child: const Text('Play now'),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _lockedOverlay() => SafeArea(
    child: Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: IconButton.filledTonal(
          tooltip: 'Unlock',
          iconSize: 28,
          icon: const Icon(Icons.lock_rounded),
          onPressed: () {
            setState(() => locked = false);
            _scheduleHide();
          },
        ),
      ),
    ),
  );

  void _openEpisodes() {
    if (!isTv) return _scaffold.currentState?.openEndDrawer();
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        child: SizedBox(
          width: 600,
          height: MediaQuery.sizeOf(context).height * .8,
          child: _EpisodeList(
            episodes: widget.episodes,
            current: index,
            media: widget.media,
            dub: widget.dub,
            online: widget.source != null,
            onSelect: (i) {
              Navigator.pop(context);
              if (i != index) _load(i);
            },
          ),
        ),
      ),
    );
  }

  Future<void> _openSubtitles() async {
    final external = current?.subtitles ?? const <Subtitle>[];
    final embedded = player.state.tracks.subtitle
        .where(
          (t) =>
              t.id != 'auto' &&
              t.id != 'no' &&
              !external.any((s) => s.label == t.title),
        )
        .toList();
    String name(SubtitleTrack t) => t.title ?? t.language ?? 'Track ${t.id}';
    final options = <Object, String>{
      'off': 'Off',
      for (final s in external) s: s.label,
      for (final t in embedded) t: name(t),
    };
    final selected = options.entries
        .where((e) => e.value == subtitle)
        .firstOrNull
        ?.key;
    final picked = await _pick<Object>('Subtitles', options, selected ?? 'off');
    switch (picked) {
      case Subtitle s:
        await _setExternal(current!, s);
      case SubtitleTrack t:
        await _setSubtitle(t, name(t));
      case 'off':
        await _setSubtitle(SubtitleTrack.no(), 'Off');
    }
  }

  static const _fits = {
    BoxFit.contain: 'Fit',
    BoxFit.cover: 'Fill (crop)',
    BoxFit.fill: 'Stretch',
  };

  /// A choice from a sheet (a panel on TV), with the controls kept up meanwhile.
  Future<T?> _pick<T>(String title, Map<T, String> options, T current) async {
    _hideTimer?.cancel();
    final picked = await pickOne(context, title, options, current);
    _scheduleHide();
    return picked;
  }

  /// The server playing, switchable in place (keeps the position).
  Widget? _serverButton() {
    if (streams.length < 2 || !streams.contains(current)) return null;
    return TextButton.icon(
      style: _onVideo(TextButton.styleFrom(foregroundColor: Colors.white)),
      onPressed: () async {
        final s = await _pick('Server', {
          for (final s in streams) s: s.label,
        }, current!);
        if (s != null && s != current && mounted) {
          await _play(s, at: player.state.position);
        }
      },
      icon: const Icon(Icons.dns_outlined),
      label: Text(current!.label),
    );
  }

  Widget _speedButton() => TextButton.icon(
    style: _onVideo(TextButton.styleFrom(foregroundColor: Colors.white)),
    onPressed: () async {
      final r = await _pick('Speed', {
        for (final r in const [.5, .75, 1.0, 1.25, 1.5, 1.75, 2.0]) r: '$r×',
      }, rate);
      if (r == null || !mounted) return;
      setState(() => rate = r);
      await player.setRate(r);
    },
    icon: const Icon(Icons.speed_rounded),
    label: Text('$rate×'),
  );

  /// Fit, fill (crop) or stretch, a tap each.
  Widget _fitButton() => IconButton(
    tooltip: 'Picture · ${_fits[fit]}',
    icon: Icon(switch (fit) {
      BoxFit.cover => Icons.crop_free_rounded,
      BoxFit.fill => Icons.open_in_full_rounded,
      _ => Icons.fit_screen_rounded,
    }),
    onPressed: () {
      final next = switch (fit) {
        BoxFit.contain => BoxFit.cover,
        BoxFit.cover => BoxFit.fill,
        _ => BoxFit.contain,
      };
      setState(() => fit = next);
      _hint(_fits[next]!, icon: Icons.aspect_ratio_rounded);
    },
  );

  Future<void> _openExternal() async {
    player.pause();
    final at = await _playExternal(current!, at: player.state.position);
    if (at != null && at > Duration.zero) player.seek(at);
  }

  /// Episodes, subtitles and handing off to another app.
  List<Widget> _menus() {
    final hasSubtitles =
        (current?.subtitles.isNotEmpty ?? false) ||
        player.state.tracks.subtitle.any((t) => t.id != 'auto' && t.id != 'no');
    return [
      if (widget.episodes.length > 1)
        IconButton(
          tooltip: 'Episodes',
          icon: const Icon(Icons.video_library_outlined),
          onPressed: _openEpisodes,
        ),
      if (hasSubtitles)
        IconButton(
          tooltip: 'Subtitles · $subtitle',
          icon: Icon(
            subtitle == 'Off'
                ? Icons.subtitles_off_outlined
                : Icons.subtitles_outlined,
          ),
          onPressed: _openSubtitles,
        ),
      IconButton(
        tooltip: 'Open in another app',
        icon: const Icon(Icons.open_in_new_rounded),
        onPressed: current == null ? null : _openExternal,
      ),
    ];
  }

  Widget _titles({required bool tv}) {
    final title = episode.title;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          titleOf(widget.media),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: tv ? 14 : 12, color: Colors.white70),
        ),
        Text(
          'Episode ${epNumber(episode.number)}${title == null ? '' : ' · $title'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: tv ? 28 : 18,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        if (tv)
          Text(
            '$_sourceName${current == null ? '' : ' · ${current!.label}'}',
            style: const TextStyle(fontSize: 12, color: Colors.white54),
          ),
      ],
    );
  }

  /// The skip for the range being played, else a fixed jump forward.
  Widget _skipButton(Duration position) {
    final skip = Settings.skipMode == SkipMode.off
        ? null
        : session.activeSkip(position);
    return TextButton.icon(
      style: _onVideo(TextButton.styleFrom(foregroundColor: Colors.white)),
      onPressed: skip == null
          ? () => _seekBy(Settings.skipSeconds)
          : () => player.seek(skip.end),
      icon: const Icon(Icons.double_arrow_rounded),
      label: Text(
        skip == null
            ? '+${Settings.skipSeconds}s'
            : 'Skip ${_skipName(skip.type)}',
      ),
    );
  }

  /// The position, the seek bar and the length.
  Widget _timeline(Duration position) {
    final duration = player.state.duration;
    final shown = seekTarget ?? position;
    const tabular = TextStyle(
      color: Colors.white,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return Row(
      children: [
        Text(formatDuration(shown), style: tabular),
        Expanded(child: ExcludeFocus(child: _seekBar(shown, duration))),
        Text(formatDuration(duration), style: tabular),
      ],
    );
  }

  /// TV: the title at the top, and along the bottom the seek bar (which takes focus: left/right on it scrub) and a
  /// row of buttons that turn solid when focused. No lock or gestures, which are for touch.
  Widget _tvOverlay(Duration position, bool loading) => Padding(
    padding: const EdgeInsets.fromLTRB(tvMargin, 24, tvMargin, 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _titles(tv: true),
        const Spacer(),
        Focus(
          onKeyEvent: (_, event) {
            final key = event.logicalKey;
            if (event is KeyUpEvent ||
                (key != LogicalKeyboardKey.arrowLeft &&
                    key != LogicalKeyboardKey.arrowRight)) {
              return KeyEventResult
                  .ignored; // releases land the scrub in _onKey
            }
            _scheduleHide();
            _scrub(event);
            return KeyEventResult.handled;
          },
          child: Builder(
            builder: (context) {
              final focused = Focus.of(context).hasPrimaryFocus;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  color: focused ? Colors.white12 : Colors.transparent,
                ),
                child: _timeline(position),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            loading
                ? const SizedBox(width: 56, height: 56)
                : _RoundButton(
                    player.state.playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    () {
                      player.playOrPause();
                      _scheduleHide();
                    },
                    tooltip: player.state.playing ? 'Pause' : 'Play',
                    focusNode: _playFocus,
                  ),
            const SizedBox(width: 8),
            if (index > 0)
              _RoundButton(
                Icons.skip_previous_rounded,
                () => _load(index - 1),
                tooltip: 'Previous episode',
              ),
            if (hasNext)
              _RoundButton(
                Icons.skip_next_rounded,
                () => _load(index + 1),
                tooltip: 'Next episode',
              ),
            const SizedBox(width: 8),
            _skipButton(position),
            const Spacer(),
            ?_serverButton(),
            _speedButton(),
            _fitButton(),
            ..._menus(),
          ],
        ),
      ],
    ),
  );

  Widget _overlay(Duration position, bool loading) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () => Navigator.pop(context),
              ),
              const SizedBox(width: 4),
              Expanded(child: _titles(tv: false)),
              ..._menus(),
            ],
          ),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _RoundButton(
                Icons.skip_previous_rounded,
                index > 0 ? () => _load(index - 1) : null,
                tooltip: 'Previous episode',
              ),
              const SizedBox(width: 32),
              _RoundButton(
                _replayIcon,
                () => _seekBy(-Settings.seekSeconds),
                tooltip: 'Back ${Settings.seekSeconds}s',
              ),
              const SizedBox(width: 32),
              loading
                  ? const SizedBox(width: 80, height: 80)
                  : _RoundButton(
                      player.state.playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      () {
                        player.playOrPause();
                        _scheduleHide();
                      },
                      tooltip: player.state.playing ? 'Pause' : 'Play',
                      big: true,
                      focusNode: _playFocus,
                    ),
              const SizedBox(width: 32),
              _RoundButton(
                _forwardIcon,
                () => _seekBy(Settings.seekSeconds),
                tooltip: 'Forward ${Settings.seekSeconds}s',
              ),
              const SizedBox(width: 32),
              _RoundButton(
                Icons.skip_next_rounded,
                hasNext ? () => _load(index + 1) : null,
                tooltip: 'Next episode',
              ),
            ],
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: _timeline(position),
          ),
          Row(
            children: [
              IconButton(
                tooltip: 'Lock controls',
                icon: const Icon(Icons.lock_open_rounded),
                onPressed: () => setState(() => locked = true),
              ),
              _skipButton(position),
              if (hasNext)
                TextButton.icon(
                  style: _onVideo(
                    TextButton.styleFrom(foregroundColor: Colors.white),
                  ),
                  onPressed: () => _load(index + 1),
                  icon: const Icon(Icons.skip_next_rounded),
                  label: const Text('Next episode'),
                ),
              const Spacer(),
              ?_serverButton(),
              _speedButton(),
              _fitButton(),
            ],
          ),
        ],
      ),
    ),
  );

  /// A slider with the intro (amber) and outro (sky) ranges drawn over its track.
  Widget _seekBar(Duration shown, Duration duration) => LayoutBuilder(
    builder: (context, constraints) {
      final max = duration.inMilliseconds.toDouble().clamp(
        1.0,
        double.infinity,
      );
      const inset = 16.0; // the slider insets its track by the overlay radius
      final track = constraints.maxWidth - inset * 2;
      double fraction(Duration d) =>
          (d.inMilliseconds / duration.inMilliseconds)
              .clamp(0.0, 1.0)
              .toDouble();
      return Stack(
        alignment: Alignment.centerLeft,
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              activeTrackColor: Theme.of(context).colorScheme.primary,
              thumbColor: Colors.white,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: inset),
              secondaryActiveTrackColor: Colors.white38,
              inactiveTrackColor: Colors.white24,
            ),
            child: Slider(
              max: max,
              value: shown.inMilliseconds.toDouble().clamp(0, max),
              secondaryTrackValue: player.state.buffer.inMilliseconds
                  .toDouble()
                  .clamp(0, max),
              onChangeStart: (_) => _hideTimer?.cancel(),
              onChanged: (v) => setState(
                () => seekTarget = Duration(milliseconds: v.round()),
              ),
              onChangeEnd: (v) {
                player.seek(Duration(milliseconds: v.round()));
                seekTarget = null;
                _scheduleHide();
              },
            ),
          ),
          if (duration > Duration.zero)
            for (final s in skips.where((s) => s.type != SkipType.recap))
              Positioned(
                left: inset + track * fraction(s.start),
                width: track * (fraction(s.end) - fraction(s.start)),
                child: IgnorePointer(
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color:
                          (s.type == SkipType.intro
                                  ? const Color(0xFFFFC857)
                                  : const Color(0xFF7DD3FC))
                              .withValues(alpha: .9),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
        ],
      );
    },
  );

  Widget _errorView() {
    final challenge = error is CloudflareChallenge;
    return ColoredBox(
      color: Colors.black87,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 48,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              const Text(
                "Couldn't play this episode",
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                friendlyError(error!),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Back'),
                  ),
                  FilledButton(
                    autofocus: isTv,
                    onPressed: () => _load(index),
                    child: Text(challenge ? 'Verify' : 'Try again'),
                  ),
                  if (hasNext)
                    FilledButton.tonal(
                      onPressed: () => _load(index + 1),
                      child: const Text('Next episode'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The episodes in the order chosen on the details page (a shared setting), with a jump-to-number field for long
/// shows. Opens on the one playing.
class _EpisodeList extends StatefulWidget {
  const _EpisodeList({
    required this.episodes,
    required this.current,
    required this.media,
    required this.dub,
    required this.online,
    required this.onSelect,
  });

  final List<Episode> episodes;
  final int current;
  final Map media;

  /// The audio playing, and whether the site can be reached: which downloads would play (see [Downloads.toPlay]).
  final bool dub, online;
  final ValueChanged<int> onSelect;

  @override
  State<_EpisodeList> createState() => _EpisodeListState();
}

class _EpisodeListState extends State<_EpisodeList> {
  static const _extent = 88.0;
  static const _jumpAt = 50; // shorter lists are quick to scroll
  bool newestFirst = Settings.newestFirst;
  late final scroll = ScrollController(
    initialScrollOffset: _offsetOf(widget.current),
  );

  /// Row of episode [i] in the current order.
  int _row(int i) => newestFirst ? widget.episodes.length - 1 - i : i;

  double _offsetOf(int i) =>
      ((_row(i) - 1) * _extent).clamp(0, double.infinity).toDouble();

  void _jump(String text) {
    final number = num.tryParse(text.trim());
    if (number == null) return;
    final i = widget.episodes.indexWhere((e) => e.number >= number);
    scroll.animateTo(
      _offsetOf(i == -1 ? widget.episodes.length - 1 : i),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final episodes = widget.episodes;
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final progress = Show(widget.media).progress;
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Episodes · ${episodes.length}',
                    style: text.titleLarge,
                  ),
                ),
                if (episodes.length > _jumpAt)
                  SizedBox(
                    width: 112,
                    child: TextField(
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.go,
                      onSubmitted: _jump,
                      decoration: const InputDecoration(
                        hintText: 'Go to EP',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                IconButton(
                  tooltip: newestFirst ? 'Newest first' : 'Oldest first',
                  icon: const Icon(Icons.swap_vert_rounded),
                  onPressed: () {
                    setState(
                      () => Settings.newestFirst = newestFirst = !newestFirst,
                    );
                    scroll.jumpTo(_offsetOf(widget.current));
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: scroll,
              padding: const EdgeInsets.only(bottom: 16),
              itemCount: episodes.length,
              itemExtent: _extent,
              itemBuilder: (context, row) {
                final i = _row(row);
                final e = episodes[i];
                final playing = i == widget.current;
                return ListTile(
                  autofocus: isTv && playing,
                  selected: playing,
                  selectedTileColor: colors.secondaryContainer.withValues(
                    alpha: .5,
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  onTap: () => widget.onSelect(i),
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 112,
                      child: AspectRatio(
                        aspectRatio: 16 / 9,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Artwork(
                              e.thumbnail,
                              placeholder: Center(
                                child: Text(
                                  epNumber(e.number),
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                            if (playing)
                              const ColoredBox(
                                color: Color(0x88000000),
                                child: Icon(
                                  Icons.graphic_eq_rounded,
                                  color: Colors.white,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  title: Text('Episode ${epNumber(e.number)}'),
                  subtitle: e.title == null
                      ? null
                      : Text(
                          e.title!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (Downloads.instance.toPlay(
                            widget.media,
                            e.number,
                            dub: widget.dub,
                            online: widget.online,
                          ) !=
                          null)
                        const Icon(Icons.download_done_rounded, size: 18),
                      if (EpisodePlan.isWatched(e, progress))
                        const Padding(
                          padding: EdgeInsets.only(left: 8),
                          child: Icon(Icons.check_circle_rounded, size: 18),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

String _skipName(SkipType type) => switch (type) {
  SkipType.intro => 'intro',
  SkipType.outro => 'outro',
  SkipType.recap => 'recap',
};

/// A round transport control: translucent on video, solid when focused on TV (from the theme).
class _RoundButton extends StatelessWidget {
  const _RoundButton(
    this.icon,
    this.onPressed, {
    required this.tooltip,
    this.big = false,
    this.focusNode,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String tooltip;
  final bool big;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    focusNode: focusNode,
    iconSize: big ? 48 : 30,
    padding: EdgeInsets.all(big ? 16 : 8),
    style: _onVideo(
      IconButton.styleFrom(
        backgroundColor: Colors.white.withValues(alpha: big ? .18 : .1),
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white24,
      ),
    ),
    icon: Icon(icon),
  );
}

/// [base] for controls over video; on TV it still turns solid white with dark content when focused.
ButtonStyle _onVideo(ButtonStyle base) {
  if (!isTv) return base;
  bool focused(Set<WidgetState> s) => s.contains(WidgetState.focused);
  return base.copyWith(
    backgroundColor: WidgetStateProperty.resolveWith(
      (s) => focused(s) ? Colors.white : base.backgroundColor?.resolve(s),
    ),
    foregroundColor: WidgetStateProperty.resolveWith(
      (s) => focused(s) ? Colors.black : base.foregroundColor?.resolve(s),
    ),
    iconColor: WidgetStateProperty.resolveWith(
      (s) => focused(s) ? Colors.black : base.iconColor?.resolve(s),
    ),
    overlayColor: WidgetStateProperty.resolveWith(
      (s) => focused(s) ? Colors.transparent : base.overlayColor?.resolve(s),
    ),
  );
}

String formatDuration(Duration d) {
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final m = d.inMinutes.remainder(60);
  return d.inHours > 0
      ? '${d.inHours}:${m.toString().padLeft(2, '0')}:$s'
      : '$m:$s';
}

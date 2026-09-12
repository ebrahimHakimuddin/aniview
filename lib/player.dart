import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';

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

/// Full-screen player with Dantotsu-style gestures: double-tap seek, swipe seek, brightness (left) /
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
    this.start,
  });

  final Map media;
  final Source?
  source; // null when playing downloads while the site is unreachable
  final String? sourceName;
  final List<Episode> episodes;
  final int index;
  final bool dub;
  final Duration? start; // resume point for the first episode

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final player = Player();
  late final controller = VideoController(player);
  final _scaffold = GlobalKey<ScaffoldState>();
  late int index = widget.index;
  List<VideoStream> streams = [];
  VideoStream? current;
  List<SkipTime> skips = [];
  final _autoSkipped = <SkipTime>{};
  int? _skipsRequested;
  String subtitle = 'Auto';
  Object? error;
  String? hint;
  IconData? hintIcon;
  bool controls = true, locked = false, cover = false, synced = false;
  double rate = Settings.speed, brightness = .5, volume = 1, doubleTapX = 0;
  // The phone's media volume as 0–1.
  static const _systemVolume = MethodChannel('aniview/volume');
  Duration? seekTarget;
  Duration? _startAt; // where the current server was asked to start
  Timer? _hideTimer, _hintTimer;
  Duration _savedAt = Duration.zero;
  late final List<StreamSubscription> _subs;

  Episode get episode => widget.episodes[index];
  bool get hasNext => index + 1 < widget.episodes.length;
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
    ScreenBrightness().application.then((v) => brightness = v).ignore();
    _subs = [
      player.stream.position.listen(_onPosition),
      player.stream.duration.listen(_onDuration),
      player.stream.playing.listen((_) => _refresh()),
      player.stream.buffering.listen((_) => _refresh()),
      player.stream.tracks.listen((_) => _refresh()),
      // A stream that never loads would otherwise spin on "Loading video…" forever.
      player.stream.error.listen((e) {
        if (!mounted ||
            current == null ||
            player.state.duration != Duration.zero) {
          return;
        }
        // Aggregated sources often list dead servers; move on before giving up.
        final next = streams.indexOf(current!) + 1;
        if (next > 0 && next < streams.length) {
          _hint(
            '${current!.label} failed · trying ${streams[next].label}',
            icon: Icons.dns_rounded,
          );
          _play(streams[next], at: _startAt);
        } else {
          setState(() => error = Exception(e));
        }
      }),
      player.stream.completed.listen((done) {
        if (done && hasNext && Settings.autoNext) _load(index + 1);
      }),
    ];
    _load(index, at: widget.start);
    _scheduleHide();
  }

  @override
  void dispose() {
    _saveHistory();
    for (final sub in _subs) {
      sub.cancel();
    }
    _hideTimer?.cancel();
    _hintTimer?.cancel();
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
    setState(() {
      index = i;
      streams = [];
      current = null;
      error = null;
      synced = false;
      skips = [];
      _autoSkipped.clear();
      _skipsRequested = null;
    });
    try {
      final target = widget.episodes[i];
      final source = widget.source;
      // A download wins even when online; match the audio unless the site can't be reached anyway.
      final offline = Downloads.instance.find(
        widget.media,
        target.number,
        dub: source == null ? null : widget.dub,
      );
      final List<VideoStream> found;
      if (offline != null) {
        found = [Downloads.instance.streamFor(offline)];
      } else if (source == null) {
        throw Exception(
          "Episode ${epNumber(target.number)} isn't downloaded and $_sourceName can't be reached",
        );
      } else {
        found = await withCloudflare(
          context,
          () => source.streams(widget.media, target, dub: widget.dub),
        );
      }
      if (!mounted || index != i) return;
      if (found.isEmpty) {
        throw Exception(
          'No ${widget.dub ? 'dub' : 'sub'} servers for this episode on $_sourceName',
        );
      }
      streams = found;
      await _play(found.first, at: at);
    } catch (e) {
      if (mounted && index == i) setState(() => error = e);
    }
  }

  Future<void> _play(VideoStream stream, {Duration? at}) async {
    _startAt = at;
    setState(() {
      current = stream;
      if (skips.isEmpty) skips = stream.skips;
    });
    await player.open(
      // HLS goes through the local proxy; direct files (mp4) get their headers from mpv itself.
      Media(
        stream.isLocal || !stream.isHls
            ? stream.url
            : await HlsProxy.url(stream.url, stream.headers),
        httpHeaders: stream.isHls ? null : stream.headers,
      ),
    );
    // open() returns before mpv has loaded the file, and seeking or adding a subtitle track before that is dropped.
    if (player.state.duration == Duration.zero) {
      await player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 20), onTimeout: () => Duration.zero);
    }
    if (!mounted || current != stream) return;
    if (at != null && at > Duration.zero) await player.seek(at);
    await _applySubtitle(stream);
    await player.setRate(rate);
  }

  Future<void> _applySubtitle(VideoStream stream) async {
    final language = Settings.subtitleLanguage;
    if (language == 'Off') return _setSubtitle(SubtitleTrack.no(), 'Off');
    Subtitle? byLanguage(String l) =>
        stream.subtitles.where((s) => s.label.startsWith(l)).firstOrNull;
    final pick =
        byLanguage(language) ??
        byLanguage('English') ??
        stream.subtitles.firstOrNull;
    if (pick == null) {
      return _setSubtitle(
        SubtitleTrack.auto(),
        'Auto',
      ); // embedded or burned-in subs
    }
    return _setExternal(stream, pick);
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
    final duration = player.state.duration;
    if (!synced &&
        duration > Duration.zero &&
        position.inMilliseconds >
            duration.inMilliseconds * Settings.watchedPercent / 100) {
      synced = true;
      _syncProgress();
    }
    if (Settings.skipMode == SkipMode.auto) {
      final skip = _activeSkip(position);
      if (skip != null && _autoSkipped.add(skip)) {
        player.seek(skip.end);
        _hint('Skipped ${_skipName(skip.type)}');
      }
    }
    if ((position - _savedAt).abs() >= const Duration(seconds: 10)) {
      _savedAt = position;
      _saveHistory();
    }
    _refresh();
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
        setState(() => skips = found);
      }
    });
  }

  SkipTime? _activeSkip(Duration position) =>
      skips.where((s) => s.contains(position)).firstOrNull;

  void _saveHistory() {
    final position = player.state.position, duration = player.state.duration;
    if (current == null || position < const Duration(seconds: 5)) return;
    final finished =
        duration > Duration.zero &&
        position.inMilliseconds >
            duration.inMilliseconds * Settings.watchedPercent / 100;
    if (finished && !hasNext) {
      WatchHistory.remove(widget.media);
    } else {
      WatchHistory.save(
        widget.media,
        source: _sourceName,
        episode: finished ? widget.episodes[index + 1].number : episode.number,
        position: finished ? Duration.zero : position,
        dub: widget.dub,
      );
    }
  }

  Future<void> _syncProgress() async {
    final number = episode.number.toInt();
    final entry = widget.media['mediaListEntry'] as Map?;
    if (!Tracker.signedIn || !Settings.syncAniList) return;
    if (number > (entry?['progress'] as int? ?? 0)) {
      widget.media['mediaListEntry'] = {
        ...?entry,
        'progress': number,
        'status': entry?['status'] ?? 'CURRENT',
      };
    }
    try {
      // Ask the tracker itself: cached media (e.g. from resume history) may be behind and must not roll progress back.
      if (number > await Tracker.progressOf(widget.media)) {
        await Tracker.saveProgress(widget.media, number);
        _hint(
          'Progress updated · Episode $number',
          icon: Icons.check_circle_rounded,
        );
      }
      Tracker.syncPending().ignore();
    } catch (_) {
      await Tracker.queueProgress(widget.media, number);
      _hint(
        'Saved offline · syncs when you’re back online',
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

  Duration _clamp(Duration t) {
    final duration = player.state.duration;
    if (t < Duration.zero) return Duration.zero;
    return duration > Duration.zero && t > duration ? duration : t;
  }

  void _seekBy(int seconds) {
    player.seek(_clamp(player.state.position + Duration(seconds: seconds)));
    _hint(seconds > 0 ? '+${seconds}s' : '${seconds}s');
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
      _systemVolume.invokeMethod('set', volume).ignore();
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

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final position = player.state.position;
    final skip = Settings.skipMode == SkipMode.button
        ? _activeSkip(position)
        : null;
    final loading =
        error == null && (current == null || player.state.buffering);

    return Scaffold(
      key: _scaffold,
      backgroundColor: Colors.black,
      endDrawerEnableOpenDragGesture: false, // horizontal swipes seek
      endDrawer: _EpisodeDrawer(
        episodes: widget.episodes,
        current: index,
        media: widget.media,
        onSelect: (i) {
          _scaffold.currentState?.closeEndDrawer();
          if (i != index) _load(i);
        },
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Video(
            controller: controller,
            controls: NoVideoControls,
            fit: cover ? BoxFit.cover : BoxFit.contain,
            subtitleViewConfiguration: SubtitleViewConfiguration(
              // media_kit otherwise shrinks text relative to a 1920×1080 view, making it tiny on phones.
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                fontSize: Settings.subtitleSize,
                color: Colors.white,
                shadows: const [Shadow(blurRadius: 8), Shadow(blurRadius: 2)],
              ),
            ),
          ),
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
                      Color(0xCC000000),
                      Color(0x33000000),
                      Color(0x33000000),
                      Color(0xDD000000),
                    ],
                    stops: [0, .3, .65, 1],
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
                    player.setRate(2);
                    _hint('2× speed', sticky: true);
                  },
            onLongPressEnd: locked
                ? null
                : (_) {
                    player.setRate(rate);
                    _clearHint();
                  },
            onVerticalDragStart: locked
                ? null
                : (_) => _systemVolume
                      .invokeMethod<double>(
                        'get',
                      ) // may have changed with the volume keys
                      .then((v) => volume = v ?? volume)
                      .ignore(),
            onVerticalDragUpdate: locked ? null : (d) => _verticalDrag(d, size),
            onVerticalDragEnd: locked ? null : _clearHint,
            onHorizontalDragStart: locked
                ? null
                : (_) => seekTarget = player.state.position,
            onHorizontalDragUpdate: locked
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
            onHorizontalDragEnd: locked
                ? null
                : (_) {
                    player.seek(seekTarget!);
                    seekTarget = null;
                    _clearHint();
                  },
          ),
          if (loading)
            IgnorePointer(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: Colors.white),
                    const SizedBox(height: 16),
                    Text(
                      current == null
                          ? 'Finding servers on $_sourceName…'
                          : 'Loading video…',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
          if (hint != null)
            IgnorePointer(
              child: Align(
                alignment: const Alignment(0, -.62),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .7),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (hintIcon != null) ...[
                        Icon(hintIcon, size: 20),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        hint!,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          IgnorePointer(
            ignoring: !controls,
            child: AnimatedOpacity(
              opacity: controls ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: locked ? _lockedOverlay() : _overlay(position, loading),
            ),
          ),
          if (skip != null &&
              !locked &&
              !controls) // the controls have their own
            Positioned(
              right: 32,
              bottom: 110,
              child: FilledButton.icon(
                onPressed: () => player.seek(skip.end),
                icon: const Icon(Icons.fast_forward_rounded),
                label: Text('Skip ${_skipName(skip.type)}'),
              ),
            ),
          if (error != null) _errorView(),
        ],
      ),
    );
  }

  Widget _lockedOverlay() => SafeArea(
    child: Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: IconButton.filledTonal(
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

  Widget _overlay(Duration position, bool loading) {
    final skip = Settings.skipMode == SkipMode.off
        ? null
        : _activeSkip(position);
    final duration = player.state.duration;
    final shown = seekTarget ?? position;
    final max = duration.inMilliseconds.toDouble().clamp(1.0, double.infinity);
    final title = episode.title;
    final external = current?.subtitles ?? const <Subtitle>[];
    final embedded = player.state.tracks.subtitle
        .where(
          (t) =>
              t.id != 'auto' &&
              t.id != 'no' &&
              !external.any((s) => s.label == t.title),
        )
        .toList();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: () => Navigator.pop(context),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Episode ${epNumber(episode.number)}${title == null ? '' : ' · $title'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '${titleOf(widget.media)} · $_sourceName${current == null ? '' : ' · ${current!.label}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.episodes.length > 1)
                  IconButton(
                    tooltip: 'Episodes',
                    icon: const Icon(Icons.video_library_rounded),
                    onPressed: () => _scaffold.currentState?.openEndDrawer(),
                  ),
                if (streams.isNotEmpty && streams.contains(current))
                  DropdownButtonHideUnderline(
                    child: DropdownButton<VideoStream>(
                      value: current,
                      icon: const Icon(Icons.arrow_drop_down_rounded),
                      dropdownColor: const Color(0xF2101016),
                      borderRadius: BorderRadius.circular(12),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                      items: [
                        for (final s in streams)
                          DropdownMenuItem(value: s, child: Text(s.label)),
                      ],
                      onChanged: (s) => s == null || s == current
                          ? null
                          : _play(s, at: player.state.position),
                    ),
                  ),
                if (external.isNotEmpty || embedded.isNotEmpty)
                  PopupMenuButton<Object>(
                    tooltip: 'Subtitles',
                    icon: Icon(
                      subtitle == 'Off'
                          ? Icons.subtitles_off_outlined
                          : Icons.subtitles_rounded,
                    ),
                    onSelected: (value) => switch (value) {
                      Subtitle s => _setExternal(current!, s),
                      SubtitleTrack t => _setSubtitle(
                        t,
                        t.title ?? t.language ?? 'Track ${t.id}',
                      ),
                      _ => _setSubtitle(SubtitleTrack.no(), 'Off'),
                    },
                    itemBuilder: (_) => [
                      _checked('Off', subtitle == 'Off', 'off'),
                      for (final s in external)
                        _checked(s.label, subtitle == s.label, s),
                      for (final t in embedded)
                        _checked(
                          t.title ?? t.language ?? 'Track ${t.id}',
                          subtitle == (t.title ?? t.language),
                          t,
                        ),
                    ],
                  ),
                PopupMenuButton<double>(
                  tooltip: 'Speed',
                  icon: const Icon(Icons.speed_rounded),
                  onSelected: (r) {
                    setState(() => rate = r);
                    player.setRate(r);
                  },
                  itemBuilder: (_) => [
                    for (final r in const [.5, .75, 1.0, 1.25, 1.5, 1.75, 2.0])
                      _checked('$r×', r == rate, r),
                  ],
                ),
                IconButton(
                  tooltip: cover ? 'Fit' : 'Fill',
                  icon: Icon(
                    cover ? Icons.fit_screen_rounded : Icons.crop_free_rounded,
                  ),
                  onPressed: () => setState(() => cover = !cover),
                ),
              ],
            ),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _RoundButton(
                  Icons.skip_previous_rounded,
                  index > 0 ? () => _load(index - 1) : null,
                ),
                const SizedBox(width: 28),
                _RoundButton(_replayIcon, () => _seekBy(-Settings.seekSeconds)),
                const SizedBox(width: 28),
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
                        big: true,
                      ),
                const SizedBox(width: 28),
                _RoundButton(_forwardIcon, () => _seekBy(Settings.seekSeconds)),
                const SizedBox(width: 28),
                _RoundButton(
                  Icons.skip_next_rounded,
                  hasNext ? () => _load(index + 1) : null,
                ),
              ],
            ),
            const Spacer(),
            Row(
              children: [
                Text(
                  formatDuration(shown),
                  style: const TextStyle(
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                Expanded(child: _seekBar(shown, duration, max)),
                Text(
                  formatDuration(duration),
                  style: const TextStyle(
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            Row(
              children: [
                IconButton(
                  tooltip: 'Lock',
                  icon: const Icon(Icons.lock_open_rounded),
                  onPressed: () => setState(() => locked = true),
                ),
                // AniSkip's range when we're inside one, otherwise a fixed jump.
                TextButton.icon(
                  onPressed: skip == null
                      ? () => _seekBy(Settings.skipSeconds)
                      : () => player.seek(skip.end),
                  icon: const Icon(Icons.double_arrow_rounded),
                  label: Text(
                    skip == null
                        ? '+${Settings.skipSeconds}s'
                        : 'Skip ${_skipName(skip.type)}',
                  ),
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                ),
                const Spacer(),
                if (hasNext)
                  FilledButton.tonalIcon(
                    onPressed: () => _load(index + 1),
                    icon: const Icon(Icons.skip_next_rounded),
                    label: const Text('Next episode'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Slider with the intro (amber) and outro (sky) ranges drawn over its track.
  Widget _seekBar(
    Duration shown,
    Duration duration,
    double max,
  ) => LayoutBuilder(
    builder: (context, constraints) {
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
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: inset),
              secondaryActiveTrackColor: Colors.white38,
              inactiveTrackColor: Colors.white12,
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
                    height: 5,
                    decoration: BoxDecoration(
                      color:
                          (s.type == SkipType.intro
                                  ? const Color(0xFFFFC857)
                                  : const Color(0xFF7DD3FC))
                              .withValues(alpha: .85),
                      borderRadius: BorderRadius.circular(3),
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
              const Icon(
                Icons.error_outline_rounded,
                size: 40,
                color: Color(0xFFFF8A8E),
              ),
              const SizedBox(height: 12),
              const Text(
                "Couldn't play this episode",
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                friendlyError(error!),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Back'),
                  ),
                  FilledButton(
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

class _EpisodeDrawer extends StatelessWidget {
  const _EpisodeDrawer({
    required this.episodes,
    required this.current,
    required this.media,
    required this.onSelect,
  });

  final List<Episode> episodes;
  final int current;
  final Map media;
  final ValueChanged<int> onSelect;

  static const _extent = 84.0;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final progress = media['mediaListEntry']?['progress'] as int? ?? 0;
    return Drawer(
      width: 400,
      backgroundColor: const Color(0xF2101016),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                'Episodes · ${episodes.length}',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: ScrollController(
                  initialScrollOffset: ((current - 1) * _extent).clamp(
                    0,
                    double.infinity,
                  ),
                ),
                padding: const EdgeInsets.only(bottom: 16),
                itemCount: episodes.length,
                itemExtent: _extent,
                itemBuilder: (context, i) {
                  final e = episodes[i];
                  final playing = i == current;
                  return InkWell(
                    onTap: () => onSelect(i),
                    child: Container(
                      color: playing ? primary.withValues(alpha: .14) : null,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox(
                              width: 120,
                              height: 68,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  ColoredBox(
                                    color: Colors.white.withValues(alpha: .06),
                                    child: Center(
                                      child: Text(
                                        epNumber(e.number),
                                        style: const TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.w800,
                                          color: Colors.white24,
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (e.thumbnail != null)
                                    Image.network(
                                      e.thumbnail!,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) =>
                                          const SizedBox(),
                                    ),
                                  if (playing)
                                    const ColoredBox(
                                      color: Color(0x88000000),
                                      child: Center(
                                        child: Icon(Icons.graphic_eq_rounded),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  'Episode ${epNumber(e.number)}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: playing ? primary : null,
                                  ),
                                ),
                                if (e.title != null)
                                  Text(
                                    e.title!,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.white60,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (Downloads.instance.find(media, e.number) != null)
                            const Padding(
                              padding: EdgeInsets.only(left: 8),
                              child: Icon(
                                Icons.download_done_rounded,
                                size: 18,
                                color: Colors.white54,
                              ),
                            ),
                          if (e.number <= progress)
                            const Padding(
                              padding: EdgeInsets.only(left: 8),
                              child: Icon(
                                Icons.check_circle_rounded,
                                size: 18,
                                color: Colors.white38,
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

PopupMenuItem<T> _checked<T>(String label, bool selected, T value) =>
    PopupMenuItem<T>(
      value: value,
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: selected ? const Icon(Icons.check_rounded, size: 18) : null,
          ),
          const SizedBox(width: 8),
          Flexible(child: Text(label)),
        ],
      ),
    );

String _skipName(SkipType type) => switch (type) {
  SkipType.intro => 'intro',
  SkipType.outro => 'outro',
  SkipType.recap => 'recap',
};

class _RoundButton extends StatelessWidget {
  const _RoundButton(this.icon, this.onPressed, {this.big = false});

  final IconData icon;
  final VoidCallback? onPressed;
  final bool big;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onPressed,
    iconSize: big ? 48 : 28,
    padding: EdgeInsets.all(big ? 16 : 10),
    style: IconButton.styleFrom(
      backgroundColor: Colors.white.withValues(alpha: big ? .16 : .08),
      foregroundColor: Colors.white,
      disabledForegroundColor: Colors.white24,
    ),
    icon: Icon(icon),
  );
}

String formatDuration(Duration d) {
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final m = d.inMinutes.remainder(60);
  return d.inHours > 0
      ? '${d.inHours}:${m.toString().padLeft(2, '0')}:$s'
      : '$m:$s';
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';

import 'anilist.dart';
import 'cloudflare.dart';
import 'history.dart';
import 'hls_proxy.dart';
import 'metadata.dart';
import 'settings.dart';
import 'sources.dart';
import 'states.dart';

/// Full-screen player with Dantotsu-style gestures: double-tap seek, swipe seek,
/// brightness (left) / volume (right) swipes, hold for 2×, lock, server/subtitle/speed pickers, AniSkip.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.media,
    required this.source,
    required this.episodes,
    required this.index,
    required this.dub,
    this.start,
  });

  final Map media;
  final Source source;
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
  late int index = widget.index;
  List<VideoStream> streams = [];
  VideoStream? current;
  List<SkipTime> skips = [];
  final _autoSkipped = <SkipTime>{};
  int? _skipsRequested;
  String subtitle = 'Auto';
  Object? error;
  String? hint;
  bool controls = true, locked = false, cover = false, synced = false;
  double rate = Settings.speed, brightness = .5, volume = 100, doubleTapX = 0;
  Duration? seekTarget;
  Timer? _hideTimer, _hintTimer;
  Duration _savedAt = Duration.zero;
  late final List<StreamSubscription> _subs;

  Episode get episode => widget.episodes[index];
  bool get hasNext => index + 1 < widget.episodes.length;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    ScreenBrightness().application.then((v) => brightness = v).ignore();
    _subs = [
      player.stream.position.listen(_onPosition),
      player.stream.duration.listen(_onDuration),
      player.stream.playing.listen((_) => _refresh()),
      player.stream.buffering.listen((_) => _refresh()),
      player.stream.tracks.listen((_) => _refresh()),
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
      final found = await withCloudflare(
        context,
        () => widget.source.streams(widget.media, widget.episodes[i], dub: widget.dub),
      );
      if (!mounted || index != i) return;
      if (found.isEmpty) {
        throw Exception('No ${widget.dub ? 'dub' : 'sub'} servers for this episode on ${widget.source.name}');
      }
      streams = found;
      await _play(found.first, at: at);
    } catch (e) {
      if (mounted && index == i) setState(() => error = e);
    }
  }

  Future<void> _play(VideoStream stream, {Duration? at}) async {
    setState(() {
      current = stream;
      if (skips.isEmpty) skips = stream.skips;
    });
    await player.open(Media(await HlsProxy.url(stream.url, stream.headers)));
    if (at != null && at > Duration.zero) await player.seek(at);
    await _applySubtitle(stream);
    await player.setRate(rate);
  }

  Future<void> _applySubtitle(VideoStream stream) async {
    final language = Settings.subtitleLanguage;
    if (language == 'Off') return _setSubtitle(SubtitleTrack.no(), 'Off');
    Subtitle? byLanguage(String l) => stream.subtitles.where((s) => s.label.startsWith(l)).firstOrNull;
    final pick = byLanguage(language) ?? byLanguage('English') ?? stream.subtitles.firstOrNull;
    if (pick == null) return _setSubtitle(SubtitleTrack.auto(), 'Auto'); // embedded or burned-in subs
    return _setSubtitle(SubtitleTrack.uri(pick.url, title: pick.label), pick.label);
  }

  Future<void> _setSubtitle(SubtitleTrack track, String label) async {
    await player.setSubtitleTrack(track);
    if (mounted) setState(() => subtitle = label);
  }

  void _onPosition(Duration position) {
    final duration = player.state.duration;
    if (!synced &&
        duration > Duration.zero &&
        position.inMilliseconds > duration.inMilliseconds * Settings.watchedPercent / 100) {
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
    if (duration <= Duration.zero || _skipsRequested == index || Settings.skipMode == SkipMode.off) return;
    final requested = _skipsRequested = index;
    aniSkip(widget.media['idMal'], episode.number, duration).then((found) {
      if (mounted && index == requested && found.isNotEmpty) setState(() => skips = found);
    });
  }

  SkipTime? _activeSkip(Duration position) => skips.where((s) => s.contains(position)).firstOrNull;

  void _saveHistory() {
    final position = player.state.position, duration = player.state.duration;
    if (current == null || position < const Duration(seconds: 5)) return;
    final finished = duration > Duration.zero && position.inMilliseconds > duration.inMilliseconds * .9;
    if (finished && !hasNext) {
      WatchHistory.remove(widget.media);
    } else {
      WatchHistory.save(
        widget.media,
        source: widget.source.name,
        episode: finished ? widget.episodes[index + 1].number : episode.number,
        position: finished ? Duration.zero : position,
        dub: widget.dub,
      );
    }
  }

  Future<void> _syncProgress() async {
    final number = episode.number.toInt();
    final entry = widget.media['mediaListEntry'] as Map?;
    if (AniList.token == null || !Settings.syncAniList) return;
    try {
      // Ask AniList itself: cached media (e.g. from resume history) may be behind and must not roll progress back.
      if (number <= await AniList.progressOf(widget.media['id'])) return;
      await AniList.saveProgress(widget.media, number);
      widget.media['mediaListEntry'] = {...?entry, 'progress': number, 'status': entry?['status'] ?? 'CURRENT'};
      _hint('✓  AniList updated · Episode $number');
    } catch (e) {
      _hint('AniList sync failed');
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

  void _hint(String text, {bool sticky = false}) {
    _hintTimer?.cancel();
    if (!mounted) return;
    setState(() => hint = text);
    if (!sticky) {
      _hintTimer = Timer(const Duration(milliseconds: 1200), () => mounted ? setState(() => hint = null) : null);
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
      _hint('☀  ${(brightness * 100).round()}%', sticky: true);
    } else {
      volume = (volume + delta * 100).clamp(0.0, 100.0);
      player.setVolume(volume);
      _hint('🔊  ${volume.round()}%', sticky: true);
    }
  }

  void _clearHint([Object? _]) => _hint(hint ?? '');

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
    final skip = Settings.skipMode == SkipMode.button ? _activeSkip(position) : null;
    final loading = error == null && (current == null || player.state.buffering);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Video(
            controller: controller,
            controls: NoVideoControls,
            fit: cover ? BoxFit.cover : BoxFit.contain,
            subtitleViewConfiguration: SubtitleViewConfiguration(
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
                    colors: [Color(0xCC000000), Color(0x33000000), Color(0x33000000), Color(0xDD000000)],
                    stops: [0, .3, .65, 1],
                  ),
                ),
              ),
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            onDoubleTapDown: locked ? null : (d) => doubleTapX = d.localPosition.dx,
            onDoubleTap: locked
                ? null
                : () => _seekBy(doubleTapX < size.width / 2 ? -Settings.seekSeconds : Settings.seekSeconds),
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
            onVerticalDragUpdate: locked ? null : (d) => _verticalDrag(d, size),
            onVerticalDragEnd: locked ? null : _clearHint,
            onHorizontalDragStart: locked ? null : (_) => seekTarget = player.state.position,
            onHorizontalDragUpdate: locked
                ? null
                : (d) {
                    seekTarget = _clamp(seekTarget! + Duration(milliseconds: (d.delta.dx * 250).round()));
                    final diff = (seekTarget! - position).inSeconds;
                    _hint('${formatDuration(seekTarget!)}  (${diff >= 0 ? '+' : ''}${diff}s)', sticky: true);
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
                      current == null ? 'Finding servers on ${widget.source.name}…' : 'Loading video…',
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
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  decoration: BoxDecoration(color: Colors.black.withValues(alpha: .7), borderRadius: BorderRadius.circular(24)),
                  child: Text(hint!, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
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
          if (skip != null && !locked)
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
    final duration = player.state.duration;
    final shown = seekTarget ?? position;
    final max = duration.inMilliseconds.toDouble().clamp(1.0, double.infinity);
    final title = episode.title;
    final external = current?.subtitles ?? const <Subtitle>[];
    final embedded = player.state.tracks.subtitle
        .where((t) => t.id != 'auto' && t.id != 'no' && !external.any((s) => s.label == t.title))
        .toList();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          children: [
            Row(
              children: [
                IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => Navigator.pop(context)),
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
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${titleOf(widget.media)} · ${widget.source.name}${current == null ? '' : ' · ${current!.label}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
                if (streams.length > 1)
                  PopupMenuButton<VideoStream>(
                    tooltip: 'Server',
                    icon: const Icon(Icons.dns_rounded),
                    onSelected: (s) => _play(s, at: player.state.position),
                    itemBuilder: (_) => [for (final s in streams) _checked(s.label, s == current, s)],
                  ),
                if (external.isNotEmpty || embedded.isNotEmpty)
                  PopupMenuButton<Object>(
                    tooltip: 'Subtitles',
                    icon: Icon(subtitle == 'Off' ? Icons.subtitles_off_outlined : Icons.subtitles_rounded),
                    onSelected: (value) => switch (value) {
                      Subtitle s => _setSubtitle(SubtitleTrack.uri(s.url, title: s.label), s.label),
                      SubtitleTrack t => _setSubtitle(t, t.title ?? t.language ?? 'Track ${t.id}'),
                      _ => _setSubtitle(SubtitleTrack.no(), 'Off'),
                    },
                    itemBuilder: (_) => [
                      _checked('Off', subtitle == 'Off', 'off'),
                      for (final s in external) _checked(s.label, subtitle == s.label, s),
                      for (final t in embedded)
                        _checked(t.title ?? t.language ?? 'Track ${t.id}', subtitle == (t.title ?? t.language), t),
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
                    for (final r in const [.5, .75, 1.0, 1.25, 1.5, 1.75, 2.0]) _checked('$r×', r == rate, r),
                  ],
                ),
                IconButton(
                  tooltip: cover ? 'Fit' : 'Fill',
                  icon: Icon(cover ? Icons.fit_screen_rounded : Icons.crop_free_rounded),
                  onPressed: () => setState(() => cover = !cover),
                ),
              ],
            ),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _RoundButton(Icons.skip_previous_rounded, index > 0 ? () => _load(index - 1) : null),
                const SizedBox(width: 28),
                _RoundButton(_replayIcon, () => _seekBy(-Settings.seekSeconds)),
                const SizedBox(width: 28),
                loading
                    ? const SizedBox(width: 80, height: 80)
                    : _RoundButton(
                        player.state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        () {
                          player.playOrPause();
                          _scheduleHide();
                        },
                        big: true,
                      ),
                const SizedBox(width: 28),
                _RoundButton(_forwardIcon, () => _seekBy(Settings.seekSeconds)),
                const SizedBox(width: 28),
                _RoundButton(Icons.skip_next_rounded, hasNext ? () => _load(index + 1) : null),
              ],
            ),
            const Spacer(),
            Row(
              children: [
                Text(formatDuration(shown), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                      secondaryActiveTrackColor: Colors.white38,
                      inactiveTrackColor: Colors.white12,
                    ),
                    child: Slider(
                      max: max,
                      value: shown.inMilliseconds.toDouble().clamp(0, max),
                      secondaryTrackValue: player.state.buffer.inMilliseconds.toDouble().clamp(0, max),
                      onChangeStart: (_) => _hideTimer?.cancel(),
                      onChanged: (v) => setState(() => seekTarget = Duration(milliseconds: v.round())),
                      onChangeEnd: (v) {
                        player.seek(Duration(milliseconds: v.round()));
                        seekTarget = null;
                        _scheduleHide();
                      },
                    ),
                  ),
                ),
                Text(formatDuration(duration), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
              ],
            ),
            Row(
              children: [
                IconButton(
                  tooltip: 'Lock',
                  icon: const Icon(Icons.lock_open_rounded),
                  onPressed: () => setState(() => locked = true),
                ),
                TextButton.icon(
                  onPressed: () => _seekBy(85),
                  icon: const Icon(Icons.double_arrow_rounded),
                  label: const Text('+85s'),
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
              const Icon(Icons.error_outline_rounded, size: 40, color: Color(0xFFFF8A8E)),
              const SizedBox(height: 12),
              const Text("Couldn't play this episode", style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(friendlyError(error!), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                children: [
                  OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Back')),
                  FilledButton(onPressed: () => _load(index), child: Text(challenge ? 'Verify' : 'Try again')),
                  if (hasNext) FilledButton.tonal(onPressed: () => _load(index + 1), child: const Text('Next episode')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

PopupMenuItem<T> _checked<T>(String label, bool selected, T value) => PopupMenuItem<T>(
      value: value,
      child: Row(
        children: [
          SizedBox(width: 24, child: selected ? const Icon(Icons.check_rounded, size: 18) : null),
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
  return d.inHours > 0 ? '${d.inHours}:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

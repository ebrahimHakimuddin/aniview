/// Keeps the player's Anime4K shaders matched to the video and the space it's shown in, and turns them down when
/// the device can't keep up. The shaders and when to run them are in upscale.dart.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'exo.dart';
import 'upscale.dart';

/// Puts a chain's shaders on disk and returns their paths; [installShaders] but in tests.
@visibleForTesting
Future<List<String>> Function(List<String> chain) installUpscaleShaders =
    installShaders;

/// What to run for a video [source] big shown in [box] (logical pixels) at [devicePixelRatio]: the shader files in
/// order, and the size to draw them at (null: the video's own).
///
/// No shaders past [restoreOnly] when [tier] is off or the video isn't shown big enough to upscale.
({List<String> chain, Size? target}) upscalePlan(
  Upscale tier, {
  required Size source,
  required Size box,
  required double devicePixelRatio,
  required bool mobile,
}) {
  final target = upscaleTarget(source, box, devicePixelRatio);
  if (tier == Upscale.off || !shouldUpscale(source, target)) {
    return (chain: restoreOnly(tier, mobile: mobile), target: null);
  }
  return (
    chain: shaderChain(
      tier,
      sourceHeight: source.height.round(),
      mobile: mobile,
    ),
    target: target,
  );
}

/// Says when upscaling drops too many frames to keep, from mpv's running counts read every few seconds.
///
/// mpv counts the frames it drops (`frame-drop-count`) but not the ones it shows, so those are estimated: the
/// video's frame rate times how far the position moved, less the drops.
class UpscaleWatchdog {
  UpscaleWatchdog({
    this.samples = 4,
    this.maxStep = const Duration(seconds: 5),
  });

  /// How many readings a decision spans: 4 readings 2 s apart cover 6 s.
  final int samples;

  /// A position that moves more than this between readings (or back) was a seek: the window starts over.
  final Duration maxStep;

  final _window = <({int dropped, Duration position})>[];

  /// Forgets the readings, after a pause, a seek, buffering or a change of shaders.
  void reset() => _window.clear();

  /// Takes a reading: the drop count so far, the position and the frame rate. True when, over the last [samples]
  /// readings, more than 10% of the frames were dropped ([tooSlow]); the window then starts over.
  bool sample({
    required int dropped,
    required Duration position,
    required double fps,
  }) {
    if (_window.isNotEmpty) {
      final last = _window.last;
      final step = position - last.position;
      // A new file restarts mpv's count; a seek moves the position by more than playing could.
      if (dropped < last.dropped || step.isNegative || step > maxStep) {
        reset();
      }
    }
    _window.add((dropped: dropped, position: position));
    if (_window.length < samples) return false;
    final first = _window.removeAt(0);
    final drops = dropped - first.dropped;
    final frames = (position - first.position).inMicroseconds / 1e6 * fps;
    final shown = (frames - drops).round().clamp(0, 1 << 31);
    if (!tooSlow(dropped: drops, shown: shown)) return false;
    reset();
    return true;
  }
}

/// The player's upscaling: picks the shaders on open, when the video's size becomes known and (after a pause of
/// [debounce]) when the space it's shown in changes; sends them only when they change. While it upscales, checks
/// the dropped frames every [pollEvery] and steps the tier down for this session when they're too many, telling
/// [onSlow].
class Upscaler {
  Upscaler(
    this.player, {
    required this._tier,
    required this.mobile,
    this.onSlow,
    this.debounce = const Duration(milliseconds: 300),
    this.pollEvery = const Duration(seconds: 2),
    UpscaleWatchdog? watchdog,
  }) : watchdog = watchdog ?? UpscaleWatchdog() {
    _subs = [
      // A loaded file: its duration arrives once it has opened.
      player.stream.duration.listen((d) {
        if (d > Duration.zero) apply();
      }),
      player.stream.size.listen((_) => _schedule()),
    ];
  }

  final ExoPlayer player;

  /// Phones get the short chains (see [shaderChain]).
  final bool mobile;

  /// Told the tier it stepped down to.
  final void Function(Upscale tier)? onSlow;
  final Duration debounce, pollEvery;
  final UpscaleWatchdog watchdog;

  late final List<StreamSubscription> _subs;
  Timer? _debounce, _poll;
  bool _disposed = false;
  bool _reading = false;

  /// What the player runs now: the chain and the size it draws at (and the video's size it was picked for, while
  /// that size matters). Empty at first: mpv starts every player with none.
  String _sent = '';
  int _generation = 0;

  Size? _box;
  double _ratio = 1;

  Upscale _tier;

  /// The tier for this session: the saved one, or lower once [onSlow] said so.
  Upscale get tier => _tier;

  /// Whether the shaders upscale now (not just restore, or nothing).
  bool get upscaling => _poll != null;

  /// The video shows in [box] (logical pixels) at [devicePixelRatio]; applied after [debounce], as a window being
  /// resized reports many sizes.
  void layout(Size box, double devicePixelRatio) {
    if (box == _box && devicePixelRatio == _ratio) return;
    _box = box;
    _ratio = devicePixelRatio;
    _schedule();
  }

  /// Picked in the player: applies at once.
  Future<void> setTier(Upscale tier) {
    _tier = tier;
    watchdog.reset();
    return apply();
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(debounce, apply);
  }

  /// Picks the shaders for now and sends them when they differ from what the player runs.
  Future<void> apply() async {
    _debounce?.cancel();
    final source = player.state.size, box = _box;
    if (_disposed || !player.supportsShaders || source == null || box == null) {
      return;
    }
    final plan = upscalePlan(
      _tier,
      source: source,
      box: box,
      devicePixelRatio: _ratio,
      mobile: mobile,
    );
    final key = plan.target == null
        ? plan.chain.join('|')
        : '${plan.chain.join('|')}@${plan.target}<$source';
    if (key == _sent) return;
    final generation = ++_generation;
    final List<String> paths;
    try {
      paths = await installUpscaleShaders(plan.chain);
    } catch (e) {
      debugPrint('Upscaling: could not install the shaders: $e');
      return;
    }
    if (_disposed || generation != _generation) return;
    _sent = key;
    _watch(plan.target != null);
    await player.setShaders(paths, target: plan.target);
  }

  void _watch(bool on) {
    watchdog.reset();
    if (!on) {
      _poll?.cancel();
      _poll = null;
    } else {
      _poll ??= Timer.periodic(pollEvery, (_) => _check());
    }
  }

  Future<void> _check() async {
    final state = player.state;
    if (!state.playing || state.buffering) return watchdog.reset();
    if (_reading) return;
    _reading = true;
    try {
      final dropped = int.tryParse(
        await player.property('frame-drop-count') ?? '',
      );
      final fps =
          double.tryParse(await player.property('estimated-vf-fps') ?? '') ??
          double.tryParse(await player.property('container-fps') ?? '');
      if (_disposed || _poll == null) return;
      if (dropped == null || fps == null || fps <= 0) return;
      if (!watchdog.sample(
        dropped: dropped,
        position: player.state.position,
        fps: fps,
      )) {
        return;
      }
      final lower = stepDown(_tier);
      if (lower == null) return;
      _tier = lower;
      onSlow?.call(lower);
      await apply();
    } finally {
      _reading = false;
    }
  }

  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _poll?.cancel();
    for (final sub in _subs) {
      sub.cancel();
    }
  }
}

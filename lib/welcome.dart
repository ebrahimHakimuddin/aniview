import 'package:flutter/material.dart';

import 'settings.dart';
import 'tracker.dart';
import 'tv.dart' show isTv;
import 'ui.dart' show scheme, seed;

/// Shown once per launch: set when the greeting has run, so a rebuilt app (a layout change) doesn't greet again.
bool _greeted = false;

/// The AniView wordmark drawing itself in, then "Welcome back, name", over [child] for a couple of seconds when the
/// app opens, while [child] loads underneath. Off in Settings → Appearance.
class Welcome extends StatefulWidget {
  const Welcome({super.key, required this.child});

  final Widget child;

  @override
  State<Welcome> createState() => _WelcomeState();
}

class _WelcomeState extends State<Welcome> with SingleTickerProviderStateMixin {
  final bool _showing = !_greeted && Settings.welcome;
  late final _run = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );

  /// The last name the account answered with, so the greeting never waits on the network; refreshed for next time.
  String? _name = Tracker.signedIn ? Settings.welcomeName : null;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _greeted = true;
    if (!_showing) {
      _run.value = 1; // nothing to play: the app sits at its resting scale
      return;
    }
    _run.forward().whenComplete(() {
      if (mounted) setState(() => _done = true);
    });
    if (Tracker.signedIn) {
      Tracker.viewer()
          .then((me) {
            final name = me?['name'] as String?;
            if (name == null) return;
            Settings.welcomeName = name;
            // Only before the greeting has shown a name: never swap it mid-read.
            if (mounted && _name == null && _run.value < .3) {
              setState(() => _name = name);
            }
          })
          .catchError((Object _) {});
    }
  }

  // Made once: a CurvedAnimation listens to [_run] until disposed, so one per build would pile up listeners.
  late final _mark = _step(0, .27, Curves.easeOutBack);
  late final _rest = _step(.27, .64, Curves.easeInOutCubic);
  late final _pulse = _step(.16, .57, Curves.linear);
  late final _glow = _step(0, .4);
  late final _greeting = _step(.61, .84);
  late final _out = _step(.84, 1, Curves.easeIn);

  @override
  void dispose() {
    for (final curve in [_mark, _rest, _pulse, _glow, _greeting, _out]) {
      curve.dispose();
    }
    _run.dispose();
    super.dispose();
  }

  /// [_run] between [begin] and [end] (fractions of it), eased.
  CurvedAnimation _step(
    double begin,
    double end, [
    Curve curve = Curves.easeOutCubic,
  ]) => CurvedAnimation(
    parent: _run,
    curve: Interval(begin, end, curve: curve),
  );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final width = isTv
        ? 520.0
        : (MediaQuery.sizeOf(context).width * .7).clamp(200.0, 320.0);
    final wordmark = Image.asset(
      scheme.brightness == Brightness.light
          ? 'assets/icon/aniview_wordmark_light.png'
          : 'assets/icon/aniview_wordmark.png',
      width: width,
      semanticLabel: 'AniView',
      // Decoded at the size shown, not the 2172px source, on the app's first frames.
      cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).round(),
    );
    final mark = _mark, rest = _rest, pulse = _pulse;
    final greeting = _greeting, out = _out;
    // Always this Stack, so [child] keeps its place (and its state) when the greeting goes: swapping in the bare
    // child would build the app's home again, and its first-launch work (What's new) with it.
    return Stack(
      children: [
        // Settles from a touch larger as the splash fades, so the app arrives rather than being uncovered.
        ScaleTransition(
          scale: Tween(begin: 1.03, end: 1.0).animate(out),
          child: widget.child,
        ),
        // Lets go of taps and the remote as it fades, so nothing waits on it. Filling the screen: left to size
        // itself it would only be as big as the glow.
        if (_showing && !_done)
          Positioned.fill(
            child: IgnorePointer(
              child: FadeTransition(
                opacity: ReverseAnimation(out),
                child: Material(
                  color: scheme.surface,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // The brand's cyan, softly behind the mark.
                      FadeTransition(
                        opacity: _glow,
                        child: Container(
                          width: width * 1.8,
                          height: width * 1.8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                seed.withValues(alpha: .16),
                                seed.withValues(alpha: 0),
                              ],
                              stops: const [0, .62],
                            ),
                          ),
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Stack(
                            children: [
                              // The "A" (the wordmark's first 29%) first…
                              FadeTransition(
                                opacity: mark,
                                child: ScaleTransition(
                                  scale: Tween(
                                    begin: .92,
                                    end: 1.0,
                                  ).animate(mark),
                                  alignment: const Alignment(-.7, .1),
                                  child: _mask(wordmark, 0, .29, soft: 0),
                                ),
                              ),
                              // …then "niView" wipes in after it.
                              AnimatedBuilder(
                                animation: rest,
                                builder: (context, child) =>
                                    _mask(child!, .29, .29 + .71 * rest.value),
                                child: wordmark,
                              ),
                              // A glow passing over the play triangle in the "A".
                              Positioned(
                                left: width * .155 - width * .05,
                                top: width / 3 * .52 - width * .05,
                                child: AnimatedBuilder(
                                  animation: pulse,
                                  builder: (context, child) => Opacity(
                                    opacity:
                                        (1 - (pulse.value - .4).abs() / .6)
                                            .clamp(0.0, 1.0) *
                                        (pulse.value > 0 ? 1 : 0),
                                    child: child,
                                  ),
                                  child: Container(
                                    width: width * .1,
                                    height: width * .1,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: RadialGradient(
                                        colors: [
                                          seed.withValues(alpha: .85),
                                          seed.withValues(alpha: 0),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: isTv ? 32 : 22),
                          FadeTransition(
                            opacity: greeting,
                            child: SlideTransition(
                              position: Tween(
                                begin: const Offset(0, .3),
                                end: Offset.zero,
                              ).animate(greeting),
                              child: Text(
                                _name == null
                                    ? 'Welcome back'
                                    : 'Welcome back, $_name',
                                textAlign: TextAlign.center,
                                style:
                                    (isTv
                                            ? text.headlineSmall
                                            : text.titleMedium)
                                        ?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                          fontWeight: FontWeight.w500,
                                        ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// [child] shown only between [from] and [to] (fractions of its width), fading out over [soft] past [to].
  static Widget _mask(
    Widget child,
    double from,
    double to, {
    double soft = .06,
  }) => ShaderMask(
    blendMode: BlendMode.dstIn,
    shaderCallback: (bounds) => LinearGradient(
      colors: const [
        Colors.transparent,
        Colors.transparent,
        Colors.white,
        Colors.white,
        Colors.transparent,
      ],
      stops: [0, from, from, to, (to + soft).clamp(to, 1.0)],
    ).createShader(bounds),
    child: child,
  );
}

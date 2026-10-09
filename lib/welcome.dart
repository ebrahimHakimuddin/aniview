import 'package:flutter/material.dart';

import 'settings.dart';
import 'tracker.dart';
import 'tv.dart' show isTv;
import 'ui.dart' show scheme;

/// Shown once per launch: set when the greeting has run, so a rebuilt app (a layout change) doesn't greet again.
bool _greeted = false;

/// "Hey, name! 👋 Welcome back to AniView 🍿" over [child] for a couple of seconds when the app opens, while
/// [child] loads underneath. Off in Settings → Appearance.
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
    if (!_showing) return;
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

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final greeting = CurvedAnimation(
      parent: _run,
      curve: const Interval(.05, .3, curve: Curves.easeOutCubic),
    );
    // Always this Stack, so [child] keeps its place (and its state) when the greeting goes: swapping in the bare
    // child would build the app's home again, and its first-launch work (What's new) with it.
    return Stack(
      children: [
        widget.child,
        // Lets go of taps and the remote as it fades, so nothing waits on it.
        if (_showing && !_done)
          IgnorePointer(
            child: FadeTransition(
              opacity: ReverseAnimation(
                CurvedAnimation(
                  parent: _run,
                  curve: const Interval(.8, 1, curve: Curves.easeIn),
                ),
              ),
              child: Material(
                color: scheme.surface,
                child: Center(
                  child: FadeTransition(
                    opacity: greeting,
                    child: SlideTransition(
                      position: Tween(
                        begin: const Offset(0, .15),
                        end: Offset.zero,
                      ).animate(greeting),
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _name == null ? 'Hey! 👋' : 'Hey, $_name! 👋',
                              textAlign: TextAlign.center,
                              style:
                                  (isTv
                                          ? text.displayMedium
                                          : text.headlineLarge)
                                      ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Welcome back to AniView 🍿',
                              textAlign: TextAlign.center,
                              style:
                                  (isTv ? text.headlineSmall : text.titleMedium)
                                      ?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                      ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

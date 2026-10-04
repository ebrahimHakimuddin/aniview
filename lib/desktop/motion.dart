import 'package:flutter/material.dart';

/// The desktop's motion, from Emil Kowalski's rules: a strong ease-out for what enters, appears or responds (it
/// starts fast, so the move is felt at once), a strong ease-in-out for what travels across the screen, and nothing
/// slower than about 300ms. Nothing here runs when the system asks for less motion.
const deskEaseOut = Cubic(0.23, 1, 0.32, 1);
const deskEaseInOut = Cubic(0.77, 0, 0.175, 1);

/// Fades [child] up into place; the first few of a group (an [index] under a handful) follow each other 35ms apart,
/// the rest come in together, so a long grid doesn't take long to arrive and scrolling back doesn't replay it.
class Reveal extends StatelessWidget {
  const Reveal({super.key, required this.child, this.index = 0});

  final Widget child;
  final int index;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final delay = index.clamp(0, 8) * 35;
    final total = 260 + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delay / total, 1, curve: deskEaseOut),
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * 8),
          child: child,
        ),
      ),
    );
  }
}

/// Crossfades between what's loading and what loaded, so content doesn't pop in where a placeholder was.
class Swap extends StatelessWidget {
  const Swap({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200),
    switchInCurve: deskEaseOut,
    child: child,
  );
}

/// Pages inside the desktop shell: a short fade with the page settling 10px up, quicker leaving than arriving.
class DeskPageTransitions extends PageTransitionsBuilder {
  const DeskPageTransitions();

  @override
  Duration get transitionDuration => const Duration(milliseconds: 220);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 160);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final eased = CurvedAnimation(
      parent: animation,
      curve: deskEaseOut,
      reverseCurve: deskEaseOut.flipped,
    );
    return FadeTransition(
      opacity: eased,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, .014),
          end: Offset.zero,
        ).animate(eased),
        child: child,
      ),
    );
  }
}

/// A [FutureBuilder] whose placeholder crossfades into what loaded, instead of the content popping in.
class SwapFuture<T> extends StatelessWidget {
  const SwapFuture({super.key, required this.future, required this.builder});

  final Future<T>? future;
  final Widget Function(BuildContext context, AsyncSnapshot<T> snapshot)
  builder;

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
    future: future,
    builder: (context, snap) => Swap(
      child: KeyedSubtree(
        key: ValueKey(snap.hasData || snap.hasError),
        child: builder(context, snap),
      ),
    ),
  );
}

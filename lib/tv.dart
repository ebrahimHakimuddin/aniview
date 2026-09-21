import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// Running on Android TV: D-pad navigation, a focus ring, and the TV home layout.
bool isTv = false;

Future<void> detectTv() async {
  try {
    isTv =
        await const MethodChannel('aniview/app').invokeMethod<bool>('tv') ??
        false;
  } catch (_) {} // not on Android
}

/// The show whose poster has D-pad focus, for the TV home billboard.
final focusedMedia = ValueNotifier<Map?>(null);

/// Draws a ring around whatever has D-pad focus, on every screen, so TV users always see where they are.
/// Follows the focused widget each frame, since scrolling moves it without a focus change.
class FocusRing extends StatefulWidget {
  const FocusRing({super.key, required this.child});

  final Widget child;

  @override
  State<FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<FocusRing>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) {
    final next = _focusedRect();
    if (next != rect) setState(() => rect = next);
  })..start();
  Rect? rect;

  Rect? _focusedRect() {
    final node = FocusManager.instance.primaryFocus;
    if (node == null || node is FocusScopeNode || node.context == null) {
      return null;
    }
    final render = node.context!.findRenderObject();
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      return null;
    }
    final r = node.rect;
    final screen = MediaQuery.sizeOf(context);
    // A whole page or text field wrapper holding focus isn't something to point at.
    if (r.width * r.height > screen.width * screen.height * .5) return null;
    return r;
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      widget.child,
      if (rect case final r?)
        Positioned.fromRect(
          rect: r.inflate(4),
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ),
    ],
  );
}

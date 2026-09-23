import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'platform.dart';

/// Running on Android TV: D-pad navigation, a focus ring, and the TV home layout.
bool isTv = false;

Future<void> detectTv() async => isTv = await AndroidApp.isTv();

const _tv = MethodChannel('aniview/tv');

/// Speech to text through Android's recognizer, for search; null when dismissed. Throws when there's none.
Future<String?> recognizeSpeech() => _tv.invokeMethod<String>('voice');

/// Resumes a show (by AniList id) picked from the TV launcher's Continue watching row, whether it launched the
/// app or came while it runs, and opens search for the remote's search key.
Future<void> listenTv({
  required void Function(int id) resume,
  required VoidCallback search,
}) async {
  _tv.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'resume':
        resume(call.arguments as int);
      case 'search':
        search();
    }
  });
  try {
    final launched = await _tv.invokeMethod<int>('launchResume');
    if (launched != null) resume(launched);
  } catch (_) {} // not on Android
}

/// Mirrors watch history (newest first) into the TV launcher's Continue watching row.
Future<void> syncWatchNext(List<Map<String, dynamic>> history) async {
  if (!isTv) return;
  final now = DateTime.now().millisecondsSinceEpoch;
  try {
    await _tv.invokeMethod('watchNext', [
      for (final (i, r) in history.take(10).indexed)
        if (r['media']['id'] is int)
          {
            'id': r['media']['id'],
            'title':
                r['media']['title']['userPreferred'] ??
                r['media']['title']['romaji'] ??
                r['media']['title']['english'] ??
                '',
            'episode': '${r['episode']}',
            'image': r['media']['coverImage']?['extraLarge'],
            'position': r['position'],
            'duration': r['duration'],
            // Entries saved before this was recorded keep their order.
            'at': r['at'] ?? now - i * 60000,
          },
    ]);
  } catch (_) {} // not on Android
}

/// The show whose poster has D-pad focus, for the TV home billboard.
final focusedMedia = ValueNotifier<Map?>(null);

/// App-wide TV remote handling. Draws a ring around whatever has D-pad focus, following it each frame since
/// scrolling moves it without a focus change. Holding OK (or the menu key) long-presses the focused widget, so
/// long-press actions work with a remote; a short press activates it on release. Up/down always leave a text
/// field, which would otherwise trap the D-pad.
class FocusRing extends StatefulWidget {
  const FocusRing({super.key, required this.child});

  final Widget child;

  @override
  State<FocusRing> createState() => _FocusRingState();
}

// ponytail: the ring polls the focused widget every frame on TV; listen to focus and scroll changes if that
// ever costs noticeable frames
class _FocusRingState extends State<FocusRing>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((elapsed) {
    final next = _focusedRect();
    if (next == rect) return;
    // Glide to a newly focused widget (following it if a scroll carries it along meanwhile), then track
    // exactly while a scroll moves it.
    if (rect == null ||
        next == null ||
        next.size != rect!.size ||
        (next.center - rect!.center).distance > 24) {
      _glideUntil = elapsed + _glide;
    }
    setState(() {
      glide = elapsed < _glideUntil ? _glide : Duration.zero;
      rect = next;
      if (next != null) shown = next;
    });
  })..start();
  static const _glide = Duration(milliseconds: 160);
  Duration _glideUntil = Duration.zero;
  Rect? rect;

  /// The last focused rect, where the ring fades out when focus goes somewhere it isn't drawn.
  Rect shown = Rect.zero;
  Duration glide = Duration.zero;
  bool _selectDown = false;
  bool _held = false;
  int _pointer = 1 << 20; // synthetic pointers, clear of real ones

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;
    final focused = FocusManager.instance.primaryFocus?.context;
    if (key == LogicalKeyboardKey.contextMenu) {
      if (event is KeyDownEvent) _longPress();
      return KeyEventResult.handled;
    }
    if (focused == null ||
        focused.findAncestorStateOfType<EditableTextState>() != null ||
        !(key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter ||
            key == LogicalKeyboardKey.gameButtonA)) {
      return KeyEventResult.ignored;
    }
    switch (event) {
      case KeyDownEvent():
        _selectDown = true;
        _held = false;
      // Android starts repeating a held key after its long-press timeout.
      case KeyRepeatEvent():
        if (!_held && _selectDown) {
          _held = true;
          _longPress();
        }
      case KeyUpEvent():
        if (!_held && _selectDown) _activate(focused);
        _selectDown = false;
    }
    return KeyEventResult.handled;
  }

  static void _activate(BuildContext context) {
    const activate = ActivateIntent();
    final action = Actions.maybeFind<ActivateIntent>(context);
    if (action != null && action.isEnabled(activate)) {
      Actions.invoke(context, activate);
    } else {
      Actions.maybeInvoke(context, const ButtonActivateIntent());
    }
  }

  /// A touch held on the focused widget's centre, which is what its long-press handler listens for.
  Future<void> _longPress() async {
    final center = FocusManager.instance.primaryFocus?.rect.center;
    if (center == null) return;
    final pointer = _pointer++;
    GestureBinding.instance.handlePointerEvent(
      PointerDownEvent(pointer: pointer, position: center),
    );
    await Future.delayed(kLongPressTimeout + const Duration(milliseconds: 80));
    GestureBinding.instance.handlePointerEvent(
      PointerUpEvent(pointer: pointer, position: center),
    );
  }

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
      Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
            TraversalDirection.up,
            ignoreTextFields: false,
          ),
          SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(
            TraversalDirection.down,
            ignoreTextFields: false,
          ),
        },
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _onKey,
          child: widget.child,
        ),
      ),
      AnimatedPositioned.fromRect(
        rect: shown.inflate(4),
        duration: glide,
        curve: Curves.easeOutCubic,
        child: IgnorePointer(
          child: AnimatedOpacity(
            opacity: rect == null ? 0 : 1,
            duration: const Duration(milliseconds: 120),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(16),
                boxShadow: const [
                  BoxShadow(color: Color(0x66FFFFFF), blurRadius: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

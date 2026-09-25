import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/services.dart';

import 'history.dart';
import 'platform.dart';

/// Running on Android TV: D-pad navigation and the TV layouts.
bool isTv = false;

/// Whether the device itself is a TV (what pairing and the TV launcher go by), whatever layout is chosen.
bool deviceIsTv = false;

/// The TV layout when the device is a TV, unless [layout] ('phone' or 'tv') says otherwise.
Future<void> detectTv({String layout = 'auto'}) async {
  deviceIsTv = await AndroidApp.isTv();
  applyLayout(layout);
}

/// Picks the layout; a phone in the TV layout stays in landscape, the shape it's made for.
void applyLayout(String layout) {
  isTv = switch (layout) {
    'tv' => true,
    'phone' => false,
    _ => deviceIsTv,
  };
  restoreOrientation();
}

/// The orientations the app allows outside the player.
void restoreOrientation() => SystemChrome.setPreferredOrientations(
  isTv && !deviceIsTv
      ? const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]
      : const [],
);

const _tv = MethodChannel('aniview/tv');

/// Speech to text through Android's recognizer, for search; null when dismissed. Throws when there's none.
Future<String?> recognizeSpeech() => _tv.invokeMethod<String>('voice');

/// The phone remote's keys, as the TV remote's.
const remoteKeys = {
  'up': (PhysicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowUp),
  'down': (PhysicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowDown),
  'left': (PhysicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowLeft),
  'right': (PhysicalKeyboardKey.arrowRight, LogicalKeyboardKey.arrowRight),
  'ok': (PhysicalKeyboardKey.select, LogicalKeyboardKey.select),
  'playpause': (
    PhysicalKeyboardKey.mediaPlayPause,
    LogicalKeyboardKey.mediaPlayPause,
  ),
  'rewind': (PhysicalKeyboardKey.mediaRewind, LogicalKeyboardKey.mediaRewind),
  'forward': (
    PhysicalKeyboardKey.mediaFastForward,
    LogicalKeyboardKey.mediaFastForward,
  ),
  'next': (
    PhysicalKeyboardKey.mediaTrackNext,
    LogicalKeyboardKey.mediaTrackNext,
  ),
};

/// What the TV is playing, for the phone remote's playback controls; null when nothing is.
typedef NowPlaying = ({
  String title,
  String episode,
  bool paused,
  Duration position,
  Duration duration,
});

final nowPlaying = ValueNotifier<NowPlaying?>(null);

/// The player's seek, for the phone remote's seek bar; set while a player is open.
void Function(Duration to)? onRemoteSeek;

/// Search on the TV for what's typed on the phone remote ([query]), or just open Search (null). Home sets it; it
/// does nothing while something plays.
void Function(String? query)? onRemoteSearch;

/// A search typed on the phone remote, for the Search page to run.
final remoteQuery = ValueNotifier<String?>(null);

/// Presses a key from the phone remote ([remoteKeys], or 'back') in the app, through the same handling as the
/// TV remote's keys; [hold] keeps it down long enough to count as a long press. Stays inside Flutter: nothing
/// is injected into Android.
Future<void> pressKey(String name, {bool hold = false}) async {
  if (name == 'back') {
    // The message the engine sends for Android's own back button.
    ServicesBinding.instance.channelBuffers.push(
      SystemChannels.navigation.name,
      SystemChannels.navigation.codec.encodeMethodCall(
        const MethodCall('popRoute'),
      ),
      (_) {},
    );
    return;
  }
  final (physical, logical) = remoteKeys[name]!;
  // The entry point the engine delivers real key presses to, and still the one that reaches the focus tree;
  // a synthesized event is dispatched right away.
  void send(ui.KeyEventType type) =>
      // ignore: deprecated_member_use
      ServicesBinding.instance.keyEventManager.handleKeyData(
        ui.KeyData(
          timeStamp: Duration(
            milliseconds: DateTime.now().millisecondsSinceEpoch,
          ),
          type: type,
          physical: physical.usbHidUsage,
          logical: logical.keyId,
          character: null,
          synthesized: true,
        ),
      );
  send(ui.KeyEventType.down);
  if (hold) {
    await Future.delayed(kLongPressTimeout);
    send(ui.KeyEventType.repeat);
  }
  send(ui.KeyEventType.up);
}

/// Types [text] into the focused text field, as if from its keyboard; false when no field has focus.
bool typeText(String text) {
  final field = FocusManager.instance.primaryFocus?.context
      ?.findAncestorStateOfType<EditableTextState>();
  field?.userUpdateTextEditingValue(
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    ),
    SelectionChangedCause.keyboard,
  );
  return field != null;
}

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
Future<void> syncWatchNext(List<WatchRecord> history) async {
  if (!isTv) return;
  final now = DateTime.now().millisecondsSinceEpoch;
  try {
    await _tv.invokeMethod('watchNext', [
      for (final (i, r) in history.take(10).indexed)
        if (r.show.id is int)
          {
            'id': r.show.id,
            'title': r.show.title,
            'episode': '${r.episode}',
            'image': r.show.cover,
            'position': r.position.inMilliseconds,
            'duration': r.duration?.inMilliseconds,
            // Entries saved before this was recorded keep their order.
            'at': r.savedAt ?? now - i * 60000,
          },
    ]);
  } catch (_) {} // not on Android
}

/// The show whose card has D-pad focus, for the TV home's immersive backdrop.
final focusedMedia = ValueNotifier<Map?>(null);

/// App-wide TV remote handling. Holding OK (or the menu key) long-presses the focused widget, so long-press
/// actions work with a remote; a short press activates it on release. The D-pad always leaves a text field,
/// which would otherwise trap it (the on-screen keyboard does the editing). Moving focus glides lists instead of
/// jumping: rows keep the focused card at their start, like Google TV, and a list holding a [ScrollAnchor]
/// brings that anchor to its top. Focus itself is drawn by each widget (cards scale, buttons invert; see ui.dart).
class TvInput extends StatefulWidget {
  const TvInput({super.key, required this.child});

  final Widget child;

  @override
  State<TvInput> createState() => _TvInputState();
}

class _TvInputState extends State<TvInput> {
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

  static void _glideTo(
    FocusNode node, {
    ScrollPositionAlignmentPolicy? alignmentPolicy,
    double? alignment,
    Duration? duration,
    Curve? curve,
  }) {
    node.requestFocus();
    final context = node.context;
    final target = context?.findRenderObject();
    if (context == null || target is! RenderBox) return;
    Element? anchor;
    context.visitAncestorElements((e) {
      if (e.widget is ScrollAnchor) anchor = e;
      return anchor == null;
    });
    var anchored = false;
    for (
      var s = Scrollable.maybeOf(context);
      s != null;
      s = Scrollable.maybeOf(s.context)
    ) {
      final position = s.position;
      if (axisDirectionToAxis(s.axisDirection) == Axis.horizontal) {
        // The focused card sits at the row's start margin while the row can scroll that far.
        final room = position.viewportDimension - target.size.width;
        position.ensureVisible(
          target,
          alignment: room <= 0 ? 0 : (tvMargin / room).clamp(0.0, 1.0),
          duration: _glide,
          curve: Curves.easeOutCubic,
        );
      } else if (anchor != null && !anchored) {
        anchored = true;
        position.ensureVisible(
          anchor!.renderObject!,
          duration: _glide,
          curve: Curves.easeOutCubic,
        );
      } else {
        // Only as far as it takes to show it (with a little room past it): a short page (Me, settings) stays
        // where it is instead of centring the focused thing and pushing its top off screen.
        final viewport = RenderAbstractViewport.of(target);
        const room = 48.0;
        final start = viewport.getOffsetToReveal(target, 0).offset - room;
        final end = viewport.getOffsetToReveal(target, 1).offset + room;
        final to = position.pixels
            .clamp(end < start ? end : start, end < start ? start : end)
            .clamp(position.minScrollExtent, position.maxScrollExtent);
        if (to != position.pixels) {
          position.animateTo(to, duration: _glide, curve: Curves.easeOutCubic);
        }
      }
    }
  }

  static const _glide = Duration(milliseconds: 260);

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
        TraversalDirection.up,
        ignoreTextFields: false,
      ),
      SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(
        TraversalDirection.down,
        ignoreTextFields: false,
      ),
      SingleActivator(LogicalKeyboardKey.arrowLeft): DirectionalFocusIntent(
        TraversalDirection.left,
        ignoreTextFields: false,
      ),
      SingleActivator(LogicalKeyboardKey.arrowRight): DirectionalFocusIntent(
        TraversalDirection.right,
        ignoreTextFields: false,
      ),
    },
    child: FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(requestFocusCallback: _glideTo),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: widget.child,
      ),
    ),
  );
}

/// The TV overscan margin at the sides (48dp), from the Android TV layout guide; 24dp at top and bottom.
const tvMargin = 48.0;

/// On TV, a vertical list brings this to its top when focus moves into it, so a row of cards shows with its
/// title instead of the focused card being centred.
class ScrollAnchor extends StatelessWidget {
  const ScrollAnchor({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// What Left from a row's first item does: the home screen opens its drawer when it's showing (returns true);
/// elsewhere focus stays put.
bool Function()? onLeftEdge;

/// A horizontal row on TV (cards, buttons, chips): Right from its last item stays put instead of jumping to
/// whatever lies right of it in another row, and Left from its first item goes to [onLeftEdge].
class TvRow extends StatelessWidget {
  const TvRow({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => !isTv
      ? child
      : Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (node, event) {
            if (event is KeyUpEvent) return KeyEventResult.ignored;
            final key = event.logicalKey;
            final right = key == LogicalKeyboardKey.arrowRight;
            if (!right && key != LogicalKeyboardKey.arrowLeft) {
              return KeyEventResult.ignored;
            }
            final current = FocusManager.instance.primaryFocus;
            if (current == null) return KeyEventResult.ignored;
            final x = current.rect.center.dx;
            // Lists build a little past their edges, so the next item along is there when there is one.
            final more = node.traversalDescendants.any(
              (n) =>
                  n != current &&
                  n.canRequestFocus &&
                  (right ? n.rect.center.dx > x + 1 : n.rect.center.dx < x - 1),
            );
            if (more) return KeyEventResult.ignored;
            if (!right) onLeftEdge?.call();
            return KeyEventResult.handled;
          },
          child: child,
        );
}

/// Set when the remote's search key should open voice search on the Search page.
final voiceSearch = ValueNotifier(false);

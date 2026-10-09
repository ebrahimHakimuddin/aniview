import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'anilist.dart' show SearchFilters;
import 'platform.dart';
import 'settings.dart';
import 'desktop/picks.dart' show deskPicks;

/// What the desktop window adds on top of the phone app: its size and place remembered, back on Esc, Alt+Left or the
/// mouse's back button, Ctrl+F (Cmd+F on a Mac, or what Settings rebinds it to) for Search and Ctrl+Q (Cmd+Q) to quit. None of it runs on Android.

/// Set by the desktop shell: puts the cursor in its search box.
VoidCallback? onDesktopFind;

/// The keys that put the cursor in the search box: Ctrl+F (Cmd+F on a Mac) unless rebound in Settings.
final searchShortcut = ValueNotifier(_savedSearchShortcut());

SingleActivator _savedSearchShortcut() {
  final saved = Settings.searchShortcut;
  if (saved == null) {
    return SingleActivator(
      LogicalKeyboardKey.keyF,
      control: !Platform.isMacOS,
      meta: Platform.isMacOS,
    );
  }
  return SingleActivator(
    LogicalKeyboardKey(int.parse(saved.first)),
    control: saved.contains('control'),
    shift: saved.contains('shift'),
    alt: saved.contains('alt'),
    meta: saved.contains('meta'),
  );
}

/// Rebinds Search to [keys]; null goes back to Ctrl+F.
void rebindSearch(SingleActivator? keys) {
  Settings.searchShortcut = keys == null
      ? null
      : [
          '${keys.trigger.keyId}',
          if (keys.control) 'control',
          if (keys.shift) 'shift',
          if (keys.alt) 'alt',
          if (keys.meta) 'meta',
        ];
  searchShortcut.value = _savedSearchShortcut();
}

/// "Ctrl+Shift+F", as the keyboard reads.
String keysLabel(SingleActivator keys, [String separator = '+']) => [
  if (keys.control) 'Ctrl',
  if (keys.meta) Platform.isMacOS ? 'Cmd' : 'Super',
  if (keys.alt) Platform.isMacOS ? 'Option' : 'Alt',
  if (keys.shift) 'Shift',
  keys.trigger.keyLabel,
].join(separator);

final _modifiers = {
  LogicalKeyboardKey.control,
  LogicalKeyboardKey.shift,
  LogicalKeyboardKey.alt,
  LogicalKeyboardKey.meta,
};

/// Waits for the next key combination pressed; null when Esc or the button closes it. It needs Ctrl, Alt or Cmd
/// (Super) held, so typing never sets it off, and can't take Quit's.
Future<SingleActivator?> recordShortcut(BuildContext context) {
  var hint = 'Press the keys together';
  return showDialog<SingleActivator>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (dialog, setState) => Focus(
        autofocus: true,
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent) return KeyEventResult.handled;
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.escape) {
            Navigator.pop(dialog);
            return KeyEventResult.handled;
          }
          // A modifier on its own: wait for the key.
          if (LogicalKeyboardKey.collapseSynonyms({key})
              .any(_modifiers.contains)) {
            return KeyEventResult.handled;
          }
          final held = HardwareKeyboard.instance;
          final keys = SingleActivator(
            key,
            control: held.isControlPressed,
            shift: held.isShiftPressed,
            alt: held.isAltPressed,
            meta: held.isMetaPressed,
          );
          if (!keys.control && !keys.alt && !keys.meta) {
            setState(() => hint = 'Hold $shortcutKey or Alt too');
          } else if (key == LogicalKeyboardKey.keyQ) {
            setState(() => hint = '${keysLabel(keys)} quits AniView');
          } else {
            Navigator.pop(dialog, keys);
          }
          return KeyEventResult.handled;
        },
        child: AlertDialog(
          title: const Text('Search shortcut'),
          content: Text(hint),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    ),
  );
}

final navigatorKey = GlobalKey<NavigatorState>();

String _pageTitle = '';

/// The window's title follows where you are: "Shingeki no Kyojin · AniView".
void setWindowTitle(String page) {
  _pageTitle = page;
  _showTitle(page);
}

/// While something plays, the window carries its title; null puts the page's back.
void setPlayerTitle(String? title) => _showTitle(title ?? _pageTitle);

void _showTitle(String page) {
  if (!isDesktop) return;
  windowManager.setTitle(page.isEmpty ? 'AniView' : '$page · AniView').ignore();
}

/// The dropdown menu that's open, if any: Esc closes it before it goes back a page.
MenuController? openMenu;

/// Set by the desktop shell: goes back in its pages; false when there's nowhere left to go.
bool Function()? desktopBack;

/// Set by the desktop shell: shows Search with [filters] (and [text] in the box).
void Function(SearchFilters filters, [String text])? onDesktopSearch;

/// Set by the desktop shell: its open section's Navigator, so a show opened from outside it (a search suggestion, the
/// release bell) still opens beside the sidebar.
BuildContext? Function()? deskPageContext;

/// Mouse and trackpad drag lists too, as a finger does (a row of posters has no other way to scroll sideways).
class DesktopScroll extends MaterialScrollBehavior {
  const DesktopScroll();

  @override
  Set<PointerDeviceKind> get dragDevices => PointerDeviceKind.values.toSet();
}

Future<void> setupWindow() async {
  await windowManager.ensureInitialized();
  final saved = Settings.windowBounds;
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: saved?.size ?? const Size(1100, 750),
      minimumSize: const Size(700, 560),
      title: 'AniView',
    ),
    () async {
      if (saved != null && saved.left >= 0 && saved.top >= 0) {
        await windowManager.setPosition(saved.topLeft);
      }
      await windowManager.show();
      await windowManager.focus();
    },
  );
  windowManager.addListener(_WindowMemory());
}

/// Keeps the window's size and place for next launch, once it has stopped moving.
class _WindowMemory with WindowListener {
  Timer? _save;

  void _later() {
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 500), () async {
      if (await windowManager.isFullScreen() ||
          await windowManager.isMaximized()) {
        return;
      }
      Settings.windowBounds = await windowManager.getBounds();
    });
  }

  @override
  void onWindowResized() => _later();

  @override
  void onWindowMoved() => _later();
}

/// Back, Search and Quit for the whole app (see [DeskShell] for the pages themselves). Wraps the Navigator, so it finds it through [navigatorKey].
class DesktopKeys extends StatelessWidget {
  const DesktopKeys({super.key, required this.child});

  final Widget child;

  /// A page above everything (the player, a dialog) goes first; then the shell's own pages.
  void _back() {
    final root = navigatorKey.currentState;
    if (root != null && root.canPop()) {
      root.maybePop();
    } else {
      desktopBack?.call();
    }
  }

  /// Esc first lets go of a text field, then goes back.
  void _escape() {
    if (openMenu != null) {
      openMenu!.close();
      return;
    }
    if (deskPicks.active && !deskPicks.busy) {
      deskPicks.clear();
      return;
    }
    final focus = FocusManager.instance.primaryFocus;
    if (focus?.context?.findAncestorWidgetOfExactType<EditableText>() != null) {
      focus!.unfocus();
    } else {
      _back();
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (e) {
      if (e.buttons == kBackMouseButton) _back();
    },
    child: ValueListenableBuilder(
      valueListenable: searchShortcut,
      builder: (context, _, _) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _escape,
          const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): _back,
          searchShortcut.value: () => onDesktopFind?.call(),
          SingleActivator(
            LogicalKeyboardKey.keyQ,
            control: !Platform.isMacOS,
            meta: Platform.isMacOS,
          ): () =>
              windowManager.close(),
          // Cmd+[ is a Mac's back.
          if (Platform.isMacOS)
            const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true):
                _back,
        },
        child: child,
      ),
    ),
  );
}

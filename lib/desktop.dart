import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'anilist.dart' show SearchFilters;
import 'platform.dart';
import 'settings.dart';
import 'desktop/picks.dart' show deskPicks;

/// What the desktop window adds on top of the phone app: its size and place remembered, back on Esc, Alt+Left or the
/// mouse's back button, Ctrl+F (Cmd+K on a Mac) for Search and Ctrl+Q (Cmd+Q) to quit. None of it runs on Android.

/// Set by the desktop shell: puts the cursor in its search box.
VoidCallback? onDesktopFind;

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
    child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _escape,
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): _back,
        SingleActivator(
          defaultTargetPlatform == TargetPlatform.macOS
              ? LogicalKeyboardKey.keyK
              : LogicalKeyboardKey.keyF,
          control: defaultTargetPlatform != TargetPlatform.macOS,
          meta: defaultTargetPlatform == TargetPlatform.macOS,
        ): () =>
            onDesktopFind?.call(),
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
  );
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'anilist.dart';
import 'desktop.dart';
import 'downloads.dart';
import 'pairing.dart';
import 'platform.dart';
import 'home.dart';
import 'settings.dart';
import 'sources.dart';
import 'tv.dart';
import 'ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // Build the top sites on app load; screens await it later.
  Sites.all().ignore();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  await Future.wait([
    AniList.load(),
    Settings.load(),
    Downloads.instance.load(),
    loadSystemAccent(),
    AndroidApp.buttonNavigation().then((v) => buttonNavigation = v),
  ]);
  if (isDesktop) await setupWindow();
  await detectTv(layout: Settings.layout);
  // Phones find it to pair as a remote and sign it in.
  if (deviceIsTv) TvLink.start().ignore();
  runApp(const App());
}

/// Bumped to rebuild the app from the top, as when the layout changes in settings.
final appGeneration = ValueNotifier(0);

/// Rebuilds MaterialApp's theme while keeping the current navigation route.
final themeGeneration = ValueNotifier(0);

class App extends StatefulWidget {
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The phone switched between light and dark: re-theme when following it.
  @override
  void didChangePlatformBrightness() {
    if (Settings.followSystemTheme) themeGeneration.value++;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([appGeneration, themeGeneration]),
    builder: (context, _) => _app(ValueKey(appGeneration.value)),
  );

  Widget _app(Key key) => MaterialApp(
    key: key,
    title: 'AniView',
    navigatorKey: isDesktop ? navigatorKey : null,
    scrollBehavior: isDesktop ? const DesktopScroll() : null,
    debugShowCheckedModeBanner: false,
    showPerformanceOverlay: Settings.perfOverlay,
    theme: buildTheme(),
    // App-specific widgets read [scheme] directly, so every color must switch in the same frame.
    themeAnimationDuration: Duration.zero,
    builder: isTv
        ? (context, child) => TvInput(child: child!)
        : buttonNavigation
        ? (context, child) => _SolidNavigationBar(child: child!)
        : isDesktop
        ? (context, child) => DesktopKeys(child: child!)
        : null,
    home: const HomeScreen(),
  );
}

/// Phones with navigation buttons: the page's surface behind them, as solid as the rest of the bars. Android 15
/// ignores an app's navigation bar colour, so it's drawn here.
///
/// The buttons' look (icon shade, no contrast scrim) is set once, here, and not as an AnnotatedRegion: Flutter
/// re-sends the whole system bar style every time any part of it changes, and a status bar style flipping while a page
/// slides would then re-apply the navigation bar's too, a stall on every other back.
class _SolidNavigationBar extends StatefulWidget {
  const _SolidNavigationBar({required this.child});

  final Widget child;

  @override
  State<_SolidNavigationBar> createState() => _SolidNavigationBarState();
}

class _SolidNavigationBarState extends State<_SolidNavigationBar> {
  @override
  void initState() {
    super.initState();
    _apply();
  }

  /// A new theme arrives as a rebuilt widget.
  @override
  void didUpdateWidget(_SolidNavigationBar old) {
    super.didUpdateWidget(old);
    _apply();
  }

  void _apply() => SystemChrome.setSystemUIOverlayStyle(
    SystemUiOverlayStyle(
      systemNavigationBarColor: scheme.surface,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarContrastEnforced: false,
      systemNavigationBarIconBrightness: scheme.brightness == Brightness.light
          ? Brightness.dark
          : Brightness.light,
    ),
  );

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      widget.child,
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        // Nothing while the player hides the system bars.
        height: MediaQuery.viewPaddingOf(context).bottom,
        child: IgnorePointer(child: ColoredBox(color: scheme.surface)),
      ),
    ],
  );
}

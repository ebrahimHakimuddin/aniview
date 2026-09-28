import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'anilist.dart';
import 'downloads.dart';
import 'pairing.dart';
import 'home.dart';
import 'settings.dart';
import 'sources.dart';
import 'tv.dart';
import 'ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Build the top sites on app load; screens await it later.
  Sites.all().ignore();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  await Future.wait([
    AniList.load(),
    Settings.load(),
    Downloads.instance.load(),
  ]);
  await detectTv(layout: Settings.layout);
  // Phones find it to pair as a remote and sign it in.
  if (deviceIsTv) TvLink.start().ignore();
  runApp(const App());
}

/// Bumped to rebuild the app from the top, as when the layout changes in settings.
final appGeneration = ValueNotifier(0);

/// Rebuilds MaterialApp's theme while keeping the current navigation route.
final themeGeneration = ValueNotifier(0);

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([appGeneration, themeGeneration]),
    builder: (context, _) => _app(ValueKey(appGeneration.value)),
  );

  Widget _app(Key key) => MaterialApp(
    key: key,
    title: 'AniView',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    // App-specific widgets read [scheme] directly, so every color must switch in the same frame.
    themeAnimationDuration: Duration.zero,
    builder: isTv ? (context, child) => TvInput(child: child!) : null,
    home: const HomeScreen(),
  );
}

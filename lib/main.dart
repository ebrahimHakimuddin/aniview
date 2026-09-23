import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'anilist.dart';
import 'downloads.dart';
import 'pairing.dart';
import 'screens.dart';
import 'settings.dart';
import 'sources.dart';
import 'tv.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  Sites.all()
      .ignore(); // build the top sites on app load; screens await it later
  await Future.wait([
    AniList.load(),
    Settings.load(),
    Downloads.instance.load(),
    detectTv(),
  ]);
  if (isTv)
    TvLink.start()
        .ignore(); // phones find it to sign it in or act as its remote
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF8B5CF6),
      brightness: Brightness.dark,
    ).copyWith(surface: background);
    return MaterialApp(
      title: 'AniView',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: background,
        appBarTheme: const AppBarTheme(
          backgroundColor: background,
          surfaceTintColor: Colors.transparent,
        ),
        chipTheme: const ChipThemeData(
          shape: StadiumBorder(),
          side: BorderSide.none,
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
      ),
      builder: isTv ? (context, child) => FocusRing(child: child!) : null,
      home: const HomeScreen(),
    );
  }
}

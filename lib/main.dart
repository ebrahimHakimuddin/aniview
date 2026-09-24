import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

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
  MediaKit.ensureInitialized();
  // Build the top sites on app load; screens await it later.
  Sites.all().ignore();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  await Future.wait([
    AniList.load(),
    Settings.load(),
    Downloads.instance.load(),
    detectTv(),
  ]);
  // Phones find it to pair as a remote and sign it in.
  if (isTv) TvLink.start().ignore();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'AniView',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    builder: isTv ? (context, child) => TvInput(child: child!) : null,
    home: const HomeScreen(),
  );
}

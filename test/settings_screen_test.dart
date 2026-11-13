import 'dart:io' show Directory, Platform;

import 'package:aniview/analytics.dart';
import 'package:aniview/anilist.dart';
import 'package:aniview/changelog.dart';
import 'package:aniview/downloads.dart';
import 'package:aniview/mal.dart';
import 'package:aniview/platform.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/tv.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every row Settings shows here, by the group it belongs in, with the same platform conditions the screen uses.
Map<String, List<String>> expectedRows() {
  final tvOrDesk = isTv || isDesktop;
  return {
    'Accounts': [
      if (AniList.usable) 'AniList',
      if (MAL.usable) 'MyAnimeList',
      'Update progress automatically',
      'Count as watched at',
      'Connect to Jellyfin',
      'Connect to Jellyseerr',
    ],
    'Appearance': [
      'Theme',
      'Show titles in',
      'Welcome screen',
      'Follow system light and dark',
      if (!isDesktop && !Platform.isIOS) 'Layout',
    ],
    'Home & search': [
      if (isDesktop) 'Search shortcut',
      'Watch random picks from',
      'Sections',
      'Hide NSFW shows',
      'Group related seasons',
    ],
    'Playback': [
      'Skip filler episodes',
      'Preferred audio',
      'Use Sub when Dub is unavailable',
      'Streaming quality',
      'Resume where you left off',
      'Play next episode automatically',
      'Skip intro & outro',
      if (Platform.isAndroid) 'Use an external player',
      if (!tvOrDesk) 'Swipe gestures',
      if (!tvOrDesk) 'Hold the video to',
      tvOrDesk ? 'Left / right seeks' : 'Double-tap to seek',
      'Skip button length',
      'Default speed',
      'Default picture',
    ],
    'Subtitles': [
      'This is your subtitle preview',
      'Language',
      'Subtitles on dub',
      'Size',
      'Text color',
      'Background',
      'Text edge',
      'Font',
      'Bold subtitles',
      'Vertical position',
      'Reset subtitle appearance',
    ],
    'Sources & extensions': [
      'Preferred source',
      if (Platform.isAndroid) 'Extensions',
      'Reset show matches',
      'Clear site verifications',
    ],
    'Downloads & storage': [
      'Download quality',
      if (isDesktop) 'Download folder',
      if (Platform.isAndroid) 'Save downloads to gallery',
      'Delete all downloads',
      'Clear watch history',
    ],
    'Devices': [
      if (!Platform.isIOS) isTv ? 'Phone remote' : 'Set up AniView on a TV',
    ],
    'Notifications': [if (Platform.isAndroid) 'New episodes'],
    'About': [
      appName,
      if (Platform.isLinux) 'Add AniView to the app menu',
      'What’s new',
      if (Analytics.available) 'Share anonymous usage stats',
      'Buy me a coffee',
      'Join the Discord',
      'GitHub',
      'Resume',
      if (isBetaBuild) 'Performance overlay',
    ],
  };
}

/// Phones, a TV and a desktop window, each tall enough that every row of a page is built at once.
typedef Profile = ({String name, double width, bool tv, bool desk});
const profiles = <Profile>[
  (name: 'phone', width: 412, tv: false, desk: false),
  (name: 'tv', width: 960, tv: true, desk: false),
  (name: 'desktop', width: 1200, tv: false, desk: true),
];

Future<void> setUpScreen(WidgetTester tester, Profile p, double height) async {
  isTv = p.tv;
  isDesktop = p.desk;
  addTearDown(() {
    isTv = false;
    isDesktop = false;
  });
  // Nothing reaches the network: no sites to list, no account to show.
  Sites.load = () async => [];
  Sites.reload();
  addTearDown(() {
    Sites.load = topSources;
    Sites.reload();
  });
  AniList.transport = (_, _) async => {};
  addTearDown(() => AniList.transport = null);
  tester.view.physicalSize = Size(p.width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // The desktop's download folder row reads where the downloads are kept: a folder of the test's own.
  final folder = Directory.systemTemp.createTempSync('aniview_settings');
  addTearDown(() => folder.deleteSync(recursive: true));
  SharedPreferences.setMockInitialValues({
    'changelog_seen': changelogVersion,
    'desktop_download_folder': folder.path,
  });
  await Settings.load();
  await tester.runAsync(Downloads.instance.load);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => TvInput(child: child!),
      home: const Scaffold(body: SettingsScreen()),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  for (final p in profiles) {
    testWidgets('${p.name}: lays out at its usual size', (tester) async {
      await setUpScreen(tester, p, p.desk ? 800 : (p.tv ? 540 : 915));
      expect(tester.takeException(), isNull);
      await tester.fling(
        find.byType(Scrollable).last,
        const Offset(0, -3000),
        3000,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('${p.name}: shows every row once', (tester) async {
      await setUpScreen(tester, p, 12000);
      final rows = expectedRows().values.expand((r) => r).toList();
      if (p.desk) {
        // One group at a time: the sidebar picks which.
        final sidebar = find.descendant(
          of: find.byType(ListView).first,
          matching: find.byType(ListTile),
        );
        final seen = <String>[];
        for (var i = 0; i < tester.widgetList(sidebar).length; i++) {
          await tester.tap(sidebar.at(i));
          await tester.pump(const Duration(seconds: 1));
          seen.addAll(
            rows.where(
              (r) => find
                  .descendant(
                    of: find.byType(ListView).last,
                    matching: find.text(r),
                  )
                  .evaluate()
                  .isNotEmpty,
            ),
          );
        }
        expect(seen..sort(), rows..sort());
      } else {
        for (final r in rows) {
          expect(find.text(r), findsOneWidget, reason: r);
        }
      }
      expect(tester.takeException(), isNull);
    });
  }
}

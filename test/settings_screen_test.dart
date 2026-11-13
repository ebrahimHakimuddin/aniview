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
import 'package:aniview/upscale.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
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
    'Video enhancement': [if (usesMediaKit) 'Anime upscaling (Anime4K)'],
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

/// How many times the screen asked for the sites since [setUpScreen].
var siteLoads = 0;

Future<void> setUpScreen(WidgetTester tester, Profile p, double height) async {
  isTv = p.tv;
  isDesktop = p.desk;
  addTearDown(() {
    isTv = false;
    isDesktop = false;
  });
  // Nothing reaches the network: no sites to list, no account to show.
  siteLoads = 0;
  Sites.load = () async {
    siteLoads++;
    return [];
  };
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

/// Groups of one row show that row on the top list rather than a page of their own (phone and TV).
const rowGroups = {'Devices', 'Notifications'};

/// The groups shown here, in order: the ones with a row on this device.
List<String> shownGroups() => [
  for (final MapEntry(:key, :value) in expectedRows().entries)
    if (value.isNotEmpty) key,
];

/// Which of [rows] are on screen under [scope] (everything when null), each expected at most once.
List<String> rowsIn(List<String> rows, [Finder? scope]) => [
  for (final r in rows)
    if ((scope == null
            ? find.text(r)
            : find.descendant(of: scope, matching: find.text(r)))
        .evaluate()
        .isNotEmpty)
      r,
];

/// A frame to start whatever was just set going (a page opening or closing), then time for it to finish.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  for (final p in profiles) {
    testWidgets('${p.name}: lays out at its usual size', (tester) async {
      await setUpScreen(tester, p, p.desk ? 800 : (p.tv ? 540 : 915));
      expect(tester.takeException(), isNull);
      Future<void> scrollToEnd() async {
        await tester.fling(
          find.byType(Scrollable).last,
          const Offset(0, -3000),
          3000,
        );
        await settle(tester);
        expect(tester.takeException(), isNull);
      }

      await scrollToEnd();
      // Every group's own page too.
      for (final group in shownGroups()) {
        if (p.desk) {
          await tester.tap(find.widgetWithText(ListTile, group).first);
          await settle(tester);
          await scrollToEnd();
        } else if (!rowGroups.contains(group)) {
          final tile = find.widgetWithText(ListTile, group);
          final list = find.byType(Scrollable).last;
          tester.state<ScrollableState>(list).position.jumpTo(0);
          await tester.pump();
          await tester.scrollUntilVisible(tile, 200, scrollable: list);
          await settle(tester);
          await tester.tap(tile);
          await settle(tester);
          await scrollToEnd();
          await tester.pageBack();
          await settle(tester);
        }
      }
    });

    testWidgets('${p.name}: shows every row once, in its group', (
      tester,
    ) async {
      await setUpScreen(tester, p, 12000);
      final expected = expectedRows();
      final all = expected.values.expand((r) => r).toList();
      final seen = <String>[];
      if (p.desk) {
        // One group at a time: the sidebar picks which.
        final sidebar = find.descendant(
          of: find.byType(ListView).first,
          matching: find.byType(ListTile),
        );
        final titles = [
          for (final tile in tester.widgetList<ListTile>(sidebar))
            (tile.title! as Text).data!,
        ];
        expect(titles, shownGroups());
        for (final (i, group) in titles.indexed) {
          await tester.tap(sidebar.at(i));
          await settle(tester);
          final pane = find.byType(ListView).last;
          final here = rowsIn(all, pane);
          expect(here, expected[group], reason: group);
          for (final r in here) {
            expect(
              find.descendant(of: pane, matching: find.text(r)),
              findsOneWidget,
              reason: r,
            );
          }
          seen.addAll(here);
        }
      } else {
        // The top list: a tile per group, or the row itself for a group of one.
        final tiles = [
          for (final g in shownGroups())
            if (!rowGroups.contains(g)) g,
        ];
        for (final g in shownGroups()) {
          expect(find.text(g), findsNWidgets(rowGroups.contains(g) ? 0 : 1));
        }
        // mpv runs the shaders; Android's Media3 can't, so the group is gone there.
        expect(
          find.text('Video enhancement'),
          usesMediaKit ? findsOneWidget : findsNothing,
        );
        expect(find.text('Watch party'), findsNothing);
        final top = rowsIn(all);
        expect(top, [for (final g in rowGroups) ...expected[g]!]);
        seen.addAll(top);
        for (final group in tiles) {
          await tester.tap(find.widgetWithText(ListTile, group));
          await settle(tester);
          // The page is titled after its group and holds just that group's rows.
          expect(
            find.descendant(
              of: find.byType(AppBar),
              matching: find.text(group),
            ),
            findsOneWidget,
          );
          final here = rowsIn(all);
          expect(here, expected[group], reason: group);
          for (final r in here) {
            expect(find.text(r), findsOneWidget, reason: r);
          }
          seen.addAll(here);
          await tester.pageBack();
          await settle(tester);
          expect(find.text(group), findsOneWidget);
        }
      }
      expect(seen..sort(), all..sort());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('phone: a switch on a group page repaints there', (tester) async {
    await setUpScreen(tester, profiles.first, 12000);
    await tester.tap(find.widgetWithText(ListTile, 'Home & search'));
    await settle(tester);
    final before = Settings.hideNsfw;
    await tester.tap(find.text('Hide NSFW shows'));
    await tester.pump();
    expect(Settings.hideNsfw, !before);
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, 'Hide NSFW shows'),
          )
          .value,
      !before,
    );
  });

  testWidgets('phone: picks an upscaling tier on its own page', (tester) async {
    expect(
      usesMediaKit,
      isTrue,
    ); // tests run on a desktop OS: mpv's group shows
    await setUpScreen(tester, profiles.first, 2000);
    await tester.tap(find.widgetWithText(ListTile, 'Video enhancement'));
    await settle(tester);
    expect(Settings.upscale, Upscale.off);
    expect(find.textContaining('Off · Sharpens anime'), findsOneWidget);
    await tester.tap(find.text('Anime upscaling (Anime4K)'));
    await settle(tester);
    await tester.tap(find.text('Quality').last);
    await settle(tester);
    expect(Settings.upscale, Upscale.quality);
    expect(find.textContaining('Quality · Sharpens anime'), findsOneWidget);
  });

  testWidgets('tv: the remote opens a group and Back returns to its tile', (
    tester,
  ) async {
    await setUpScreen(tester, profiles[1], 540);
    bool focused(String text) =>
        Focus.of(tester.element(find.text(text))).hasPrimaryFocus;

    expect(focused('Accounts'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await settle(tester);
    expect(focused('Appearance'), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await settle(tester);
    expect(find.text('Follow system light and dark'), findsOneWidget);
    expect(focused('Theme'), isTrue);

    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.text('Theme'), findsNothing);
    expect(focused('Appearance'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('builds a group\'s rows only once it is on screen', (
    tester,
  ) async {
    await setUpScreen(tester, profiles.first, 2000);
    expect(siteLoads, 0); // the top list doesn't build Sources
    await tester.tap(find.widgetWithText(ListTile, 'Sources & extensions'));
    await settle(tester);
    expect(siteLoads, 1);
  });

  testWidgets('desktop: builds only the group picked in the sidebar', (
    tester,
  ) async {
    await setUpScreen(tester, profiles.last, 800);
    expect(siteLoads, 0);
    await tester.tap(find.widgetWithText(ListTile, 'Sources & extensions'));
    await settle(tester);
    expect(siteLoads, 1);
  });
}

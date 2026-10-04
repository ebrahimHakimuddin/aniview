import 'package:aniview/anilist.dart';
import 'package:aniview/changelog.dart';
import 'package:aniview/home.dart';
import 'package:aniview/platform.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/tracker.dart';
import 'package:aniview/tv.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Browsing answers with nothing, so every place lays out without reaching the network.
class _Empty implements Catalog {
  @override
  bool get usable => true;
  @override
  Future<List> trending() async => [];
  @override
  Future<List> season() async => [];
  @override
  Future<(List, bool)> search(
    String text,
    SearchFilters filters,
    int page,
  ) async => (<dynamic>[], false);
  @override
  Future<List<(String, Map)>> relations(Map media) async => [];
}

/// Each platform's layout at the sizes it runs at: phones (portrait and landscape), a tablet, TVs and desktop windows.
typedef P = ({String name, Size size, double dpr, bool tv, bool desk});

const profiles = <P>[
  (name: 'phone small', size: Size(360, 640), dpr: 1, tv: false, desk: false),
  (name: 'phone', size: Size(412, 915), dpr: 1, tv: false, desk: false),
  (
    name: 'phone landscape',
    size: Size(915, 412),
    dpr: 1,
    tv: false,
    desk: false,
  ),
  (name: 'tablet', size: Size(800, 1280), dpr: 1, tv: false, desk: false),
  (name: 'tv 1080p', size: Size(960, 540), dpr: 2, tv: true, desk: false),
  (name: 'tv 720p', size: Size(1280, 720), dpr: 1, tv: true, desk: false),
  (name: 'desktop min', size: Size(420, 600), dpr: 1, tv: false, desk: true),
  (name: 'desktop', size: Size(1100, 750), dpr: 1, tv: false, desk: true),
  (name: 'desktop 4k', size: Size(1920, 1080), dpr: 2, tv: false, desk: true),
];

void main() {
  for (final p in profiles) {
    testWidgets('${p.name} ${p.size.width.toInt()}x${p.size.height.toInt()}', (
      tester,
    ) async {
      isDesktop = p.desk;
      isTv = p.tv;
      addTearDown(() {
        isDesktop = false;
        isTv = false;
      });
      Tracker.primary = _Empty();
      addTearDown(() => Tracker.primary = const AniListCatalog());
      AniList.transport = (_, _) async => {
        'Page': {
          'pageInfo': {'hasNextPage': false},
          'media': [],
          'airingSchedules': [],
          'mediaList': [],
        },
      };
      addTearDown(() => AniList.transport = null);
      Sites.load = () async => [];
      addTearDown(() {
        Sites.load = topSources;
        Sites.reload();
      });
      tester.view.physicalSize = p.size * p.dpr;
      tester.view.devicePixelRatio = p.dpr;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({
        'changelog_seen': changelogVersion,
      });
      await Settings.load();
      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull, reason: 'home');

      if (p.tv) {
        // D-pad: open the drawer and walk down through each page.
        for (var i = 0; i < 6; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
          await tester.pump(const Duration(milliseconds: 300));
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump(const Duration(milliseconds: 300));
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
          await tester.pump(const Duration(milliseconds: 500));
          expect(tester.takeException(), isNull, reason: 'tv step $i');
        }
      } else if (!p.desk) {
        for (final l in ['Schedule', 'Search', 'My list', 'Me', 'Home']) {
          const icons = {
            'Home': Icons.home_outlined,
            'Schedule': Icons.calendar_today_outlined,
            'Search': Icons.search_rounded,
            'My list': Icons.bookmarks_outlined,
            'Me': Icons.person_outline_rounded,
          };
          await tester.tap(
            (p.size.width >= 600 ? find.byIcon(icons[l]!) : find.byTooltip(l))
                .first,
          );
          await tester.pump(const Duration(milliseconds: 500));
          expect(tester.takeException(), isNull, reason: l);
        }
      } else {
        for (final l in [
          'Schedule',
          'My list',
          'Downloads',
          'Settings',
          'Home',
        ]) {
          final t = p.size.width < 1000
              ? find.byTooltip(l)
              : find.text(l).first;
          await tester.tap(t);
          await tester.pump(const Duration(milliseconds: 500));
          expect(tester.takeException(), isNull, reason: l);
        }
      }
    });
  }
}

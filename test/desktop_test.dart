import 'package:aniview/anilist.dart';
import 'package:aniview/changelog.dart';
import 'package:aniview/desktop/widgets.dart';
import 'package:aniview/home.dart';
import 'package:aniview/platform.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/tracker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A catalog with nothing in it, so no test reaches for the network.
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

void main() {
  setUp(() => Tracker.primary = _Empty());
  tearDown(() => Tracker.primary = const AniListCatalog());

  testWidgets('the desktop has a sidebar of places, each opening its page', (
    tester,
  ) async {
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'changelog_seen': changelogVersion,
    });
    await Settings.load();
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));

    for (final place in [
      'Home',
      'Schedule',
      'My list',
      'Downloads',
      'Settings',
    ]) {
      expect(
        find.text(place),
        findsWidgets,
        reason: '$place is in the sidebar',
      );
    }
    expect(find.byType(NavigationBar), findsNothing); // not the phone's

    await tester.tap(find.text('Schedule'));
    await tester.pump();
    expect(find.text('This week'), findsOneWidget);

    await tester.tap(find.text('My list'));
    await tester.pump();
    expect(find.text('Sign in with AniList'), findsWidgets);
  });

  // The window can be as small as 420 wide; nothing may overflow at any size between.
  for (final (width, height) in [
    (700.0, 600.0),
    (1000.0, 700.0),
    (1600.0, 1000.0),
  ]) {
    testWidgets('every place lays out at ${width.toInt()}×${height.toInt()}', (
      tester,
    ) async {
      isDesktop = true;
      addTearDown(() => isDesktop = false);
      // AniList answers with nothing in it, so each place lays out its empty state without reaching the network.
      AniList.transport = (_, _) async => {
        'Page': {
          'pageInfo': {'hasNextPage': false},
          'media': [],
          'airingSchedules': [],
          'mediaList': [],
        },
      };
      addTearDown(() => AniList.transport = null);
      // Settings lists the sites; there are none to list here.
      Sites.load = () async => [];
      addTearDown(() {
        Sites.load = topSources;
        Sites.reload();
      });
      tester.view.physicalSize = Size(width, height);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({
        'changelog_seen': changelogVersion,
      });
      await Settings.load();
      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      for (final place in [
        'Schedule',
        'My list',
        'Downloads',
        'Settings',
        'Home',
      ]) {
        // A narrow window keeps the sidebar to icons, which carry the names as tooltips.
        final tab = width < 1000
            ? find.byTooltip(place)
            : find.text(place).first;
        await tester.tap(tab);
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull, reason: '$place at $width');
      }
    });
  }

  testWidgets('a row can be hidden from its menu', (tester) async {
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var hidden = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DeskRow('Trending now', [
            {
              'id': 1,
              'title': {'userPreferred': 'A show'},
              'description': 'It is about something.',
            },
          ], onHide: () => hidden++),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Row options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide this row'));
    await tester.pumpAndSettle();
    expect(hidden, 1);
  });

  // A page in the shell sits in a Navigator beside the sidebar and under the top bar.
  Future<void> shellLike(WidgetTester tester, Widget page) async {
    isDesktop = true;
    addTearDown(() => isDesktop = false);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              const SizedBox(width: 232),
              Expanded(
                child: Column(
                  children: [
                    const SizedBox(height: 64),
                    Expanded(
                      child: Navigator(
                        onGenerateRoute: (_) => MaterialPageRoute<void>(
                          builder: (_) => Material(child: page),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('posters with two-line titles fit their cells at any width', (
    tester,
  ) async {
    await shellLike(
      tester,
      GridView.builder(
        gridDelegate: const DeskPosterGrid(),
        itemCount: 12,
        itemBuilder: (_, i) => DeskPoster({
          'id': i,
          'title': {
            'userPreferred':
                'A show with a title long enough to need two lines $i',
          },
        }, subtitle: 'EP 2 / 12'),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a right click opens its menu at the pointer', (tester) async {
    await shellLike(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 172,
          child: DeskPoster({
            'id': 1,
            'title': {'userPreferred': 'A show'},
          }),
        ),
      ),
    );
    final at = tester.getCenter(find.text('A show'));
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await mouse.down(at);
    await mouse.up();
    await tester.pumpAndSettle();
    final menu = tester.getTopLeft(find.text('Open'));
    // The item's text sits a padding in from the menu's corner, which is where the pointer was.
    expect((menu.dx - at.dx).abs(), lessThan(40));
    expect((menu.dy - at.dy).abs(), lessThan(40));
  });
}

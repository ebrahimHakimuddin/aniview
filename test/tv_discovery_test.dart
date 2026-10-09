import 'package:aniview/anilist.dart';
import 'package:aniview/search.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/tracker.dart';
import 'package:aniview/tv.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map _show(int id) => {
  'id': id,
  'title': {'english': 'English $id', 'userPreferred': 'Japanese $id'},
  'averageScore': 86,
  'genres': ['Action', 'Fantasy'],
  'description': 'A journey across the stars for show $id.',
  'format': 'TV',
  'episodes': 12,
};

class _Catalog implements Catalog {
  final calls = <(String, SearchFilters)>[];
  @override
  bool get usable => true;
  @override
  Future<List> trending() async => [_show(1)];
  @override
  Future<List> season() async => [];
  @override
  Future<List<(String, Map)>> relations(Map media) async => [];
  @override
  Future<(List, bool)> search(
    String text,
    SearchFilters filters,
    int page,
  ) async {
    calls.add((text, filters));
    return ([_show(text.isEmpty ? 1 : 2), _show(3)], false);
  }
}

void main() {
  late _Catalog catalog;
  setUp(() async {
    isTv = true;
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
    catalog = _Catalog();
    Tracker.primary = catalog;
  });
  tearDown(() {
    isTv = false;
    Tracker.primary = const AniListCatalog();
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        builder: (_, child) => TvInput(child: child!),
        home: const SearchScreen(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'browse shows English titles, scores and a synopsis without typing',
    (tester) async {
      await open(tester);
      expect(catalog.calls.single.$1, '');
      expect(catalog.calls.single.$2.sort, 'POPULARITY_DESC');
      expect(find.text('English 1'), findsNWidgets(2));
      expect(find.text('Japanese 1'), findsNothing);
      expect(
        find.text('A journey across the stars for show 1.'),
        findsOneWidget,
      );
      expect(find.text('Action · Fantasy'), findsOneWidget);
      expect(find.byIcon(Icons.star_rounded), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('clear search returns to browsing with the selected sort', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'naruto');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('English 2'), findsNWidgets(2));
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    expect(catalog.calls.last.$1, '');
    expect(catalog.calls.last.$2.sort, 'POPULARITY_DESC');
    expect(find.text('English 1'), findsNWidgets(2));
    expect(find.text('English 2'), findsNothing);
  });

  testWidgets(
    'focusing a poster hides filters; returning to search restores them',
    (tester) async {
      await open(tester);
      expect(find.text('Genres'), findsOneWidget);
      final focus = tester.widget<Focus>(
        find
            .descendant(
              of: find.byType(PosterCard).last,
              matching: find.byType(Focus),
            )
            .last,
      );
      Focus.of(tester.element(find.byWidget(focus.child))).requestFocus();
      await tester.pumpAndSettle();
      expect(find.text('Genres'), findsNothing);
      expect(find.text('English 3'), findsNWidgets(2));
      expect(
        find.text('A journey across the stars for show 3.'),
        findsOneWidget,
      );
      tester
          .widget<TextField>(find.byType(TextField))
          .focusNode!
          .requestFocus();
      await tester.pumpAndSettle();
      expect(find.text('Genres'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('sorting changes the browse request', (tester) async {
    await open(tester);
    await tester.tap(find.text('Popular'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Top rated'));
    await tester.pumpAndSettle();
    expect(catalog.calls.last.$2.sort, 'SCORE_DESC');
  });

  testWidgets(
    'D-pad down stays in text entry while Android keyboard is visible',
    (tester) async {
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      addTearDown(tester.view.reset);
      final field = FocusNode(), below = FocusNode();
      addTearDown(field.dispose);
      addTearDown(below.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => TvInput(child: child!),
          home: Scaffold(
            body: Column(
              children: [
                TextField(focusNode: field, autofocus: true),
                TextButton(
                  focusNode: below,
                  onPressed: () {},
                  child: const Text('Below'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(field.hasFocus, isTrue);
      expect(below.hasFocus, isFalse);
    },
  );

  testWidgets('episode anchor centers when reached with the remote', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const anchor = Key('episodes');
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => TvInput(child: child!),
        home: Scaffold(
          body: ListView(
            children: [
              TextButton(
                autofocus: true,
                onPressed: () {},
                child: const Text('Start'),
              ),
              const SizedBox(height: 700),
              ScrollAnchor(
                key: anchor,
                alignment: .5,
                child: SizedBox(
                  height: 100,
                  child: TextButton(
                    onPressed: () {},
                    child: const Text('Episode 1'),
                  ),
                ),
              ),
              const SizedBox(height: 700),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(tester.getCenter(find.byKey(anchor)).dy, closeTo(270, 2));
  });
}

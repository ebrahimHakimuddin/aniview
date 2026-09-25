import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a page\'s floating button sits above the navigation pill', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    // A gesture-bar phone: 24dp of system inset at the bottom.
    tester.view.padding = const FakeViewPadding(bottom: 72);
    tester.view.viewPadding = const FakeViewPadding(bottom: 72);
    addTearDown(tester.view.reset);
    const fab = Key('fab');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          extendBody: true,
          bottomNavigationBar: FloatingNav(
            destinations: const [
              (Icons.home_outlined, Icons.home, 'Home'),
              (Icons.search, Icons.search, 'Search'),
            ],
            selected: 0,
            onSelect: (_) {},
          ),
          // Home's feed is a scaffold of its own inside the app's, as in the app.
          body: Builder(
            builder: (page) => Scaffold(
              floatingActionButton: ClearOfNav(
                page: page,
                child: const SizedBox(key: fab, width: 120, height: 48),
              ),
              body: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    final button = tester.getRect(find.byKey(fab));
    final pill = tester.getRect(find.byType(Panel));
    expect(button.bottom, lessThanOrEqualTo(pill.top));
    expect(
      pill.top - button.bottom,
      lessThanOrEqualTo(24),
    ); // just above, not floating off
  });

  testWidgets('a snackbar from a page shows above the navigation pill', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(bottom: 72);
    tester.view.viewPadding = const FakeViewPadding(bottom: 72);
    addTearDown(tester.view.reset);
    late BuildContext inPage;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          extendBody: true,
          bottomNavigationBar: FloatingNav(
            destinations: const [
              (Icons.home_outlined, Icons.home, 'Home'),
              (Icons.search, Icons.search, 'Search'),
            ],
            selected: 0,
            onSelect: (_) {},
          ),
          body: Scaffold(
            body: Builder(
              builder: (context) {
                inPage = context;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      ),
    );
    ScaffoldMessenger.of(inPage)
        .showSnackBar(const SnackBar(content: Text('Saved')));
    await tester.pumpAndSettle();
    final snack = tester.getRect(find.byType(SnackBar));
    final pill = tester.getRect(find.byType(Panel));
    expect(snack.bottom, lessThanOrEqualTo(pill.top));
  });

  testWidgets('the navigation pill keeps its items 8dp from every edge', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: FloatingNav(
            destinations: const [
              (Icons.home_outlined, Icons.home, 'Home'),
              (Icons.event_outlined, Icons.event, 'Schedule'),
              (Icons.search, Icons.search, 'Search'),
              (Icons.bookmarks_outlined, Icons.bookmarks, 'My list'),
              (Icons.person_outline, Icons.person, 'Me'),
            ],
            selected: 0,
            onSelect: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final pill = tester.getRect(find.byType(Panel));
    final items = find.descendant(
      of: find.byType(Panel),
      matching: find.byType(AnimatedContainer),
    );
    final first = tester.getRect(items.first),
        last = tester.getRect(items.last);
    expect(first.top - pill.top, 8);
    expect(pill.bottom - first.bottom, 8);
    expect(first.left - pill.left, 8);
    expect(pill.right - last.right, 8);
  });
}

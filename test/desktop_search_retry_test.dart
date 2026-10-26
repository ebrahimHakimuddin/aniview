import 'package:aniview/anilist.dart';
import 'package:aniview/desktop/search.dart';
import 'package:aniview/desktop/shell.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('later-page failure keeps results and waits for explicit retry', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final request = ValueNotifier(
      const DeskSearchRequest('anime', SearchFilters()),
    );
    addTearDown(request.dispose);
    final pages = <int>[];
    var fail = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: DeskSearch(
            request,
            onReload: ({bool force = false}) {},
            fetch: (_, _, page) async {
              pages.add(page);
              if (page == 2 && fail) throw Exception('Page two failed');
              return (
                [
                  for (var i = 0; i < 20; i++)
                    {
                      'id': page * 100 + i,
                      'title': {'romaji': 'Show $page-$i'},
                    },
                ],
                page == 1,
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final scroll = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    scroll.jumpTo(scroll.maxScrollExtent);
    await tester.pumpAndSettle();
    scroll.jumpTo(scroll.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.textContaining('Page two failed'), findsOneWidget);
    expect(pages, [1, 2]);
    scroll.jumpTo(scroll.maxScrollExtent - 10);
    await tester.pumpAndSettle();
    expect(pages, [1, 2]);
    expect(find.textContaining('Show 1-'), findsWidgets);
    fail = false;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(pages, [1, 2, 2]);
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('40 shows'), findsOneWidget);
    expect(find.textContaining('Page two failed'), findsNothing);
  });
}

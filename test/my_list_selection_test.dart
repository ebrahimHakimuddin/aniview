import 'package:aniview/anilist.dart';
import 'package:aniview/library.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('bulk actions stay visible while scrolling My List', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
    AniList.token = 'test';
    addTearDown(() => AniList.token = null);

    final shows = [
      for (var i = 0; i < 30; i++)
        {
          'id': i,
          'title': {'userPreferred': 'Show $i'},
          'coverImage': {'extraLarge': null},
        },
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: MyListScreen(
          lists: Future.value({'CURRENT': shows}),
          onRefresh: () async {},
          onChanged: () {},
          onSignIn: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.byType(PosterCard).first);
    await tester.pumpAndSettle();

    final action = find.byTooltip('Change status');
    expect(find.text('1 selected'), findsOneWidget);
    final topBefore = tester.getTopLeft(action).dy;

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1100));
    await tester.pumpAndSettle();

    expect(action, findsOneWidget);
    expect(tester.getTopLeft(action).dy, topBefore);
  });
}

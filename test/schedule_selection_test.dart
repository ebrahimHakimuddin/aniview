import 'package:aniview/anilist.dart';
import 'package:aniview/details.dart';
import 'package:aniview/library.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map _slot(int id, DateTime at) => {
  'episode': 3,
  'airingAt': at.millisecondsSinceEpoch ~/ 1000,
  'media': {
    'id': id,
    'title': {'userPreferred': 'Show $id'},
    'coverImage': {'extraLarge': null},
  },
};

Future<void> _pumpSchedule(WidgetTester tester, List<Map> slots) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  await Settings.load();
  AniList.token = 'test';
  addTearDown(() => AniList.token = null);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: ScheduleScreen(
        schedule: Future.value(slots),
        allSchedule: Future.value(slots),
        onRefresh: () async {},
        onChanged: () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The card (what's pressed), not its title text.
Finder _card(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(FocusCard));

void main() {
  final now = DateTime.now();

  testWidgets(
    'holding an episode starts picking, and taps then toggle instead of opening',
    (tester) async {
      // The first second of today: always today, and already aired, so every one is a plain row.
      final at = DateTime(now.year, now.month, now.day, 0, 0, 1);
      await _pumpSchedule(tester, [_slot(1, at), _slot(2, at), _slot(3, at)]);

      await tester.longPress(_card('Show 1'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      expect(find.byTooltip('Add to list'), findsOneWidget);

      await tester.tap(_card('Show 2'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);
      expect(find.byType(DetailsScreen), findsNothing);

      await tester.tap(_card('Show 1'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      await tester.tap(find.byTooltip('Done'));
      await tester.pumpAndSettle();
      expect(find.textContaining('selected'), findsNothing);
    },
  );

  testWidgets('the next-up card picks too', (tester) async {
    await _pumpSchedule(tester, [
      _slot(1, DateTime(now.year, now.month, now.day, 23, 59, 59)),
    ]);

    expect(
      find.textContaining('NEXT UP'),
      findsOneWidget,
    ); // its eyebrow, upper-cased
    await tester.longPress(_card('Show 1'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
  });
}

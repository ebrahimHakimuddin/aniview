import 'package:aniview/anilist.dart';
import 'package:aniview/details.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'list progress fill has visible height and tracks watched episodes',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await Settings.load();
      AniList.token = 'test';
      addTearDown(() => AniList.token = null);
      final media = {
        'id': 7,
        'title': {'userPreferred': 'Example show'},
        'coverImage': {'extraLarge': null},
        'episodes': 10,
        'mediaListEntry': {'status': 'CURRENT', 'progress': 8},
      };
      await tester.pumpWidget(
        MaterialApp(theme: buildTheme(), home: DetailsScreen(media)),
      );
      await tester.pump(const Duration(milliseconds: 700));

      final card = find.ancestor(
        of: find.text('8 / 10'),
        matching: find.byType(Card),
      );
      final fill = find.descendant(
        of: card,
        matching: find.byType(FractionallySizedBox),
      );
      expect(fill, findsOneWidget);
      expect(tester.getSize(fill).height, 4);
      expect(tester.getSize(fill).width, greaterThan(0));
    },
  );
}

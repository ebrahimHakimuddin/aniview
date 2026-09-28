import 'package:aniview/settings.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'long poster titles leave progress and airing badges on the art',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      await Settings.load();
      final media = {
        'id': 1,
        'title': {
          'userPreferred': 'A very long anime title with a second line',
        },
        'coverImage': {'extraLarge': null},
        'episodes': 19,
        'mediaListEntry': {'status': 'CURRENT', 'progress': 11},
        'nextAiringEpisode': {
          'episode': 20,
          'airingAt':
              DateTime.now()
                  .add(const Duration(days: 3))
                  .millisecondsSinceEpoch ~/
              1000,
        },
      };
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(body: MediaRow('Continue watching', [media])),
        ),
      );
      await tester.pumpAndSettle();

      final poster = tester.getRect(find.byType(FocusCard));
      final progress = tester.getRect(find.text('EP 11 / 19'));
      final airing = tester.getRect(find.textContaining('EP 20'));
      expect(progress.top, greaterThan(airing.bottom));
      expect(progress.bottom, lessThan(poster.bottom));
      final fill = find.descendant(
        of: find.byType(FocusCard),
        matching: find.byType(FractionallySizedBox),
      );
      expect(tester.getSize(fill).height, progressBarHeight);
      expect(tester.getSize(fill).width, greaterThan(0));
      expect(tester.takeException(), isNull);
    },
  );
}

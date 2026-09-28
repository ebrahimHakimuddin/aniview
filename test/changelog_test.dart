import 'package:aniview/changelog.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('the in-app changelog shows the current release overview', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showChangelog(context),
              child: const Text('What’s new'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('What’s new'));
    await tester.pumpAndSettle();
    expect(find.text('What’s new in $changelogVersion'), findsOneWidget);
    for (final highlight in changelogHighlights) {
      expect(find.text(highlight), findsOneWidget);
    }
  });
}

import 'package:aniview/changelog.dart';
import 'package:aniview/home.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // Home's shell rebuilding re-runs its LayoutBuilder, which rebuilds the whole feed under it: on a phone that was
  // most of the first frame of every show page opened from Home, and of the first frame back.
  testWidgets('opening a page over Home and going back leaves Home unbuilt', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    // Home shows the what's-new dialog on a version's first launch; this starts past it.
    SharedPreferences.setMockInitialValues({
      'changelog_seen': changelogVersion,
    });
    await Settings.load();
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    // Past Home's first-frame checks (updates, what's new, the survey), which wait on real I/O.
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
    final nav = tester.widget(find.byType(FloatingNav));

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('a show')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('a show'), findsOneWidget);
    navigator.pop();
    await tester.pumpAndSettle();

    // The very same widget: Home's shell never built again.
    expect(identical(tester.widget(find.byType(FloatingNav)), nav), isTrue);
  });
}

import 'package:aniview/settings.dart';
import 'package:aniview/tv.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings → Home & search → Sections, at TV size, driven like a remote would.
Future<void> openSections(WidgetTester t) async {
  t.view.physicalSize = const Size(1920, 1080);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  SharedPreferences.setMockInitialValues({});
  await Settings.load();
  await t.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      builder: (context, child) => TvInput(child: child!),
      home: const Scaffold(body: SettingsScreen()),
    ),
  );
  await t.pumpAndSettle();
  await t.tap(find.text('Home & search').first);
  await t.pump();
  await t.pump(const Duration(seconds: 1));
  await t.scrollUntilVisible(
    find.text('Sections'),
    200,
    scrollable: find.byType(Scrollable).last,
  );
  await t.tap(find.text('Sections'));
  await t.pumpAndSettle();
}

List<HomeSection> order() => [for (final (s, _) in Settings.homeSections) s];

void main() {
  testWidgets('a remote moves a section with the row\'s Move down', (t) async {
    isTv = true;
    addTearDown(() => isTv = false);
    await openSections(t);
    final first = order();
    // From Back, down to the second row's buttons, then across to Move down.
    for (var i = 0; i < 3; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pumpAndSettle();
    }
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pumpAndSettle();
    final focused = FocusManager.instance.primaryFocus!.context!;
    expect(
      focused.findAncestorWidgetOfExactType<Tooltip>()?.message,
      'Move down',
    );
    await t.sendKeyEvent(LogicalKeyboardKey.select);
    await t.pumpAndSettle();
    await t.sendKeyEvent(LogicalKeyboardKey.select);
    await t.pumpAndSettle();
    // The row moved two places, and focus stayed on its button for the next press.
    expect(order().indexOf(first[1]), 3);
    expect(order()[1], first[2]);
    expect(
      FocusManager.instance.primaryFocus!.context!
          .findAncestorWidgetOfExactType<Tooltip>()
          ?.message,
      'Move down',
    );
  });

  testWidgets(
    'a box without a touchscreen gets the buttons in the phone layout',
    (t) async {
      deviceHasTouch = false;
      addTearDown(() => deviceHasTouch = true);
      await openSections(t);
      expect(find.byTooltip('Move down'), findsWidgets);
      expect(find.byIcon(Icons.drag_indicator_rounded), findsNothing);
      final first = order();
      await t.tap(find.byTooltip('Move up').at(1));
      await t.pumpAndSettle();
      expect(order().first, first[1]);
    },
  );

  testWidgets('a phone drags them by the handle', (t) async {
    await openSections(t);
    expect(find.byIcon(Icons.drag_indicator_rounded), findsWidgets);
    expect(find.byTooltip('Move down'), findsNothing);
  });
}

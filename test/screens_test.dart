import 'package:aniview/screens.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/tv.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('labels the next airing episode until it airs', () {
    int inSeconds(Duration d) =>
        DateTime.now().add(d).millisecondsSinceEpoch ~/ 1000;
    Map airing(Duration d) => {
      'nextAiringEpisode': {'episode': 12, 'airingAt': inSeconds(d)},
    };
    expect(
      airingLabel(airing(const Duration(days: 2, hours: 1))),
      'EP 12 · 2d',
    );
    expect(
      airingLabel(airing(const Duration(hours: 5, minutes: 1))),
      'EP 12 · 5h',
    );
    expect(
      airingLabel(airing(const Duration(minutes: 30, seconds: 5))),
      'EP 12 · 30m',
    );
    expect(
      airingLabel(airing(const Duration(minutes: -1))),
      isNull,
    ); // already aired
    expect(airingLabel({'nextAiringEpisode': null}), isNull);
  });

  testWidgets("TV home: the rail only takes focus from the rows' left edge", (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
    isTv = true;
    addTearDown(() => isTv = false);
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => FocusRing(child: child!),
        home: const HomeScreen(),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    String? focused() => FocusManager.instance.primaryFocus?.debugLabel;
    Future<void> press(LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pump(const Duration(milliseconds: 400));
    }

    expect(focused(), 'rail 0');
    for (var i = 0; i < 5; i++) {
      await press(LogicalKeyboardKey.arrowDown);
    }
    expect(focused(), 'rail 3'); // stops at the end

    await press(LogicalKeyboardKey.arrowRight);
    final row = FocusManager.instance.primaryFocus;
    expect(focused(), isNot(startsWith('rail')));
    await press(LogicalKeyboardKey.arrowUp);
    expect(
      FocusManager.instance.primaryFocus,
      row,
    ); // nothing above, and not the rail

    await press(LogicalKeyboardKey.arrowLeft);
    expect(focused(), 'rail 0');
  });
}

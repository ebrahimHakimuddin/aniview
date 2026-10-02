import 'package:aniview/settings.dart';

import 'dart:ui' show Brightness;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('keeps the saved home order and appends sections added later', () async {
    SharedPreferences.setMockInitialValues({
      'home_sections': ['trending', '-featured', 'gone'],
    });
    await Settings.load();
    final sections = Settings.homeSections;
    expect(sections.take(2), [
      (HomeSection.trending, true),
      (HomeSection.featured, false),
    ]);
    expect(sections.length, HomeSection.values.length);
    expect(sections.last, (HomeSection.season, true));
    // Appended sections start off unless they're one of the defaults.
    expect(sections, contains((HomeSection.planning, false)));

    Settings.homeSections = sections.reversed.toList();
    expect(Settings.homeSections.first, (HomeSection.season, true));
    expect(Settings.homeSections.last, (HomeSection.trending, true));
  });

  testWidgets('follows the phone\'s light and dark mode when asked to', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'theme_selection': 'violetLight'});
    await Settings.load();
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    expect(Settings.activeTheme, ThemeSelection.violetLight); // off: as chosen

    Settings.followSystemTheme = true;
    expect(Settings.activeTheme, ThemeSelection.violetDark);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    expect(Settings.activeTheme, ThemeSelection.violetLight);

    // The original dark look has no light twin: cyan stands in.
    expect(
      ThemeSelection.custom.inBrightness(Brightness.light),
      ThemeSelection.materialLight,
    );
    expect(
      ThemeSelection.custom.inBrightness(Brightness.dark),
      ThemeSelection.custom,
    );
  });
}

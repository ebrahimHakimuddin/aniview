import 'package:aniview/home.dart';
import 'package:aniview/main.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('light hero labels stay clear over artwork', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
    addTearDown(() => Settings.themeSelection = ThemeSelection.custom);

    for (final choice in [
      ThemeSelection.materialLight,
      ThemeSelection.violetLight,
      ThemeSelection.forestLight,
    ]) {
      Settings.themeSelection = choice;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: const Scaffold(body: Eyebrow('Trending')),
        ),
      );

      final label = tester.widget<Text>(find.text('TRENDING'));
      expect(label.style?.shadows, isNull);
      final fade = keyArtFade.gradient! as LinearGradient;
      final background = Color.alphaBlend(fade.colors[3], Colors.black);
      final foreground = label.style!.color!;
      final brighter = [
        foreground.computeLuminance(),
        background.computeLuminance(),
      ]..sort();
      final contrast = (brighter.last + .05) / (brighter.first + .05);
      expect(contrast, greaterThanOrEqualTo(4.5), reason: choice.name);
    }
  });

  testWidgets('theme colors change together without a mixed-color frame', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
    await tester.pumpWidget(const App());

    Settings.themeSelection = ThemeSelection.violetLight;
    themeGeneration.value++;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final page = tester.element(find.byType(HomeScreen));
    expect(Theme.of(page).colorScheme.primary, scheme.primary);
    Settings.themeSelection = ThemeSelection.custom;
  });
}

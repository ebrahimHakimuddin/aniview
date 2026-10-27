import 'package:aniview/settings.dart';
import 'package:aniview/tv.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
    isTv = true;
  });
  tearDown(() => isTv = false);

  test('TV audio segments distinguish focus from selection in every theme', () {
    for (final theme in ThemeSelection.values) {
      Settings.themeSelection = theme;
      final built = buildTheme();
      final style = built.segmentedButtonTheme.style!;
      for (final selected in [false, true]) {
        final states = <WidgetState>{
          WidgetState.focused,
          if (selected) WidgetState.selected,
        };
        expect(
          style.backgroundColor?.resolve(states),
          built.colorScheme.onSurface,
          reason: '${theme.name}: selected=$selected',
        );
        expect(
          style.foregroundColor?.resolve(states),
          built.colorScheme.surface,
        );
      }
    }
  });
}

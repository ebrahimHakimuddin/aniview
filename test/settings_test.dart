import 'package:aniview/settings.dart';
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
}

import 'package:aniview/screens.dart';
import 'package:flutter_test/flutter_test.dart';

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
}

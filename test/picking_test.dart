import 'package:aniview/ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('watchedShare', () {
    test('is the share watched of a known total', () {
      expect(watchedShare(6, 12), .5);
      expect(watchedShare(20, 12), 1); // never past full
      expect(watchedShare(0, 12), 0);
    });

    test(
      'fills 90% once something is watched of a show with no episode count',
      () {
        expect(watchedShare(3, null), .9);
        expect(watchedShare(3, 0), .9);
        expect(watchedShare(0, null), 0);
      },
    );
  });
}

import 'package:aniview/ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // the haptic tick on each pick

  test('picking adds and removes shows by id, and ends when none are left', () {
    final picking = Picking();
    var notified = 0;
    picking.addListener(() => notified++);
    final a = {'id': 1}, b = {'id': 2};

    expect(picking.active, isFalse);
    picking.toggle(a);
    picking.toggle(b);
    expect(picking.active, isTrue);
    expect(picking.picked!.length, 2);
    expect(picking.has({'id': 1}), isTrue); // by id, not identity

    picking.toggle(a);
    expect(picking.has(a), isFalse);
    picking.toggle(b);
    expect(picking.active, isFalse);
    expect(notified, 4);
  });

  test('picks are held while a change saves', () {
    final picking = Picking()..toggle({'id': 1});
    picking.setBusy(true);
    picking.toggle({'id': 2});
    expect(picking.picked!.keys, [1]);
    picking.setBusy(false);
    picking.clear();
    expect(picking.active, isFalse);
  });

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

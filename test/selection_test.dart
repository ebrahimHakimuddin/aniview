import 'package:aniview/details.dart';
import 'package:aniview/selection.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('Selection', () {
    test('toggles by key, and ends when none are left', () {
      final selection = Selection<int, Map>((m) => m['id']);
      var notified = 0;
      selection.addListener(() => notified++);
      final a = {'id': 1}, b = {'id': 2};

      expect(selection.active, isFalse);
      selection.toggle(a);
      selection.toggle(b);
      expect(selection.active, isTrue);
      expect(selection.count, 2);
      expect(selection.has({'id': 1}), isTrue); // by key, not identity

      selection.toggle(a);
      expect(selection.has(a), isFalse);
      selection.toggle(b);
      expect(selection.active, isFalse);
      expect(notified, 4);
    });

    test('All picks exactly what is given, and clear drops it', () {
      final selection = Selection<int, int>((n) => n)..toggle(9);
      selection.selectAll([1, 2, 3]);
      expect(selection.items, [1, 2, 3]);
      selection.clear();
      expect(selection.active, isFalse);
    });

    test('picks are held while a change saves', () async {
      final selection = Selection<int, int>((n) => n)..selectAll([1, 2]);
      final release = Future<bool>.delayed(Duration.zero, () => true);
      final running = selection.runBulk((_) => release);
      expect(selection.busy, isTrue);
      expect(selection.toggle(3), isFalse);
      selection.selectAll([4]);
      expect(selection.items, [1, 2]);

      await running;
      expect(selection.busy, isFalse);
      expect(selection.active, isFalse); // cleared when done
    });

    test('runs one at a time and counts the ones that failed midway', () async {
      final selection = Selection<int, int>((n) => n)..selectAll([1, 2, 3, 4]);
      final seen = <int>[];
      var running = 0;
      final result = await selection.runBulk((n) async {
        expect(++running, 1); // never two at once
        await Future<void>.delayed(Duration.zero);
        running--;
        seen.add(n);
        if (n == 2) return false; // queued for later
        if (n == 3) throw Exception('AniList down');
        return true;
      });
      expect(seen, [1, 2, 3, 4]);
      expect((result.total, result.failed, result.ok), (4, 2, false));
      expect(bulkMessage(result, 'Moved 4'), startsWith('2 of 4 not saved'));
      expect(bulkMessage(const BulkResult(4, 0), 'Moved 4'), 'Moved 4');
    });

    test('closing mid-change does not notify a disposed selection', () async {
      final selection = Selection<int, int>((n) => n)..selectAll([1]);
      final running = selection.runBulk((_) async => true);
      selection.dispose();
      expect((await running).total, 1);
    });
  });

  group('cards under a Picking', () {
    final shows = [
      for (var i = 1; i <= 3; i++)
        {
          'id': i,
          'title': {'userPreferred': 'Show $i'},
          'coverImage': {'extraLarge': null},
        },
    ];

    Future<Picking> pump(
      WidgetTester tester,
      List<Widget> Function(List<Map>) cards,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await Settings.load();
      final picking = Picking();
      addTearDown(picking.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: PickingProvider(
            notifier: picking,
            child: Scaffold(
              body: Row(
                children: [
                  for (final card in cards(shows))
                    SizedBox(width: 200, height: 400, child: card),
                ],
              ),
            ),
          ),
        ),
      );
      return picking;
    }

    testWidgets('hold starts picking and taps toggle without opening', (
      tester,
    ) async {
      final picking = await pump(
        tester,
        (s) => [PosterCard(s[0]), PosterCard(s[1])],
      );

      await tester.longPress(find.byType(PosterCard).first);
      expect(picking.items.map((m) => m['id']), [1]);
      await tester.tap(find.byType(PosterCard).last);
      await tester.pump();
      expect(picking.items.map((m) => m['id']), [1, 2]);
      await tester.tap(find.byType(PosterCard).first);
      await tester.pump();
      expect(picking.items.map((m) => m['id']), [2]);
      expect(find.byType(DetailsScreen), findsNothing);
    });

    testWidgets('a card that handles holds itself opts out', (tester) async {
      var held = 0, tapped = 0;
      final picking = await pump(
        tester,
        (s) => [
          PosterCard(s[0], onLongPress: () => held++, onTap: () => tapped++),
          PosterCard(s[1], selected: false, onTap: () => tapped++),
        ],
      );

      await tester.longPress(find.byType(PosterCard).first);
      expect((held, picking.active), (1, false));
      await tester.tap(find.byType(PosterCard).last);
      expect((tapped, picking.active), (1, false));
    });
  });
}

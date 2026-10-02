import 'package:aniview/changelog.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('the in-app changelog shows the current release overview', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showChangelog(context),
              child: const Text('What’s new'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('What’s new'));
    await tester.pumpAndSettle();
    expect(find.text('What’s new in $changelogVersion'), findsOneWidget);
    for (final entry in changelogHighlights) {
      expect(find.text(entry.title), findsOneWidget);
      expect(find.text(entry.body), findsOneWidget);
    }
  });

  group('what\'s new on the first launch of a version', () {
    const app = MethodChannel('aniview/app');
    late List<MethodCall> calls;

    /// The app launching, with Android's side of 'aniview/app' recording what it's asked.
    Future<void> launch(WidgetTester tester) async {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(app, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(app, null),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => maybeShowWhatsNew(context),
                child: const Text('Launch'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Launch'));
      await tester.pumpAndSettle();
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await Settings.load();
    });

    test('shows once per version', () {
      bool show(String? seen) =>
          shouldShowWhatsNew(seen: seen, current: '2.3.0');
      expect(
        show(null),
        isTrue,
      ); // an update from a build that kept no record, or a fresh install
      expect(
        show('2.2.1'),
        isTrue,
      ); // a new version since the last one dismissed
      expect(show('2.3.0'), isFalse); // already dismissed
    });

    testWidgets('appears with the overview and both links pinned', (
      tester,
    ) async {
      await launch(tester);

      expect(find.text('What’s new in $changelogVersion'), findsOneWidget);
      for (final entry in changelogHighlights) {
        expect(find.text(entry.title), findsOneWidget);
        expect(find.text(entry.body), findsOneWidget);
      }
      expect(find.text('Buy me a coffee'), findsOneWidget);
      expect(find.text('Join Discord'), findsOneWidget);
      expect(find.text('Got it'), findsOneWidget);
      // Until it's dismissed it hasn't been seen.
      expect(Settings.changelogSeen, isNull);
    });

    testWidgets(
      'keeps the buttons in view while the overview scrolls on a small phone',
      (tester) async {
        tester.view.physicalSize = const Size(
          960,
          1440,
        ); // 320 × 480 dp, a small phone
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        await launch(tester);

        expect(tester.takeException(), isNull); // nothing overflows
        for (final label in ['Buy me a coffee', 'Join Discord', 'Got it']) {
          expect(
            tester.getRect(find.text(label)).bottom,
            lessThanOrEqualTo(480),
            reason: '$label is on screen',
          );
        }
        // The overview is what scrolls, so the buttons stay put.
        expect(find.byType(SingleChildScrollView), findsOneWidget);
      },
    );

    testWidgets('the links open the coffee page and the Discord invite', (
      tester,
    ) async {
      await launch(tester);

      await tester.tap(find.text('Buy me a coffee'));
      await tester.tap(find.text('Join Discord'));
      await tester.pump();
      expect(
        [for (final c in calls.where((c) => c.method == 'open')) c.arguments],
        [coffeeUrl, discordUrl],
      );
      expect(
        find.text('Got it'),
        findsOneWidget,
      ); // opening a link leaves it up
    });

    testWidgets('is gone for good once dismissed', (tester) async {
      await launch(tester);
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();

      expect(find.text('Got it'), findsNothing);
      expect(Settings.changelogSeen, changelogVersion);

      await tester.tap(find.text('Launch'));
      await tester.pumpAndSettle();
      expect(find.text('Got it'), findsNothing); // not again
    });

    testWidgets('dismissing it by tapping outside counts too', (tester) async {
      await launch(tester);
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();

      expect(find.text('Got it'), findsNothing);
      expect(Settings.changelogSeen, changelogVersion);
    });

    testWidgets('comes back for the next version', (tester) async {
      Settings.changelogSeen = '2.0.0';
      await launch(tester);

      expect(find.text('Got it'), findsOneWidget);
    });
  });
}

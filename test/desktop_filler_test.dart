import 'dart:convert';

import 'package:aniview/platform.dart';
import 'package:aniview/details.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

class _Source extends Source {
  _Source(String name) : super(name, 'https://source.test');
  @override
  Future<List<SearchResult>> search(String query) async => [];
  @override
  Future<String?> match(Map media) async => 'show';
  @override
  Future<List<Episode>> episodesOf(String id) async => [
    Episode(1, ref: '1'),
    Episode(2, ref: '2'),
    Episode(3, ref: '3'),
    Episode(4, ref: '4'),
  ];
  @override
  Future<List<VideoStream>> streams(
    Map media,
    Episode episode, {
    required bool dub,
  }) async => [];
}

void main() {
  for (final desktop in [true, false]) {
    testWidgets(
      '${desktop ? 'desktop' : 'phone'} episodes display filler and mixed labels',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'filler:${desktop ? 90210 : 90211}': jsonEncode({
            'at': DateTime.now().millisecondsSinceEpoch,
            'kinds': {'1': 'filler', '2': 'filler', '3': 'mixed'},
          }),
        });
        await Settings.load();
        final oldDesktop = isDesktop;
        isDesktop = desktop;
        final oldLoad = Sites.load, oldHost = ExtensionHost.current;
        Sites.load = () async => [_Source('Test')];
        ExtensionHost.current = FakeHost();
        Sites.reload();
        addTearDown(() {
          isDesktop = oldDesktop;
          Sites.load = oldLoad;
          ExtensionHost.current = oldHost;
          Sites.reload();
        });
        tester.view.physicalSize = desktop
            ? const Size(1280, 1400)
            : const Size(390, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final show = {
          'id': desktop ? 90210 : 90211,
          'title': {'userPreferred': 'Show'},
          'episodes': 4,
        };
        await tester.pumpWidget(
          MaterialApp(theme: buildTheme(), home: DetailsScreen(show)),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Episode 1'));
        await tester.pumpAndSettle();
        expect(find.text('Episode 1'), findsOneWidget);
        expect(
          find.byWidgetPredicate((w) => w is Banner && w.message == 'FILLER'),
          findsNWidgets(2),
        );
        expect(
          find.byWidgetPredicate((w) => w is Banner && w.message == 'MIXED'),
          findsOneWidget,
        );
        await tester.ensureVisible(find.byType(SwitchListTile));
        await tester.tap(find.byType(SwitchListTile));
        await tester.pumpAndSettle();
        expect(Settings.skipFiller, isTrue);
        expect(
          find.byWidgetPredicate((w) => w is Banner && w.message == 'FILLER'),
          findsNWidgets(2),
        );
        expect(
          find.byWidgetPredicate((w) => w is Banner && w.message == 'MIXED'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        Future<void> choose(String current, String next) async {
          final button = find.text('Filler view: $current');
          await tester.ensureVisible(button);
          await tester.tap(button);
          await tester.pumpAndSettle();
          await tester.tap(find.text(next));
          await tester.pumpAndSettle();
        }

        await choose('Show all', 'Group filler');
        expect(find.text('Episode 1'), findsNothing);
        expect(find.text('Episodes 1–2 · Filler'), findsOneWidget);
        await tester.ensureVisible(find.text('Episodes 1–2 · Filler'));
        await tester.tap(find.text('Episodes 1–2 · Filler'));
        await tester.pumpAndSettle();
        expect(find.text('Episode 1'), findsOneWidget);
        await tester.ensureVisible(find.text('Collapse filler'));
        await tester.tap(find.text('Collapse filler'));
        await tester.pumpAndSettle();
        expect(find.text('Episode 1'), findsNothing);
        await choose('Group filler', 'Hide skipped filler');
        expect(
          find.text('Hidden while skipping · Tap to reveal'),
          findsOneWidget,
        );
        expect(
          find.byWidgetPredicate((w) => w is Banner && w.message == 'MIXED'),
          findsOneWidget,
        );
        await tester.ensureVisible(find.byType(SwitchListTile));
        await tester.tap(find.byType(SwitchListTile));
        await tester.pumpAndSettle();
        expect(Settings.skipFiller, isFalse);
        expect(find.text('Episode 1'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

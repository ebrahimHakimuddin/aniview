import 'package:aniview/details.dart';
import 'package:aniview/downloads.dart';
import 'package:aniview/platform.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

class _Source extends Source {
  _Source() : super('Test', 'https://source.test');
  @override
  Future<List<SearchResult>> search(String query) async => [];
  @override
  Future<String?> match(Map media) async => 'show';
  @override
  Future<List<Episode>> episodesOf(String id) async => [
    for (var i = 1; i <= 3; i++) Episode(i, ref: '$i'),
  ];
  @override
  Future<List<VideoStream>> streams(
    Map media,
    Episode episode, {
    required bool dub,
  }) async => [];
}

void main() {
  testWidgets('phone picks update their rows and the bar without the page, '
      'and selection keeps the rows', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
    final oldDesktop = isDesktop;
    isDesktop = false;
    final oldLoad = Sites.load, oldHost = ExtensionHost.current;
    Sites.load = () async => [_Source()];
    ExtensionHost.current = FakeHost();
    Sites.reload();
    addTearDown(() {
      isDesktop = oldDesktop;
      Sites.load = oldLoad;
      ExtensionHost.current = oldHost;
      Sites.reload();
    });
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: DetailsScreen({
          'id': 90212,
          'title': {'userPreferred': 'Show'},
          'episodes': 3,
        }),
      ),
    );
    await tester.pumpAndSettle();
    final checked = find.byIcon(Icons.check_circle_rounded);

    await tester.ensureVisible(find.text('Episode 1'));
    // Entering and leaving selection updates each row in place rather than rebuilding it from scratch.
    final row = tester.element(find.text('Episode 3'));
    await tester.longPress(find.text('Episode 1'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(checked, findsOneWidget);
    expect(tester.element(find.text('Episode 3')), same(row));

    // A pick redraws only the row it changed.
    final rebuilt = <String>[];
    debugOnRebuildDirtyWidget = (e, _) =>
        rebuilt.add(e.widget.runtimeType.toString());
    await tester.tap(find.text('Episode 2'));
    await tester.pump();
    debugOnRebuildDirtyWidget = null;
    expect(rebuilt.where((t) => t == '_EpisodeTile'), hasLength(1));
    expect(rebuilt, isNot(contains('DetailsScreen')));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    expect(checked, findsNWidgets(2));

    await tester.tap(find.text('Episode 1'));
    await tester.tap(find.text('Episode 2'));
    await tester.pumpAndSettle();
    expect(find.textContaining('selected'), findsNothing);
    expect(tester.element(find.text('Episode 3')), same(row));
    expect(find.byIcon(Icons.radio_button_unchecked_rounded), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a download’s progress redraws its own episode’s button, not the others',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await Settings.load();
      final oldDesktop = isDesktop;
      isDesktop = false;
      final oldLoad = Sites.load, oldHost = ExtensionHost.current;
      Sites.load = () async => [_Source()];
      ExtensionHost.current = FakeHost();
      Sites.reload();
      addTearDown(() {
        isDesktop = oldDesktop;
        Sites.load = oldLoad;
        ExtensionHost.current = oldHost;
        Sites.reload();
      });
      tester.view.physicalSize = const Size(390, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final media = {
        'id': 90212,
        'title': {'userPreferred': 'Show'},
        'episodes': 3,
      };
      Download download(int number, DownloadStatus status) => Download(
        media: media,
        source: 'Test',
        number: number,
        dub: false,
        ref: '$number',
        status: status,
        progress: status == DownloadStatus.done ? 1 : .25,
      );
      final active = download(1, DownloadStatus.downloading);
      Downloads.instance.items
        ..clear()
        ..addAll([active, download(2, DownloadStatus.done)]);
      addTearDown(Downloads.instance.items.clear);
      await tester.pumpWidget(
        MaterialApp(theme: buildTheme(), home: DetailsScreen(media)),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('25% · tap to cancel'), findsOneWidget);
      expect(find.byTooltip('Downloaded · tap to delete'), findsOneWidget);
      expect(find.byTooltip('Download'), findsOneWidget);

      final rebuilt = <Widget>[];
      debugOnRebuildDirtyWidget = (e, _) => rebuilt.add(e.widget);
      active.progress = .5;
      Downloads.instance.debugProgressed(active);
      await tester.pump();
      debugOnRebuildDirtyWidget = null;
      expect(find.byTooltip('50% · tap to cancel'), findsOneWidget);
      final types = [for (final w in rebuilt) w.runtimeType.toString()];
      expect(types, isNot(contains('_DownloadButton')));
      expect(types, isNot(contains('ListTile')));
      expect(types.where((t) => t == 'IconButton'), hasLength(1));
      expect(rebuilt.length, lessThan(60), reason: '$types');

      // Finished: a change to the list, which every episode's button still hears.
      active
        ..status = DownloadStatus.done
        ..progress = 1;
      Downloads.instance.debugChanged();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Downloaded · tap to delete'), findsNWidgets(2));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      Downloads.instance.items.removeAt(1);
      Downloads.instance.debugChanged();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Download'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );
}

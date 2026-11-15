import 'package:aniview/details.dart';
import 'package:aniview/downloads.dart';
import 'package:aniview/platform.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/gestures.dart';
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
  testWidgets('desktop episode picks update their rows and the bar, '
      'and selection keeps the rows', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
    final oldDesktop = isDesktop;
    isDesktop = true;
    final oldLoad = Sites.load, oldHost = ExtensionHost.current;
    Sites.load = () async => [_Source()];
    ExtensionHost.current = FakeHost();
    Sites.reload();
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() {
      isDesktop = oldDesktop;
      Sites.load = oldLoad;
      ExtensionHost.current = oldHost;
      Sites.reload();
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic;
    });
    tester.view.physicalSize = const Size(1400, 1400);
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
    final unchecked = find.byIcon(Icons.radio_button_unchecked_rounded);
    final checked = find.byIcon(Icons.check_circle_rounded);

    // Hovering a row shows its checkbox; clicking it starts picking.
    final row = tester.element(find.text('Episode 3'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.text('Episode 1')));
    await tester.pumpAndSettle();
    await tester.tap(unchecked.first);
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(checked, findsOneWidget);
    expect(tester.element(find.text('Episode 3')), same(row));

    // While picking every row has its box: a second pick redraws that row and the bar.
    await tester.tap(unchecked.first);
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    expect(checked, findsNWidgets(2));

    await tester.tap(checked.first);
    await tester.pumpAndSettle();
    await tester.tap(checked.first);
    await tester.pumpAndSettle();
    expect(find.textContaining('selected'), findsNothing);
    expect(checked, findsNothing);
    expect(tester.element(find.text('Episode 3')), same(row));
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a download’s progress redraws its own episode’s button, not the rows',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await Settings.load();
      final oldDesktop = isDesktop;
      isDesktop = true;
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
      tester.view.physicalSize = const Size(1400, 1400);
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

      final rebuilt = <Widget>[];
      debugOnRebuildDirtyWidget = (e, _) => rebuilt.add(e.widget);
      active.progress = .5;
      Downloads.instance.debugProgressed(active);
      await tester.pump();
      debugOnRebuildDirtyWidget = null;
      expect(find.byTooltip('50% · tap to cancel'), findsOneWidget);
      final types = [for (final w in rebuilt) w.runtimeType.toString()];
      expect(types, isNot(contains('_DownloadButton')));
      expect(types, isNot(contains('Hover')));
      expect(types.where((t) => t == 'IconButton'), hasLength(1));
      expect(rebuilt.length, lessThan(60), reason: '$types');

      active
        ..status = DownloadStatus.done
        ..progress = 1;
      Downloads.instance.debugChanged();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Downloaded · tap to delete'), findsNWidgets(2));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

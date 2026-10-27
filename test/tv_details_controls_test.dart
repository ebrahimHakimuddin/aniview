import 'package:aniview/details.dart';
import 'package:aniview/platform.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/tv.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

class _Source extends Source {
  _Source() : super('Fixture', 'https://fixture.test');
  @override
  Future<List<SearchResult>> search(String query) async => [];
  @override
  Future<String?> match(Map media) async => 'show';
  @override
  Future<List<Episode>> episodesOf(String id) async => [
    Episode(1, ref: '1'),
    Episode(2, ref: '2'),
  ];
  @override
  Future<List<VideoStream>> streams(
    Map media,
    Episode episode, {
    required bool dub,
  }) async => [];
}

void main() {
  for (final size in [const Size(960, 540), const Size(1280, 720)]) {
    testWidgets(
      'TV details keeps sort beside Play and selects focused Dub at $size',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        await Settings.load();
        final wasTv = isTv, wasDesktop = isDesktop;
        final oldLoad = Sites.load, oldHost = ExtensionHost.current;
        isTv = true;
        isDesktop = false;
        Sites.load = () async => [_Source()];
        ExtensionHost.current = FakeHost();
        Sites.reload();
        addTearDown(() {
          isTv = wasTv;
          isDesktop = wasDesktop;
          Sites.load = oldLoad;
          ExtensionHost.current = oldHost;
          Sites.reload();
        });
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            builder: (context, child) => TvInput(child: child!),
            home: DetailsScreen({
              'id': 980876,
              'title': {'romaji': 'Fixture'},
              'episodes': 2,
            }),
          ),
        );
        await tester.pumpAndSettle();
        final play = tester.getRect(find.byType(PlayAction));
        final sort = tester.getRect(
          find.widgetWithText(TextButton, 'Oldest first'),
        );
        expect(sort.left, greaterThanOrEqualTo(play.right));
        expect((sort.center.dy - play.center.dy).abs(), lessThan(4));
        Focus.of(tester.element(find.text('Dub'))).requestFocus();
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
              .selected,
          {false},
        );
        await pressKey('ok');
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
              .selected,
          {true},
        );
        expect(
          tester
              .widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
              .showSelectedIcon,
          isTrue,
        );
        await tester.tap(find.text('Oldest first'));
        await tester.pumpAndSettle();
        expect(find.text('Newest first'), findsOneWidget);
      },
    );
  }
}

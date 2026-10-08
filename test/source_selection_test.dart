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
  Future<List<Episode>> episodesOf(String id) async => [];
  @override
  Future<List<VideoStream>> streams(
    Map media,
    Episode episode, {
    required bool dub,
  }) async => [];
}

void main() {
  testWidgets('a source selected on a show is selected again after restart', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
    final oldLoad = Sites.load, oldHost = ExtensionHost.current;
    Sites.load = () async => [_Source('Ranked'), _Source('Chosen')];
    ExtensionHost.current = FakeHost();
    Sites.reload();
    addTearDown(() {
      Sites.load = oldLoad;
      ExtensionHost.current = oldHost;
      Sites.reload();
    });
    tester.view.physicalSize = const Size(500, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final show = {
      'id': 7,
      'title': {'userPreferred': 'Show'},
      'episodes': 12,
    };
    Future<void> open() async {
      await tester.pumpWidget(
        MaterialApp(theme: buildTheme(), home: DetailsScreen(show)),
      );
      await tester.pumpAndSettle();
    }

    await open();
    await tester.ensureVisible(find.text('#1  Ranked'));
    await tester.tap(find.text('#1  Ranked'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#2  Chosen'));
    await tester.pumpAndSettle();
    expect(Settings.preferredSource, 'Chosen');
    await tester.pumpWidget(const SizedBox.shrink());
    await Settings.load();
    Sites.reload();
    await open();
    expect(find.text('#2  Chosen'), findsOneWidget);
    // Removing that site falls back safely without erasing the saved choice.
    expect(Sites.preferred([_Source('Ranked')])!.name, 'Ranked');
    expect(Settings.preferredSource, 'Chosen');
  });
}

import 'dart:convert';

import 'package:aniview/exo.dart';
import 'package:aniview/player.dart';
import 'package:aniview/platform.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Backend extends PlayerBackend {
  late void Function(Map) emit;
  @override
  Future<void> start(void Function(Map) on) async => emit = on;
  @override
  Future<void> call(String method, Map<String, Object?> args) async {
    if (method == 'open') {
      emit({
        'position': 0,
        'buffer': 0,
        'duration': 100000,
        'playing': true,
        'buffering': false,
      });
    }
  }

  @override
  Future<void> setVolume(double level) async {}
  @override
  Future<void> dispose() async {}
}

class SourceFixture extends Source {
  SourceFixture() : super('Fixture', 'https://fixture.test');
  final requested = <num>[];
  final requestedRefs = <Object>[];
  @override
  Future<String?> match(Map media) async => 'fixture';
  @override
  Future<List<Episode>> episodesOf(String id) async => [Episode(1, ref: '1')];
  @override
  Future<List<SearchResult>> search(String query) async => [];
  @override
  Future<List<VideoStream>> streams(
    Map media,
    Episode episode, {
    required bool dub,
  }) async {
    requested.add(episode.number);
    requestedRefs.add(episode.ref);
    return [VideoStream('Fixture', '/tmp/fixture.mp4', {})];
  }
}

void main() {
  testWidgets(
    'offline entry streams an unsaved episode from its saved source',
    (tester) async {
      SharedPreferences.setMockInitialValues({'resume': false});
      await Settings.load();
      final source = SourceFixture();
      final previousLoad = Sites.load;
      Sites.load = () async => [source];
      Sites.reload();
      addTearDown(() {
        Sites.load = previousLoad;
        Sites.reload();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: PlayerScreen(
            media: {
              'id': 1234567,
              'title': {'romaji': 'Fixture'},
            },
            source: null,
            sourceName: source.name,
            episodes: [Episode(1, ref: 'obsolete-offline-reference')],
            index: 0,
            dub: false,
            backend: Backend(),
          ),
        ),
      );
      for (var i = 0; i < 20 && source.requested.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(source.requested, [1]);
      expect(source.requestedRefs, ['1']);
      expect(find.textContaining("isn't downloaded"), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  for (final skip in [true, false]) {
    for (final action in ['click', 'keyboard', 'automatic']) {
      testWidgets('$action Next respects skip filler=$skip', (tester) async {
        final id =
            9898 +
            ['click', 'keyboard', 'automatic'].indexOf(action) +
            (skip ? 0 : 10);
        SharedPreferences.setMockInitialValues({
          'skip_filler': skip,
          'resume': false,
          'auto_next': true,
          'filler:$id': jsonEncode({
            'at': DateTime.now().millisecondsSinceEpoch,
            'kinds': {'2': 'filler'},
          }),
        });
        await Settings.load();
        final oldDesktop = isDesktop;
        isDesktop = true;
        addTearDown(() => isDesktop = oldDesktop);
        tester.view.physicalSize = const Size(1400, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final source = SourceFixture();
        final backend = Backend();
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: PlayerScreen(
              media: {
                'id': id,
                'title': {'romaji': 'Fixture'},
              },
              source: source,
              episodes: [
                Episode(1, ref: '1'),
                Episode(2, ref: '2'),
                Episode(3, ref: '3'),
              ],
              index: 0,
              dub: false,
              backend: backend,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(source.requested, [1]);
        expect(find.byTooltip('Open in another app'), findsNothing);
        if (action == 'click') {
          await tester.tap(find.byTooltip('Next episode  (N)'));
        } else if (action == 'keyboard') {
          await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
        } else {
          backend.emit({'completed': true});
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(source.requested, [1, skip ? 3 : 2]);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
    }
  }
}

import 'package:aniview/platform.dart';
import 'package:aniview/player.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_controls_test.dart' show Backend, SourceFixture;

Future<Backend> _open(
  WidgetTester tester,
  int id, {
  bool desktop = true,
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues({'resume': false, ...prefs});
  await Settings.load();
  final previous = configureQuality;
  configureQuality = (_, _) async => const [];
  addTearDown(() => configureQuality = previous);
  final oldDesktop = isDesktop;
  isDesktop = desktop;
  addTearDown(() => isDesktop = oldDesktop);
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final backend = Backend();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: PlayerScreen(
        media: {
          'id': id,
          'title': {'romaji': 'Fixture'},
        },
        source: SourceFixture(),
        episodes: [
          Episode(1, ref: '1'),
          Episode(2, ref: '2'),
        ],
        index: 0,
        dub: false,
        backend: backend,
      ),
    ),
  );
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return backend;
}

void main() {
  testWidgets('letting go of a hold shows no hint unless one was showing', (
    tester,
  ) async {
    await _open(tester, 7007019, desktop: false);
    final hintBox = find.byWidgetPredicate(
      (w) =>
          w is DecoratedBox &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).color ==
              Colors.black.withValues(alpha: .7),
    );
    // Off the controls, on the video itself.
    const video = Offset(100, 300);
    expect(tester.hitTestOnBinding(video).path.length, greaterThan(0));
    expect(hintBox, findsNothing);
    // Hold for 2×: nothing was showing, so letting go shows nothing.
    var hold = await tester.startGesture(video);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    expect(find.text('2×'), findsOneWidget);
    await hold.up();
    await tester.pump();
    expect(hintBox, findsNothing);
    await tester.pump(const Duration(seconds: 2));

    // Hold to pause: its hint stays while held, then fades after letting go.
    await tester.pumpWidget(const SizedBox.shrink());
    await _open(
      tester,
      7007020,
      desktop: false,
      prefs: {'hold_gesture': 'pause'},
    );
    hold = await tester.startGesture(video);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    expect(find.text('Paused · release to play'), findsOneWidget);
    await hold.up();
    await tester.pump();
    expect(find.text('Paused · release to play'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(hintBox, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('hints, buffering and scrubbing keep the controls mounted', (
    tester,
  ) async {
    final backend = await _open(tester, 7007010);
    final next = find.byTooltip('Next episode  (N)');
    final before = tester.state(next);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp); // volume: a hint
    await tester.pump();
    expect(find.text('100%'), findsOneWidget);
    expect(identical(tester.state(next), before), isTrue);
    backend.emit({'buffering': true}); // the spinner comes and goes
    await tester.pump();
    backend.emit({'buffering': false});
    await tester.pump();
    expect(identical(tester.state(next), before), isTrue);
    final seekBar = find.byType(Slider).first;
    // Scrubbing the seek bar moves the time with it, and letting go lands there.
    final bar = tester.getCenter(seekBar);
    final drag = await tester.startGesture(bar);
    await tester.pump();
    await drag.moveBy(const Offset(40, 0));
    await tester.pump();
    final scrubbing = tester.widget<Slider>(seekBar).value;
    expect(scrubbing, greaterThan(40000));
    expect(
      find.text(formatDuration(Duration(milliseconds: scrubbing.round()))),
      findsOneWidget,
    );
    await drag.up();
    await tester.pump();
    expect(tester.widget<Slider>(seekBar).value, scrubbing);
    await tester.pump(const Duration(seconds: 2)); // the hint goes
    expect(find.text('100%'), findsNothing);
    expect(identical(tester.state(next), before), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a volume drag rebuilds only the volume control', (tester) async {
    await _open(tester, 7007011);
    final next = find.byTooltip('Next episode  (N)');
    final before = tester.element(next);
    var builds = 0;
    final volume = find.byType(Slider).last;
    expect(tester.widget<Slider>(volume).value, 1);
    // Count rebuilds of a control beside the volume: none while dragging it.
    final watched = tester.widget(next);
    final drag = await tester.startGesture(tester.getCenter(volume));
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      await drag.moveBy(const Offset(-10, 0));
      await tester.pump();
      if (!identical(tester.widget(next), watched)) builds++;
    }
    await drag.up();
    await tester.pump();
    expect(builds, 0);
    expect(identical(tester.element(next), before), isTrue);
    final dragged = tester.widget<Slider>(volume).value;
    expect(dragged, lessThan(.75));
    // Keys still move it, with the hint, and M still mutes and restores.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    final up = ((dragged + .05).clamp(0.0, 1.0) * 100).round();
    expect(find.text('$up%'), findsOneWidget);
    expect(tester.widget<Slider>(volume).value, closeTo(dragged + .05, 1e-9));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(tester.widget<Slider>(volume).value, 0);
    expect(find.byTooltip('Unmute  (M)'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(tester.widget<Slider>(volume).value, closeTo(dragged + .05, 1e-9));
    expect(identical(tester.element(next), before), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });
}

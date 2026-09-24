import 'package:aniview/tv.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('OK taps on release and long-presses when held', (tester) async {
    var taps = 0, longPresses = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TvInput(child: child!),
        home: Scaffold(
          body: Center(
            child: InkWell(
              autofocus: true,
              onTap: () => taps++,
              onLongPress: () => longPresses++,
              child: const SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    expect(taps, 0); // not on press
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect((taps, longPresses), (1, 0));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect((taps, longPresses), (1, 1));
  });

  testWidgets('right leaves a text field for the button beside it', (
    tester,
  ) async {
    final mic = FocusNode();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TvInput(child: child!),
        home: Scaffold(
          appBar: AppBar(
            // Caret at the start, where Right would otherwise just move it.
            title: TextField(
              autofocus: true,
              controller: TextEditingController(text: 'naruto')
                ..selection = const TextSelection.collapsed(offset: 0),
            ),
            actions: [
              IconButton(
                focusNode: mic,
                onPressed: () {},
                icon: const Icon(Icons.mic),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(mic.hasPrimaryFocus, isTrue);
  });

  testWidgets('phone remote keys go through the app like the TV remote\'s', (
    tester,
  ) async {
    var taps = 0, longPresses = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TvInput(child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: InkWell(
                autofocus: true,
                onTap: () => taps++,
                onLongPress: () => longPresses++,
                child: const SizedBox(width: 100, height: 100),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.runAsync(() => pressKey('ok'));
    await tester.pump();
    expect((taps, longPresses), (1, 0));

    // The hold and the long press it triggers run on real timers.
    await tester.runAsync(() async {
      await pressKey('ok', hold: true);
      await Future.delayed(
        kLongPressTimeout + const Duration(milliseconds: 200),
      );
    });
    await tester.pumpAndSettle();
    expect((taps, longPresses), (1, 1));

    Navigator.of(tester.element(find.byType(Scaffold)))
        .push(MaterialPageRoute(builder: (_) => const Text('pushed')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => pressKey('back'));
    await tester.pumpAndSettle();
    expect(find.text('pushed'), findsNothing);
  });

  testWidgets(
    "a row's ends keep focus in the row; Left from its start goes to onLeftEdge",
    (tester) async {
      isTv = true;
      addTearDown(() => isTv = false);
      var edges = 0;
      onLeftEdge = () {
        edges++;
        return true;
      };
      addTearDown(() => onLeftEdge = null);
      final nodes = List.generate(3, (i) => FocusNode(debugLabel: 'card $i'));
      final below = FocusNode(debugLabel: 'below');
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => TvInput(child: child!),
          home: Scaffold(
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TvRow(
                  child: Row(
                    children: [
                      for (final (i, node) in nodes.indexed)
                        TextButton(
                          autofocus: i == 2,
                          focusNode: node,
                          onPressed: () {},
                          child: Text('card $i'),
                        ),
                    ],
                  ),
                ),
                // Further right than the row's end, on the row below.
                Padding(
                  padding: const EdgeInsets.only(left: 600),
                  child: TextButton(
                    focusNode: below,
                    onPressed: () {},
                    child: const Text('below'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(nodes[2].hasPrimaryFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(nodes[2].hasPrimaryFocus, isTrue); // not the button below

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(nodes[0].hasPrimaryFocus, isTrue);
      expect(edges, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(edges, 1);
    },
  );
}

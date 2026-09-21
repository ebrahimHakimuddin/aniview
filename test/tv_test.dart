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
        builder: (context, child) => FocusRing(child: child!),
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
}

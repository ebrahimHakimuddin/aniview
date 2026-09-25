import 'package:aniview/tv.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('on TV the D-pad moves through a picker and only OK chooses', (
    tester,
  ) async {
    isTv = true;
    addTearDown(() => isTv = false);
    double? picked;
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              picked = await pickOne(context, 'Speed', {
                .5: '0.5×',
                1.0: '1×',
                1.5: '1.5×',
                2.0: '2×',
              }, 1.0);
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(closed, isFalse); // moving isn't choosing
    expect(find.text('1.5×'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(picked, 1.5); // the one moved to, not the next again
  });
}

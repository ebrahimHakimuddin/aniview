import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decode widths step by 64 and never undershoot the box', () {
    expect(decodeWidth(0), 0);
    expect(decodeWidth(1), 64);
    expect(decodeWidth(232), 256);
    expect(decodeWidth(256), 256);
    // A box animating across a few pixels keeps one decode.
    expect(decodeWidth(241.3), decodeWidth(250.9));
  });

  testWidgets('tiles built while their list scrolls show without fading', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ListView.builder(
          itemCount: 100,
          itemBuilder: (_, i) => FadeIn(
            index: i,
            child: SizedBox(height: 100, child: Text('$i')),
          ),
        ),
      ),
    );
    double opacityOf(String label) => tester
        .widget<Opacity>(
          find.ancestor(of: find.text(label), matching: find.byType(Opacity)),
        )
        .opacity;
    expect(opacityOf('0'), 0); // arriving: fades in
    await tester.pumpAndSettle();
    final drag = await tester.startGesture(const Offset(400, 500));
    for (var i = 0; i < 10; i++) {
      await drag.moveBy(const Offset(0, -150));
      await tester.pump();
    }
    expect(opacityOf('15'), 1);
    await drag.up();
    await tester.pumpAndSettle();
  });
}

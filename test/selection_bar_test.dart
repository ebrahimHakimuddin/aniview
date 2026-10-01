import 'package:aniview/settings.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('the selection bar fits a small phone at double text size', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: SelectionBar(
              count: 128,
              onDone: () {},
              onAll: () {},
              actions: [
                for (final icon in const [
                  Icons.download_rounded,
                  Icons.delete_outline_rounded,
                  Icons.done_all_rounded,
                ])
                  IconButton(onPressed: () {}, icon: Icon(icon)),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull); // no overflow
    expect(find.text('128 selected'), findsOneWidget);
  });
}

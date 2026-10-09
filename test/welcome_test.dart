import 'package:aniview/settings.dart';
import 'package:aniview/welcome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('greets once over the app, then gets out of the way', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
    Widget app() => const MaterialApp(home: Welcome(child: Text('home')));
    await tester.pumpWidget(app());
    expect(find.text('home'), findsOneWidget); // loads underneath
    expect(find.text('Welcome back to AniView 🍿'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Welcome back to AniView 🍿'), findsNothing);

    // Rebuilt (a layout change): not again.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    expect(find.text('Welcome back to AniView 🍿'), findsNothing);
  });
}

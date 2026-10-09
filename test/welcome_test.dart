import 'package:aniview/settings.dart';
import 'package:aniview/welcome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

var _built = 0;

class _Home extends StatefulWidget {
  const _Home();
  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  @override
  void initState() {
    super.initState();
    _built++; // home's first-launch work (What's new) runs here
  }

  @override
  Widget build(BuildContext context) => const Text('home');
}

void main() {
  testWidgets('greets once over the app, then gets out of the way', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
    Widget app() => const MaterialApp(home: Welcome(child: _Home()));
    await tester.pumpWidget(app());
    expect(find.text('home'), findsOneWidget); // loads underneath
    expect(find.text('Welcome back to AniView 🍿'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Welcome back to AniView 🍿'), findsNothing);
    expect(_built, 1); // the greeting going didn't build home again

    // Rebuilt (a layout change): not again.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    expect(find.text('Welcome back to AniView 🍿'), findsNothing);
  });
}

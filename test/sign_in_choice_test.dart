import 'package:aniview/settings.dart';
import 'package:aniview/tracker.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Account implements ListProvider {
  _Account(this.name);
  @override
  final String name;
  @override
  bool signedIn = false;
  int logins = 0;
  @override
  bool get usable => true;
  @override
  String get pendingKey => '${name}_pending';
  @override
  int? idOf(Map media) => 1;
  @override
  Future<void> login(BuildContext context) async {
    logins++;
    signedIn = true;
  }

  @override
  Future<void> logout() async => signedIn = false;
  @override
  Future<Map<String, dynamic>?> viewer() async => {'name': '$name viewer'};
  @override
  Future<Map<String, dynamic>?> stats() async => null;
  @override
  Future<Map<String, List>> lists({bool all = false}) async => {};
  @override
  Future<int> progressOf(int id) async => 0;
  @override
  Future<void> save(
    int id, {
    required String status,
    required int progress,
  }) async {}
  @override
  Future<void> remove(int id) async {}
}

void main() {
  for (final chosen in ['AniList', 'MyAnimeList']) {
    testWidgets('a generic sign-in prompt can sign in with $chosen', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await Settings.load();
      await Tracker.load();
      final old = Tracker.accounts;
      final ani = _Account('AniList'), mal = _Account('MyAnimeList');
      Tracker.accounts = [ani, mal];
      addTearDown(() => Tracker.accounts = old);
      String? name;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => name = await Tracker.signIn(context),
                child: const Text('Sign in'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(find.text('Sign in with AniList'), findsOneWidget);
      expect(find.text('Sign in with MyAnimeList'), findsOneWidget);
      await tester.tap(find.text('Sign in with $chosen'));
      await tester.pumpAndSettle();
      expect(name, '$chosen viewer');
      expect(Tracker.account?.name, chosen);
      expect(chosen == 'AniList' ? mal.logins : ani.logins, 0);
    });
  }

  testWidgets('signing in to the other account switches, once confirmed', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
    final old = Tracker.accounts;
    final ani = _Account('AniList')..signedIn = true;
    final mal = _Account('MyAnimeList');
    Tracker.accounts = [ani, mal];
    addTearDown(() => Tracker.accounts = old);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Tracker.signIn(context, mal),
              child: const Text('Sign in'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(Tracker.account, ani);
    expect(mal.logins, 0);

    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Switch'));
    await tester.pumpAndSettle();
    expect(Tracker.account, mal);
    expect(ani.signedIn, isFalse);
  });
}

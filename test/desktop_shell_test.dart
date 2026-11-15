import 'package:aniview/anilist.dart';
import 'package:aniview/desktop.dart';
import 'package:aniview/desktop/shell.dart';
import 'package:aniview/history.dart';
import 'package:aniview/home_feed.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/tracker.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Empty implements Catalog {
  @override
  bool get usable => true;
  @override
  Future<List> trending() async => [];
  @override
  Future<List> season() async => [];
  @override
  Future<(List, bool)> search(
    String text,
    SearchFilters filters,
    int page,
  ) async => (<dynamic>[], false);
  @override
  Future<List<(String, Map)>> relations(Map media) async => [];
}

class _Source implements HomeSource {
  @override
  bool get signedIn => false;
  @override
  Future<Map<String, dynamic>?> viewer() async => null;
  @override
  Future<Map<String, List>> lists({bool all = false}) async => {};
  @override
  Future<List> trending() async => [];
  @override
  Future<List> season() async => [];
  @override
  Future<Map<String, dynamic>?> stats() async => null;
  @override
  Future<List<Map>> airingAround(Iterable<int> ids) async => [];
  @override
  Future<List<Map>> airingPopular() async => [];
  @override
  Future<List<WatchRecord>> history() async => [];
}

/// Counts its builds.
class _Page extends StatelessWidget {
  const _Page(this.onBuild);

  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return const SizedBox.expand();
  }
}

void main() {
  testWidgets('a push or pop in the shell does not rebuild the pages under it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
    Tracker.primary = _Empty();
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: DeskShell(
          feed: HomeFeed(source: _Source()),
          onRefresh: () async {},
          onReload: ({bool force = false, bool checkStale = false}) {},
          onSignIn: () {},
          actions: const [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    var builds = 0;
    final nav = Navigator.of(deskPageContext!()!);
    nav.push(MaterialPageRoute<void>(builder: (_) => _Page(() => builds++)));
    await tester.pumpAndSettle();
    final settled = builds;

    nav.push(MaterialPageRoute<void>(builder: (_) => const SizedBox()));
    await tester.pumpAndSettle();
    nav.pop();
    await tester.pumpAndSettle();
    // Once when pushed; the shell used to rebuild it again after its own push, and after each push and pop above it.
    expect(settled, 1);
    expect(builds, 1);
    // The back button still follows the stack.
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byIcon(Icons.arrow_back_rounded),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNotNull,
    );
  });
}

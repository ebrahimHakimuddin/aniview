import 'dart:convert';
import 'dart:io';

import 'package:aniview/desktop/downloads.dart';
import 'package:aniview/downloads.dart';
import 'package:aniview/downloads_screen.dart';
import 'package:aniview/platform.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/tv.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _mb = 1 << 20;

Download _download(
  int show,
  int number,
  DownloadStatus status, {
  double progress = 0,
  int bytes = 0,
}) => Download(
  media: {
    'id': show,
    'title': {'romaji': show == 1 ? 'Alpha' : 'Beta'},
  },
  source: 'Anikoto',
  number: number,
  dub: false,
  ref: '$show/$number',
  status: status,
  progress: progress,
  bytes: bytes,
);

/// Alpha: episode 1 downloading (25%, 10 MB), 2 done (100 MB), 3 failed. Beta: two done (200 MB each).
List<Download> _library() => [
  _download(1, 1, DownloadStatus.downloading, progress: .25, bytes: 10 * _mb),
  _download(1, 2, DownloadStatus.done, progress: 1, bytes: 100 * _mb),
  _download(1, 3, DownloadStatus.failed),
  _download(2, 1, DownloadStatus.done, progress: 1, bytes: 200 * _mb),
  _download(2, 2, DownloadStatus.done, progress: 1, bytes: 200 * _mb),
];

/// Straight into the store's list, as a loaded library would be, with nothing on disk and nothing downloading.
Download _seed(WidgetTester tester) {
  Downloads.instance.items
    ..clear()
    ..addAll(_library());
  addTearDown(Downloads.instance.items.clear);
  return Downloads.instance.items.first;
}

/// What a running download does each time it reports progress.
void _progress(Download d, double progress, int bytes) {
  d
    ..progress = progress
    ..bytes = bytes;
  Downloads.instance.debugProgressed(d);
}

/// The widgets rebuilt by [action] and the frame after it.
Future<List<Widget>> _rebuiltBy(
  WidgetTester tester,
  void Function() action,
) async {
  final rebuilt = <Widget>[];
  debugOnRebuildDirtyWidget = (element, _) => rebuilt.add(element.widget);
  try {
    action();
    await tester.pump();
  } finally {
    debugOnRebuildDirtyWidget = null;
  }
  return rebuilt;
}

Set<String> _types(List<Widget> widgets) => {
  for (final w in widgets) w.runtimeType.toString(),
};

Set<String?> _texts(List<Widget> widgets) => {
  for (final w in widgets.whereType<Text>()) w.data,
};

double? _bar(WidgetTester tester) => tester
    .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
    .value;

void main() {
  testWidgets(
    'Down from the filter chips walks the lazy list past the first screen on a TV',
    (tester) async {
      isTv = true;
      addTearDown(() => isTv = false);
      final parent = Directory.systemTemp.createTempSync(
        'aniview_tv_downloads',
      );
      addTearDown(() => parent.deleteSync(recursive: true));
      final root = Directory('${parent.path}/AniView')..createSync();
      SharedPreferences.setMockInitialValues({
        'desktop_download_folder': parent.path,
      });
      await tester.runAsync(() async {
        // Failed, so nothing starts downloading; each row keeps a focusable Retry.
        await DownloadStore(root).write(
          jsonEncode([
            for (var n = 1; n <= 40; n++)
              Download(
                media: {
                  'id': 1,
                  'title': {'romaji': 'Show'},
                },
                source: 'Anikoto',
                number: n,
                dub: false,
                ref: '$n',
                status: DownloadStatus.failed,
              ).toJson(),
          ]),
        );
        await Settings.load();
        await Downloads.instance.load();
      });
      expect(Downloads.instance.items, hasLength(40));

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => TvInput(child: child!),
          home: const DownloadsScreen(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Episode 40'), findsNothing); // not built yet: lazy
      Focus.of(tester.element(find.text('All · 40'))).requestFocus();
      await tester.pumpAndSettle();

      String? focusedRow() =>
          (FocusManager.instance.primaryFocus?.context
                      ?.findAncestorWidgetOfExactType<ListTile>()
                      ?.title
                  as Text?)
              ?.data;
      for (var i = 0; i < 45 && focusedRow() != 'Episode 40'; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      expect(focusedRow(), 'Episode 40');
    },
  );

  group('phone downloads, while one downloads', () {
    Future<Download> open(WidgetTester t) async {
      SharedPreferences.setMockInitialValues({});
      await Settings.load();
      final active = _seed(t);
      await t.pumpWidget(
        MaterialApp(theme: buildTheme(), home: const DownloadsScreen()),
      );
      await t.pumpAndSettle();
      return active;
    }

    testWidgets('a progress tick redraws that row’s progress and the totals, '
        'not the other rows or the list', (t) async {
      final active = await open(t);
      expect(find.text('25% · 10.0 MB'), findsOneWidget);
      expect(find.text('5 episodes · 510.0 MB on this device'), findsOneWidget);

      final rebuilt = await _rebuiltBy(
        t,
        () => _progress(active, .5, 20 * _mb),
      );

      expect(find.text('50% · 20.0 MB'), findsOneWidget);
      expect(_bar(t), .5);
      expect(find.text('5 episodes · 520.0 MB on this device'), findsOneWidget);
      expect(find.text('3 episodes · 120.0 MB'), findsOneWidget); // Alpha
      expect(find.text('2 episodes · 400.0 MB'), findsOneWidget); // Beta
      final types = _types(rebuilt);
      for (final type in [
        'DownloadsScreen',
        'ListView',
        '_ShowHeader',
        '_DownloadTile',
        'ListTile',
        'ChoiceChip',
      ]) {
        expect(types, isNot(contains(type)), reason: '$type was rebuilt');
      }
      expect(_texts(rebuilt), {
        '50% · 20.0 MB',
        '3 episodes · 120.0 MB',
        '5 episodes · 520.0 MB on this device',
      });
      expect(rebuilt.length, lessThan(30), reason: '${_types(rebuilt)}');
    });

    testWidgets('a change to the list still redraws the list, counts and empty '
        'state', (t) async {
      final active = await open(t);
      expect(find.text('In progress · 1'), findsOneWidget);

      // Finished: its row, the chips and the totals follow.
      active
        ..status = DownloadStatus.done
        ..progress = 1
        ..bytes = 300 * _mb;
      Downloads.instance.debugChanged();
      await t.pumpAndSettle();
      expect(find.text('300.0 MB · Sub · Anikoto'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('In progress · 1'), findsNothing);
      expect(find.text('Done · 4'), findsOneWidget);
      expect(find.text('5 episodes · 800.0 MB on this device'), findsOneWidget);

      // A new one starts: it gets its own row, and its ticks reach that row.
      final next = _download(1, 4, DownloadStatus.downloading);
      Downloads.instance.items.add(next);
      Downloads.instance.debugChanged();
      await t.pumpAndSettle();
      expect(find.text('In progress · 1'), findsOneWidget);
      expect(find.text('6 episodes · 800.0 MB on this device'), findsOneWidget);
      _progress(next, .1, 5 * _mb);
      await t.pump();
      expect(find.text('10% · 5.0 MB'), findsOneWidget);
      expect(find.text('6 episodes · 805.0 MB on this device'), findsOneWidget);

      // A filter shows only its own.
      await t.tap(find.text('Failed · 1'));
      await t.pumpAndSettle();
      expect(find.text('Download failed'), findsOneWidget);
      expect(find.text('Episode 2'), findsNothing);

      // Removing the last failed one empties that filter, which falls back to All.
      Downloads.instance.items.remove(Downloads.instance.items[2]);
      Downloads.instance.debugChanged();
      await t.pumpAndSettle();
      expect(find.text('Failed · 1'), findsNothing);
      expect(find.text('All · 5'), findsOneWidget);
      expect(find.text('Episode 2'), findsOneWidget);

      Downloads.instance.items.clear();
      Downloads.instance.debugChanged();
      await t.pumpAndSettle();
      expect(find.text('No downloads yet'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  testWidgets(
    'a hold picks episodes, a show\'s header all of them, for one delete',
    (t) async {
      SharedPreferences.setMockInitialValues({});
      await Settings.load();
      _seed(t);
      await t.pumpWidget(
        MaterialApp(theme: buildTheme(), home: const DownloadsScreen()),
      );
      await t.pumpAndSettle();
      expect(find.text('Downloads'), findsOneWidget);

      await t.longPress(find.text('Episode 2'));
      await t.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      expect(
        find.text('Downloads'),
        findsNothing,
      ); // the bar stands in for the title
      expect(
        find.byTooltip('Delete'),
        findsNothing,
      ); // rows lose their own buttons

      // While picking a tap picks, rather than playing.
      await t.tap(find.text('Episode 1').first);
      await t.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);
      await t.tap(find.text('Episode 1').first);
      await t.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      // A show's header picks all of its episodes, and again unpicks them.
      await t.tap(find.text('Beta'));
      await t.pumpAndSettle();
      expect(find.text('3 selected'), findsOneWidget);
      await t.tap(find.text('Beta'));
      await t.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      // Picking the failed one offers a retry; All picks everything the filter shows.
      await t.tap(find.text('Episode 3'));
      await t.pumpAndSettle();
      expect(find.byTooltip('Retry 1'), findsOneWidget);
      await t.tap(find.text('All'));
      await t.pumpAndSettle();
      expect(find.text('5 selected'), findsOneWidget);

      await t.tap(find.byTooltip('Delete 5'));
      await t.pumpAndSettle();
      expect(find.text('Delete 5 downloads?'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(find.text('5 selected'), findsOneWidget);
      expect(Downloads.instance.items, hasLength(5));

      // Back ends picking rather than leaving.
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.text('Downloads'), findsOneWidget);
      expect(find.textContaining('selected'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  group('desktop downloads, while one downloads', () {
    Future<Download> open(WidgetTester t) async {
      final oldDesktop = isDesktop;
      isDesktop = true;
      addTearDown(() => isDesktop = oldDesktop);
      t.view.physicalSize = const Size(1600, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      SharedPreferences.setMockInitialValues({});
      await Settings.load();
      final active = _seed(t);
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(body: DeskDownloads(onBrowse: () {})),
        ),
      );
      await t.pumpAndSettle();
      return active;
    }

    testWidgets('a progress tick redraws that row’s progress and the totals, '
        'not the header’s buttons, the chips, the cards or the other rows', (
      t,
    ) async {
      final active = await open(t);
      expect(find.text('25% · 10.0 MB'), findsOneWidget);

      final rebuilt = await _rebuiltBy(
        t,
        () => _progress(active, .5, 20 * _mb),
      );

      expect(find.text('50% · 20.0 MB'), findsOneWidget);
      expect(_bar(t), .5);
      expect(find.text('5 episodes · 520.0 MB on this device'), findsOneWidget);
      expect(find.text('3 episodes · 120.0 MB'), findsOneWidget);
      expect(find.text('2 episodes · 400.0 MB'), findsOneWidget);
      final types = _types(rebuilt);
      for (final type in [
        'DeskDownloads',
        'ListView',
        '_ShowCard',
        '_Episode',
        'Hover',
        'TextButton',
        'IconButton',
      ]) {
        expect(types, isNot(contains(type)), reason: '$type was rebuilt');
      }
      expect(_texts(rebuilt), {
        '50% · 20.0 MB',
        '3 episodes · 120.0 MB',
        'Downloads', // the header's title, beside the note
        '5 episodes · 520.0 MB on this device',
      });
      expect(rebuilt.length, lessThan(40), reason: '${_types(rebuilt)}');
    });

    testWidgets('a change to the list still redraws the list, counts and empty '
        'state', (t) async {
      final active = await open(t);
      expect(find.text('In progress · 1'), findsOneWidget);

      active
        ..status = DownloadStatus.done
        ..progress = 1
        ..bytes = 300 * _mb;
      Downloads.instance.debugChanged();
      await t.pumpAndSettle();
      expect(find.text('300.0 MB · Sub · Anikoto'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('In progress · 1'), findsNothing);
      expect(find.text('Done · 4'), findsOneWidget);
      expect(find.text('5 episodes · 800.0 MB on this device'), findsOneWidget);
      expect(find.text('3 episodes · 400.0 MB'), findsOneWidget);

      final next = _download(2, 3, DownloadStatus.downloading);
      Downloads.instance.items.add(next);
      Downloads.instance.debugChanged();
      await t.pumpAndSettle();
      expect(find.text('3 episodes · 400.0 MB'), findsNWidgets(2));
      _progress(next, .1, 5 * _mb);
      await t.pump();
      expect(find.text('10% · 5.0 MB'), findsOneWidget);
      expect(find.text('3 episodes · 405.0 MB'), findsOneWidget); // Beta now
      expect(find.text('6 episodes · 805.0 MB on this device'), findsOneWidget);

      await t.tap(find.text('Failed · 1'));
      await t.pumpAndSettle();
      expect(find.text('Download failed'), findsOneWidget);
      expect(find.text('10% · 5.0 MB'), findsNothing);

      Downloads.instance.items.remove(Downloads.instance.items[2]);
      Downloads.instance.debugChanged();
      await t.pumpAndSettle();
      expect(find.text('Failed · 1'), findsNothing);
      expect(find.text('All · 5'), findsOneWidget);
      expect(find.text('10% · 5.0 MB'), findsOneWidget);

      Downloads.instance.items.clear();
      Downloads.instance.debugChanged();
      await t.pumpAndSettle();
      expect(find.text('No downloads yet'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });
}

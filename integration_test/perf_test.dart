// Frame-timing scenarios for AniView, run in profile mode on any device:
//
//   flutter drive --profile -d <device> \
//     --driver=test_driver/perf_driver.dart --target=integration_test/perf_test.dart
//
// Each scenario is wrapped in IntegrationTestWidgetsFlutterBinding.watchPerformance, which reports the frame build
// and raster times of every frame drawn during it under the scenario's name; test_driver/perf_driver.dart writes them
// to disk. Every scenario uses fake data (integration_test/perf_fixtures.dart): posters drawn on the device into the
// app's poster cache, a fake catalog and site, a loopback server for downloads, and a guard that answers any other
// request 404, so runs are repeatable and nothing depends on the internet.
//
// One file for every form factor: a scenario that only makes sense on one (mouse hover, window resize) records
// {"skipped": "<why>"} elsewhere. --dart-define=PERF_ONLY=home_scroll,hover_sweep runs a subset.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:aniview/anilist.dart';
import 'package:aniview/changelog.dart';
import 'package:aniview/desktop.dart';
import 'package:aniview/details.dart';
import 'package:aniview/downloads.dart';
import 'package:aniview/downloads_screen.dart';
import 'package:aniview/exo.dart';
import 'package:aniview/main.dart';
import 'package:aniview/platform.dart';
import 'package:aniview/player.dart';
import 'package:aniview/search.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/tracker.dart';
import 'package:aniview/tv.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'perf_fixtures.dart';

const _only = String.fromEnvironment('PERF_ONLY');

/// --dart-define=PERF_TRACE=true: after nav_push_pop's timed opens, untimed ones that report what their slow frames
/// were made of (see [_traceFrames]). Off by default.
const _trace = bool.fromEnvironment('PERF_TRACE');

/// The desktop window the scenarios start from, in logical pixels.
const _desktopWindow = Size(1600, 1000);

late final IntegrationTestWidgetsFlutterBinding _binding;
late final FakeSite _site;
late final SlowFileServer _files;
late final LocalOnlyClient _guard;
late final Directory _scratch;

String get _formFactor => isTv
    ? 'tv'
    : isDesktop
    ? 'desktop'
    : 'phone';

void main() {
  _binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Frames come when the app asks for them, as in the real app, not when the test pumps.
  _binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  setUpAll(() async {
    _guard = guardNetwork();
    _scratch = Directory(
      '${(await getTemporaryDirectory()).path}/aniview_perf_$pid',
    );
    if (await _scratch.exists()) await _scratch.delete(recursive: true);
    await _scratch.create(recursive: true);
    final downloads = Directory('${_scratch.path}/downloads')..createSync();
    // In memory: the scenarios never read or change the device's real settings.
    SharedPreferences.setMockInitialValues({
      'changelog_seen': changelogVersion,
      'welcome': false,
      'resume': false,
      'desktop_download_folder': downloads.path,
      'analytics': false, // no survey, no events
      'subscription_survey_v1': 'answered',
      'subscription_survey_beta_v2': 'answered',
    });
    await Settings.load();
    await detectTv(layout: Settings.layout);
    // The phone player's swipes (seek, brightness, volume) are off by default; the phone scenarios swipe.
    if (_formFactor == 'phone') Settings.swipeGestures = true;
    _site = FakeSite();
    Sites.load = () async => [_site];
    Sites.reload();
    ExtensionHost.current = NoExtensions();
    Tracker.primary = FakeCatalog();
    configureQuality = (_, _) async => const [];
    _files = await SlowFileServer.start();
    _site.server = _files.uri;
    await seedPosters(Directory('${_scratch.path}/posters'));
    await _writeDownloads(const []);
    if (isDesktop) {
      await windowManager.ensureInitialized();
      await windowManager.setSize(_desktopWindow);
    }
    _binding.reportData = {
      'meta': <String, Object?>{
        'form_factor': _formFactor,
        'os': Platform.operatingSystem,
        'os_version': Platform.operatingSystemVersion,
        'started': DateTime.now().toIso8601String(),
        'display_refresh_rate':
            _binding.platformDispatcher.displays.firstOrNull?.refreshRate,
      },
    };
  });

  tearDownAll(() async {
    (_binding.reportData!['meta'] as Map)['blocked_requests'] =
        _guard.blocked.length;
    await _files.close();
    try {
      await _scratch.delete(recursive: true);
    } catch (_) {}
  });

  _scenario('home_scroll', (tester) async {
    await _openApp(tester);
    final list = _mainScroll(tester);
    await _measure('home_scroll', () async {
      for (var i = 0; i < 3; i++) {
        await list.animateTo(
          list.maxScrollExtent,
          duration: const Duration(milliseconds: 1400),
          curve: Curves.easeInOut,
        );
        await list.animateTo(
          0,
          duration: const Duration(milliseconds: 1400),
          curve: Curves.easeInOut,
        );
      }
    });
  });

  _scenario('row_scroll', (tester) async {
    await _openApp(tester);
    final rows = _scrollables(
      tester,
      Axis.horizontal,
    ).where((p) => p.maxScrollExtent > 0).take(3).toList();
    if (rows.isEmpty) throw StateError('No poster row to scroll');
    await _measure('row_scroll', () async {
      for (final row in rows) {
        await row.animateTo(
          row.maxScrollExtent,
          duration: const Duration(milliseconds: 1200),
          curve: Curves.easeInOut,
        );
        await row.animateTo(
          0,
          duration: const Duration(milliseconds: 1200),
          curve: Curves.easeInOut,
        );
      }
    });
  });

  _scenario('grid_scroll', (tester) async {
    await _openGrid(tester);
    final grid = _mainScroll(tester);
    await _measure('grid_scroll', () async {
      // Each pass reaches further as more pages load; the last pages are already in by the third.
      for (var i = 0; i < 3; i++) {
        await grid.animateTo(
          grid.maxScrollExtent,
          duration: const Duration(milliseconds: 1600),
          curve: Curves.easeInOut,
        );
        await _wait(const Duration(milliseconds: 300));
        await grid.animateTo(
          0,
          duration: const Duration(milliseconds: 1600),
          curve: Curves.easeInOut,
        );
      }
    });
  });

  // Fix 2: the surface the app lays out in shrinks and grows a few pixels a frame, as a window being dragged does.
  // setSurfaceSize changes what the app lays out at; the live binding scales the result into the real surface, so
  // it works on every device.
  _scenario('resize_sweep', (tester) async {
    await _openGrid(tester);
    final full = tester.view.physicalSize / tester.view.devicePixelRatio;
    final cache = PaintingBinding.instance.imageCache;
    cache
      ..maximumSize = 100000
      ..maximumSizeBytes = 2 << 30
      ..clear();
    await _wait(
      const Duration(milliseconds: 1500),
    ); // posters decoded again at this size
    final before = cache.currentSize;
    await _measure('resize_sweep', () async {
      for (var pass = 0; pass < 2; pass++) {
        for (var w = full.width; w >= full.width * .6; w -= 6) {
          await _binding.setSurfaceSize(Size(w, full.height));
          await tester.pump();
        }
        for (var w = full.width * .6; w <= full.width; w += 6) {
          await _binding.setSurfaceSize(Size(w, full.height));
          await tester.pump();
        }
      }
      await _binding.setSurfaceSize(null);
      await _wait(const Duration(milliseconds: 800));
    });
    _note('resize_sweep', {
      'image_cache_entries_before': before,
      'image_cache_entries_after': cache.currentSize,
      'image_cache_mb_after': cache.currentSizeBytes / (1 << 20),
      'decoded_during_sweep': cache.currentSize - before,
    });
    cache
      ..clear()
      ..maximumSize = 1000
      ..maximumSizeBytes = 100 << 20;
  });

  // Fix 2 again, through the real window: desktop only.
  _scenario(
    'window_resize_sweep',
    skip: () => !isDesktop ? 'needs a resizable window' : null,
    (tester) async {
      await _openGrid(tester);
      final cache = PaintingBinding.instance.imageCache;
      cache
        ..maximumSize = 100000
        ..maximumSizeBytes = 2 << 30
        ..clear();
      await _wait(const Duration(milliseconds: 1500));
      final before = cache.currentSize;
      final widths = <double>{};
      await _measure('window_resize_sweep', () async {
        for (var w = _desktopWindow.width; w >= 1000; w -= 8) {
          await windowManager.setSize(Size(w, _desktopWindow.height));
          await _wait(const Duration(milliseconds: 16));
          widths.add(tester.view.physicalSize.width);
        }
        for (var w = 1000.0; w <= _desktopWindow.width; w += 8) {
          await windowManager.setSize(Size(w, _desktopWindow.height));
          await _wait(const Duration(milliseconds: 16));
        }
        await _wait(const Duration(milliseconds: 800));
      });
      _note('window_resize_sweep', {
        'image_cache_entries_before': before,
        'image_cache_entries_after': cache.currentSize,
        'decoded_during_sweep': cache.currentSize - before,
        'window_after': _wh(await windowManager.getSize()),
        // Proof the window really moved: the narrowest the app was laid out at, and how many widths it saw.
        'narrowest_physical_width': widths.reduce(math.min),
        'distinct_widths_seen': widths.length,
      });
      cache
        ..clear()
        ..maximumSize = 1000
        ..maximumSizeBytes = 100 << 20;
      await windowManager.setSize(_desktopWindow);
    },
  );

  // Fix 3: a show page pushed over Home and popped again, five times.
  _scenario('nav_push_pop', (tester) async {
    await _openApp(tester);
    await _measure('nav_push_pop', () async {
      for (var i = 0; i < 5; i++) {
        final closed = openDetails(_pageContext(tester), fakeShow(i));
        await _wait(const Duration(milliseconds: 1200));
        _back(tester);
        await closed;
        await _wait(const Duration(milliseconds: 900));
      }
    });
    if (!_trace) return;
    // Untimed: what the slow frames of an open are made of. Shows not opened above, so their art decodes afresh, as
    // the timed opens' did. First the frame phases with the engine's own timeline (raster thread included), then
    // again with every widget build, layout and paint timed, which slows those frames and is only read for shares.
    Future<void> opens(List<int> shows, void Function(String) mark) async {
      for (final i in shows) {
        mark('push $i');
        final closed = openDetails(_pageContext(tester), fakeShow(i));
        await _wait(const Duration(milliseconds: 1200));
        mark('pop $i');
        _back(tester);
        await closed;
        await _wait(const Duration(milliseconds: 900));
      }
    }

    final report = _binding.reportData!['nav_push_pop'] as Map;
    report['trace_phases'] = await _traceFrames(
      (mark) => opens([40, 41, 42], mark),
      engine: true,
    );
    report['trace_widgets'] = await _traceFrames(
      (mark) => opens([43, 44], mark),
      widgets: true,
    );
  });

  // Fix 6: a mouse moving along a poster row and across the banner.
  _scenario('hover_sweep', skip: () => !isDesktop ? 'needs a mouse' : null, (
    tester,
  ) async {
    await _openApp(tester);
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    // The first poster row scrolled wholly on screen, then the banner above it.
    final list = _mainScroll(tester);
    final height =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final cut = _rows(tester).first.bottom - height + 24;
    if (cut > 0) {
      list.jumpTo(cut);
      await _wait(const Duration(milliseconds: 400));
    }
    final y = _rowY(tester);
    // Across the banner where it's still on screen, else the next row down.
    final top = _posters(tester).first;
    final banner = top.height < 400
        ? y + top.height + 60
        : math.max(top.top, 80.0) + 80;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset(4, y));
    await _wait(const Duration(milliseconds: 300));
    await _measure('hover_sweep', () async {
      for (var pass = 0; pass < 2; pass++) {
        for (var x = 4.0; x < width - 4; x += 6) {
          await mouse.moveTo(Offset(x, y));
          await _wait(const Duration(milliseconds: 8)); // a 125 Hz mouse
        }
        for (var x = width - 4; x > 4; x -= 6) {
          await mouse.moveTo(Offset(x, banner));
          await _wait(const Duration(milliseconds: 8));
        }
      }
    });
    await mouse.removePointer();
  });

  // Fix 5: picking episodes on a show page, then unpicking them. TV has no picking: holding OK opens one
  // episode's actions (lib/details.dart, `picking = picked.active && !isTv`).
  _scenario(
    'details_selection',
    skip: () => isTv ? 'TV has no episode picking' : null,
    (tester) async {
      _site.episodeCount = 60;
      await _openApp(tester);
      // A finished show on phones: a releasing one's page lists only the episodes out so far (10 of show 3's 60),
      // too few to pick a page of. Desktop keeps the show its earlier runs used.
      final shown = _formFactor == 'phone' ? 4 : 3;
      unawaited(
        openDetails(_pageContext(tester), fakeShow(shown, episodes: 60)),
      );
      await _wait(const Duration(milliseconds: 2500));
      var rows = _episodeRows();
      // On a phone the list starts below the fold (and is built lazily): the page scrolled until rows show.
      for (var i = 0; i < 12 && rows.isEmpty; i++) {
        final page = _mainScroll(tester);
        page.jumpTo(math.min(page.pixels + 300, page.maxScrollExtent));
        await _wait(const Duration(milliseconds: 300));
        rows = _episodeRows();
      }
      if (rows.isEmpty) throw StateError('No episode rows: ${_texts()}');
      // The list to the top of the page, so a screenful of rows can be picked.
      await Scrollable.ensureVisible(
        tester.element(_row(rows.first)),
        alignment: .02,
      );
      await _wait(const Duration(milliseconds: 500));
      rows = _episodeRows();
      final first = rows.first;
      final unchecked = find.byIcon(Icons.radio_button_unchecked_rounded);
      final checked = find.byIcon(Icons.check_circle_rounded);
      TestGesture? mouse;
      final picks = <String>[];
      // What each round saw, for reading a run that picked fewer than meant.
      final rounds = <String>[];
      await _measure('details_selection', () async {
        if (isDesktop) {
          // Hovering a row shows its box; clicking it starts picking.
          mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
          await mouse!.addPointer(location: tester.getCenter(_row(first)));
          await _wait(const Duration(milliseconds: 300));
          await _click(tester, unchecked.hitTestable().first);
        } else {
          await tester.longPress(_row(first));
          await _wait(const Duration(milliseconds: 400));
        }
        picks.add(first);
        // While picking, every desktop row shows its box; a phone row is picked by tapping it. A screenful, then the
        // page scrolls on for more.
        final page = _mainScroll(tester);
        final start = page.pixels;
        for (var round = 0; round < 3 && picks.length < 24; round++) {
          rounds.add(
            'pick $round: ${_episodeRows().length} rows, at ${page.pixels.round()}/${page.maxScrollExtent.round()}',
          );
          for (final row in _episodeRows()) {
            if (picks.length >= 24) break;
            if (isDesktop) {
              final box = unchecked.hitTestable();
              if (box.evaluate().isEmpty) break;
              await _click(tester, box.first);
              picks.add('box');
            } else if (!picks.contains(row)) {
              await _click(tester, _row(row));
              picks.add(row);
            }
          }
          await page.animateTo(
            page.pixels + 450,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
          await _wait(const Duration(milliseconds: 200));
        }
        // And all unpicked again, from the bottom up.
        for (var round = 0; round < 6; round++) {
          rounds.add(
            'unpick $round: ${checked.hitTestable().evaluate().length} checked, at ${page.pixels.round()}',
          );
          for (var k = 0; k < 12; k++) {
            final box = checked.hitTestable();
            if (box.evaluate().isEmpty) break;
            await _click(tester, box.first);
          }
          // A phone's first pick can sit under the page's pinned header at the start offset: on up then.
          final more = !isDesktop && checked.evaluate().isNotEmpty;
          if (page.pixels <= (more ? 0 : start)) break;
          await page.animateTo(
            math.max(more ? 0.0 : start, page.pixels - 450),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
          await _wait(const Duration(milliseconds: 200));
        }
      });
      _note('details_selection', {
        'picked': picks.length,
        'left_picked': checked.evaluate().length,
        'rounds': rounds,
      });
      await mouse?.removePointer();
      _site.episodeCount = 24;
    },
  );

  // Fix 4: the downloads list, with 240 entries, while three episodes download from a loopback server that sends
  // a chunk every few ms.
  _scenario('downloads_progress', (tester) async {
    await _writeDownloads(_failedLibrary());
    await _openApp(tester);
    if (isDesktop) {
      await _click(tester, find.text('Downloads').hitTestable().first);
    } else {
      unawaited(
        Navigator.of(_pageContext(tester)).push(
          MaterialPageRoute<void>(builder: (_) => const DownloadsScreen()),
        ),
      );
    }
    await _wait(const Duration(milliseconds: 1200));
    final notified = await _countNotifications(
      () => _measure('downloads_progress', () async {
        _download(fakeShow(0), [1, 2, 3]);
        await _untilDownloaded(const Duration(seconds: 30));
      }),
    );
    final extra = <String, Object?>{...notified, 'files_served': _files.served};
    // One more episode with the framework counting builds, after the timed part (counting slows every build).
    final counted = await _countDownloadBuilds(fakeShow(0), [4]);
    _noteTop('downloads_progress', counted.builds);
    _note('downloads_progress', {
      ...extra,
      ...counted.notes,
      ..._buildsOf(counted.builds, [
        'DeskHeader',
        '_ShowCard',
        '_Episode',
        '_DownloadTile',
        '_ShowHeader',
        'LinearProgressIndicator',
        'Text',
      ]),
    });
    await _writeDownloads(const []);
  });

  // Fix 4, from a show page: every episode row looks itself up on each progress update.
  _scenario('details_download_progress', (tester) async {
    await _writeDownloads(_failedLibrary());
    _site.episodeCount = 60;
    await _openApp(tester);
    final show = fakeShow(0, episodes: 60);
    unawaited(openDetails(_pageContext(tester), show));
    await _wait(const Duration(milliseconds: 2500));
    final notified = await _countNotifications(
      () => _measure('details_download_progress', () async {
        _download(show, [4, 5, 6]);
        await _untilDownloaded(const Duration(seconds: 30));
      }),
    );
    final counted = await _countDownloadBuilds(show, [7]);
    _noteTop('details_download_progress', counted.builds);
    _note('details_download_progress', {
      ...notified,
      ...counted.notes,
      ..._buildsOf(counted.builds, [
        '_DownloadButton',
        'IconButton',
        'CircularProgressIndicator',
        'ListTile',
      ]),
    });
    _site.episodeCount = 24;
    await _writeDownloads(const []);
  });

  // Fix 1: the player's controls over a fake backend (no video decoding: the picture is empty), with position
  // updates four times a second as a real player sends them, while the seek bar and volume are dragged.
  _scenario('player_controls', (tester) async {
    await _openApp(tester);
    final backend = _TickingBackend();
    _openPlayer(tester, backend);
    await _wait(const Duration(milliseconds: 2000));
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    addTearDown(backend.stop);
    await _measure('player_controls', () async {
      if (isTv) {
        for (var i = 0; i < 20; i++) {
          await (i < 10
              ? _key(
                  tester,
                  LogicalKeyboardKey.arrowRight,
                  PhysicalKeyboardKey.arrowRight,
                )
              : _key(
                  tester,
                  LogicalKeyboardKey.arrowLeft,
                  PhysicalKeyboardKey.arrowLeft,
                ));
          await _wait(const Duration(milliseconds: 120));
        }
        return;
      }
      if (!isDesktop) {
        // Volume (right), brightness (left) and a seek swipe, each where no control sits (the middle of the screen
        // is the play button), then a tap there to toggle the controls.
        final s = _phoneSpots(tester);
        await _swipe(
          tester,
          Offset(s.rightX, s.bottom),
          Offset(0, s.top - s.bottom),
        );
        await _swipe(
          tester,
          Offset(s.leftX, s.bottom),
          Offset(0, s.top - s.bottom),
        );
        await _swipe(
          tester,
          Offset(s.size.width * .25, s.band),
          Offset(s.size.width * .5, 0),
        );
        await _singleTap(tester, Offset(s.size.width / 2, s.band));
      }
      if (isDesktop) {
        // The pointer moving over the picture brings the controls back.
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(
          location: Offset(size.width * .5, size.height * .4),
        );
        for (var i = 0; i < 10; i++) {
          await mouse.moveBy(const Offset(4, 4));
          await _wait(const Duration(milliseconds: 16));
        }
        addTearDown(mouse.removePointer);
      } else if (find.byType(Slider).hitTestable().evaluate().isEmpty) {
        await _singleTap(
          tester,
          Offset(size.width * .5, _phoneSpots(tester).band),
        );
      }
      if (find.byType(Slider).hitTestable().evaluate().isEmpty) {
        throw StateError('No seek bar on screen: ${_texts()}');
      }
      final seek = tester.getRect(find.byType(Slider).hitTestable().first);
      await _drag(
        tester,
        Offset(seek.left + seek.width * .2, seek.center.dy),
        Offset(seek.width * .6, 0),
      );
      await _drag(
        tester,
        Offset(seek.left + seek.width * .8, seek.center.dy),
        Offset(-seek.width * .6, 0),
      );
      if (isDesktop) {
        final volume = tester.getRect(find.byType(Slider).hitTestable().last);
        await _drag(
          tester,
          Offset(volume.right - 2, volume.center.dy),
          Offset(-volume.width + 4, 0),
        );
        await _drag(
          tester,
          Offset(volume.left + 2, volume.center.dy),
          Offset(volume.width - 4, 0),
        );
        for (var i = 0; i < 8; i++) {
          // Volume keys: the hint comes and goes over the controls.
          await _key(
            tester,
            LogicalKeyboardKey.arrowDown,
            PhysicalKeyboardKey.arrowDown,
          );
          await _wait(const Duration(milliseconds: 150));
        }
        for (var i = 0; i < 6; i++) {
          backend.emit({'buffering': i.isEven});
          await _wait(const Duration(milliseconds: 150));
        }
      }
    });
    backend.stop();
    Navigator.of(_pageContext(tester), rootNavigator: true).pop();
    await _wait(const Duration(milliseconds: 800));
  });

  // ─────────────────────────────── Phone: the player's touch gestures ───────────────────────────────

  // lib/player.dart, phone: the picture's gestures with the controls hidden, as when watching: brightness (left) and
  // volume (right) swipes up and down, seek swipes both ways, double-tap seeks, holding for 2× and the buffering
  // spinner. Timed once, then once more with builds counted (as the TV scenarios do). Before the fix every pointer event
  // of a swipe set state on the whole player.
  _scenario(
    'phone_player_gestures',
    skip: () => isTv || isDesktop ? 'needs the phone layout' : null,
    (tester) async {
      await _openApp(tester);
      final backend = _TickingBackend();
      addTearDown(backend.stop);
      _openPlayer(tester, backend);
      // Turned to landscape, and the controls' 3 s timer has hidden them.
      await _wait(const Duration(milliseconds: 4000));
      final s = _phoneSpots(tester);
      var moves = 0;
      Future<void> swipe(Offset from, Offset by) async {
        await _swipe(tester, from, by);
        moves += 30;
      }

      Future<void> act() async {
        moves = 0;
        final height = s.top - s.bottom;
        await swipe(Offset(s.leftX, s.bottom), Offset(0, height));
        await swipe(Offset(s.leftX, s.top), Offset(0, -height));
        await swipe(Offset(s.rightX, s.bottom), Offset(0, height));
        await swipe(Offset(s.rightX, s.top), Offset(0, -height));
        await swipe(
          Offset(s.size.width * .25, s.band),
          Offset(s.size.width * .5, 0),
        );
        await swipe(
          Offset(s.size.width * .75, s.band),
          Offset(-s.size.width * .5, 0),
        );
        for (final x in [.8, .8, .2, .2]) {
          await _doubleTap(tester, Offset(s.size.width * x, s.band));
          await _wait(const Duration(milliseconds: 500));
        }
        final hold = await tester.startGesture(
          Offset(s.size.width / 2, s.band),
        );
        await _wait(const Duration(milliseconds: 1200));
        await hold.up();
        await _wait(const Duration(milliseconds: 300));
        for (var i = 0; i < 6; i++) {
          backend.emit({'buffering': i.isEven});
          await _wait(const Duration(milliseconds: 200));
        }
        await _wait(
          const Duration(milliseconds: 1700),
        ); // the hint and the timeline go
      }

      await _measure('phone_player_gestures', act);
      final emits = backend.emits;
      final clock = Stopwatch()..start();
      final builds = await _countBuilds(act);
      _noteTop('phone_player_gestures', builds);
      _note('phone_player_gestures', {
        'pointer_moves': moves,
        'counted_seconds': clock.elapsedMilliseconds / 1000,
        'counted_backend_updates': backend.emits - emits,
        'seeks': backend.seeks.length,
        ..._buildsOf(builds, [
          'PlayerScreen',
          '_FastForward',
          'Slider',
          'ValueListenableBuilder<Duration?>',
          'CircularProgressIndicator',
        ]),
        // The hint pill's own builder (current tree only): a record type, whose name the runtime spells its own way.
        'builds.hint_pill_builder': builds.entries
            .where((e) => e.key.startsWith('ValueListenableBuilder<({'))
            .fold<int>(0, (sum, e) => sum + e.value),
      });
      backend.stop();
      Navigator.of(_pageContext(tester), rootNavigator: true).pop();
      await _wait(const Duration(milliseconds: 800));
    },
  );

  // lib/player.dart, phone behaviour, as assertions over the fake backend (as tv_player_checks): the controls' tap and
  // timer, seek swipes, brightness and volume swipes, double-tap seeks, the hint, spinner and 2× badge coming and going
  // with the controls' overlay kept (same elements, not remounted), and the seek bar. Every check is recorded
  // (extra.check.<name>: 1 pass, 0 fail; "checks" says why), then the test fails if any did.
  _scenario(
    'phone_player_checks',
    skip: () => isTv || isDesktop ? 'needs the phone layout' : null,
    (tester) async {
      await _openApp(tester);
      final backend = _TickingBackend();
      addTearDown(backend.stop);
      final checks = <String, String>{};
      void check(String name, bool ok, [Object? detail]) {
        checks[name] = ok ? 'pass' : 'FAIL ${detail ?? ''}'.trim();
      }

      final step = Settings.seekSeconds * 1000;
      final playerOpen = find.byType(PlayerScreen);
      // The overlay's own elements: a remount replaces them.
      (Element, State) overlay() => (
        _inPlayer(find.byTooltip('Lock controls')).evaluate().single,
        tester.state(_inPlayer(find.byType(Slider)).first),
      );
      bool kept((Element, State) was) {
        final now = overlay();
        return identical(now.$1, was.$1) &&
            identical(now.$2, was.$2) &&
            now.$1.mounted;
      }

      bool spinner() =>
          _inPlayer(find.byType(CircularProgressIndicator))
              .evaluate()
              .isNotEmpty;

      _openPlayer(tester, backend);
      await _wait(const Duration(milliseconds: 1500));
      check('opens_with_controls_up', _phoneControlsShown());
      await _wait(const Duration(milliseconds: 2200)); // 3.7 s in, playing
      check('controls_hide_3s_after_open', !_phoneControlsShown());
      final s = _phoneSpots(tester);
      final mid = Offset(s.size.width / 2, s.band);

      // A tap on the picture brings them up; they go 3 s later while it plays; a tap with them up hides them.
      await _singleTap(tester, mid);
      check('tap_shows_controls', _phoneControlsShown());
      await _wait(const Duration(milliseconds: 2000));
      check('controls_stay_2_5s_after_tap', _phoneControlsShown());
      await _wait(const Duration(milliseconds: 1100));
      check('controls_hide_3s_after_tap', !_phoneControlsShown());
      await _singleTap(tester, mid);
      await _singleTap(tester, mid);
      check('tap_hides_controls', !_phoneControlsShown());
      await _singleTap(tester, mid);

      // Paused from the controls, so they stay up and the position holds still for what follows.
      await tester.tap(_inPlayer(find.byTooltip('Pause')));
      await _wait(const Duration(milliseconds: 400));
      check(
        'pause_button_pauses',
        backend.calls.any((c) => c.$1 == 'pause') &&
            !backend.playing &&
            _phoneControlsShown(),
        '${backend.calls.map((c) => c.$1).toList()} shown ${_phoneControlsShown()}',
      );
      final ov = overlay();

      // The buffering spinner.
      backend.emit({'buffering': true});
      await _wait(const Duration(milliseconds: 300));
      check('spinner_shows', spinner());
      check('overlay_kept_spinner_on', kept(ov));
      backend.emit({'buffering': false});
      await _wait(const Duration(milliseconds: 300));
      check('spinner_goes', !spinner());
      check('overlay_kept_spinner_off', kept(ov));

      // Double taps: right half forward, left half back, a step each, with the hint.
      Future<void> doubleTap(String name, double x, int sign) async {
        final from = backend.position;
        final seeks = backend.seeks.length;
        await _doubleTap(tester, Offset(s.size.width * x, s.band));
        await _wait(const Duration(milliseconds: 250));
        final landed = backend.seeks.skip(seeks).toList();
        check(
          '${name}_seeks_one_step',
          landed.length == 1 && landed.single == from + sign * step,
          'from $from, seeks $landed',
        );
        final hint = _hintText();
        check(
          '${name}_hint_shows',
          hint == '${sign > 0 ? '+' : '-'}${Settings.seekSeconds}s',
          hint,
        );
        check('${name}_overlay_kept_hint_on', kept(ov));
        check('${name}_controls_stay_up', _phoneControlsShown());
        await _wait(const Duration(milliseconds: 1700));
        check('${name}_hint_goes', _hintText() == null, _hintText());
        check('${name}_overlay_kept_hint_off', kept(ov));
      }

      await doubleTap('double_tap_right', .8, 1);
      await doubleTap('double_tap_left', .2, -1);

      // Seek swipes: the target moves with the finger (250 ms a pixel), the hint and the time played say it, the
      // seek bar shows it, nothing seeks until the finger lifts, then one seek, to the target.
      Future<void> seekSwipe(String name, double fromX, double dx) async {
        final start = backend.position;
        final seeks = backend.seeks.length;
        final wrong = <String>[];
        final targets = <int>[];
        final g = await tester.startGesture(Offset(fromX, s.band));
        const steps = 30;
        for (var i = 0; i < steps; i++) {
          await g.moveBy(Offset(dx / steps, 0));
          await _wait(const Duration(milliseconds: 16));
          if (i < 4) continue; // inside the drag slop
          final bar = _bars().first;
          targets.add(bar);
          final shown = formatDuration(Duration(milliseconds: bar));
          if (_inPlayer(find.text(shown)).evaluate().isEmpty) {
            wrong.add('move $i: time played not "$shown"');
          }
          final hint = _hintText();
          if (hint == null || !hint.startsWith('$shown  (')) {
            wrong.add('move $i: hint "$hint", bar $shown');
          }
          if (backend.seeks.length != seeks) wrong.add('move $i: seeked');
        }
        final last = targets.last;
        await g.up();
        await _wait(const Duration(milliseconds: 400));
        final moved = (last - start) * dx.sign;
        // The drag slop (18 px) is not counted.
        final expected = (dx.abs() - 18) * 250;
        check(
          '${name}_moves_target',
          (moved - expected).abs() < 20 * 250,
          'moved ${moved}ms, expected about ${expected.round()}ms',
        );
        var monotonic = true;
        for (var i = 1; i < targets.length; i++) {
          if ((targets[i] - targets[i - 1]) * dx.sign < 0) monotonic = false;
        }
        check('${name}_target_follows_finger', monotonic, targets);
        check('${name}_time_and_hint_follow', wrong.isEmpty, wrong.take(4));
        final landed = backend.seeks.skip(seeks).toList();
        check(
          '${name}_release_seeks_once_to_target',
          landed.length == 1 && landed.single == last,
          'seeks $landed, target $last',
        );
        check(
          '${name}_bar_shows_landing',
          (_bars().first - last).abs() < 1000,
          'bar ${_bars()}, landed $last',
        );
        check('${name}_overlay_kept', kept(ov));
        await _wait(const Duration(milliseconds: 1700));
        check('${name}_hint_goes', _hintText() == null, _hintText());
      }

      await seekSwipe(
        'seek_swipe_right',
        s.size.width * .25,
        s.size.width * .5,
      );
      await seekSwipe(
        'seek_swipe_left',
        s.size.width * .75,
        -s.size.width * .5,
      );

      // Up and down swipes: brightness on the left, volume on the right, the hint saying the level.
      final percent = RegExp(r'^(\d+)%$');
      Future<List<int>> levelSwipe(double x, double dy) async {
        final shown = <int>[];
        final g = await tester.startGesture(
          Offset(x, dy < 0 ? s.bottom : s.top),
        );
        for (var i = 0; i < 30; i++) {
          await g.moveBy(Offset(0, dy / 30));
          await _wait(const Duration(milliseconds: 16));
          if (percent.firstMatch(_hintText() ?? '') case final m?) {
            shown.add(int.parse(m[1]!));
          }
        }
        await g.up();
        await _wait(const Duration(milliseconds: 300));
        return shown;
      }

      bool hasIcon(IconData icon) =>
          _inPlayer(find.byIcon(icon)).evaluate().isNotEmpty;
      final height = s.bottom - s.top;
      final brightness0 = (await ScreenBrightness().application * 100).round();
      final up = await levelSwipe(s.leftX, -height);
      check(
        'brightness_swipe_up_raises',
        up.isNotEmpty && up.last > brightness0 || brightness0 == 100,
        'from $brightness0: $up',
      );
      check('brightness_hint_icon', hasIcon(Icons.brightness_6_rounded));
      final window = (await ScreenBrightness().application * 100).round();
      check(
        'brightness_applied_to_window',
        up.isNotEmpty && (window - up.last).abs() <= 1,
        'window $window, hint ${up.lastOrNull}',
      );
      check('brightness_overlay_kept', kept(ov));
      final down = await levelSwipe(s.leftX, height);
      check(
        'brightness_swipe_down_lowers',
        down.isNotEmpty && down.last < (up.lastOrNull ?? 100),
        down,
      );
      await _wait(const Duration(milliseconds: 1700));
      check('brightness_hint_goes', _hintText() == null, _hintText());

      final volumes = backend.volumes.length;
      final louder = await levelSwipe(s.rightX, -height);
      final set = backend.volumes.skip(volumes).toList();
      check(
        'volume_swipe_up_raises',
        louder.isNotEmpty &&
            set.isNotEmpty &&
            (set.last * 100).round() == louder.last &&
            (set.length < 2 || set.last >= set.first),
        'hint $louder, set ${set.map((v) => (v * 100).round()).toList()}',
      );
      check('volume_hint_icon', hasIcon(Icons.volume_up_rounded));
      check('volume_overlay_kept', kept(ov));
      final quieter = await levelSwipe(s.rightX, height * 1.5);
      check(
        'volume_swipe_down_lowers_to_mute',
        quieter.isNotEmpty &&
            quieter.last == 0 &&
            backend.volumes.last == 0 &&
            hasIcon(Icons.volume_off_rounded),
        'hint $quieter, last set ${backend.volumes.lastOrNull}',
      );
      await _wait(const Duration(milliseconds: 1700));
      check('volume_hint_goes', _hintText() == null, _hintText());

      // Holding plays at 2× while held, the badge showing.
      final callsBeforeHold = backend.calls.length;
      final hold = await tester.startGesture(mid);
      await _wait(const Duration(milliseconds: 900));
      check('badge_shows', _built('_FastForward'));
      check('overlay_kept_badge_on', kept(ov));
      await hold.up();
      await _wait(const Duration(milliseconds: 400));
      check('badge_goes', !_built('_FastForward'));
      check('overlay_kept_badge_off', kept(ov));
      final rates = [
        for (final (m, a) in backend.calls.skip(callsBeforeHold))
          if (m == 'rate') a['rate'],
      ];
      check('hold_sets_rate_2x_and_back', rates.join(',') == '2.0,1.0', rates);
      check('controls_up_after_hold', _phoneControlsShown());

      // The seek bar dragged: the time played follows, one seek on release.
      final bar = tester.getRect(_inPlayer(find.byType(Slider)).first);
      final seeks = backend.seeks.length;
      final g = await tester.startGesture(
        Offset(bar.left + bar.width * .2, bar.center.dy),
      );
      final wrong = <String>[];
      final values = <int>[];
      for (var i = 0; i < 30; i++) {
        await g.moveBy(Offset(bar.width * .4 / 30, 0));
        await _wait(const Duration(milliseconds: 16));
        final value = _bars().first;
        values.add(value);
        final shown = formatDuration(Duration(milliseconds: value));
        if (_inPlayer(find.text(shown)).evaluate().isEmpty) {
          wrong.add('move $i: "$shown" not shown');
        }
        if (backend.seeks.length != seeks) wrong.add('move $i: seeked');
      }
      await g.up();
      await _wait(const Duration(milliseconds: 400));
      check(
        'seek_bar_drag_time_follows',
        wrong.isEmpty && values.last > values.first,
        '${wrong.take(4)} ${values.first}..${values.last}',
      );
      final landed = backend.seeks.skip(seeks).toList();
      check(
        'seek_bar_release_seeks_once',
        landed.length == 1 && (landed.single - values.last).abs() < 1000,
        'seeks $landed, last value ${values.last}',
      );
      check('seek_bar_overlay_kept', kept(ov));

      // Back on the top bar leaves the player, pausing.
      await tester.tap(_inPlayer(find.byTooltip('Play')));
      await _wait(const Duration(milliseconds: 300));
      final calls = backend.calls.length;
      await tester.tap(_inPlayer(find.byTooltip('Back')));
      await _wait(const Duration(milliseconds: 1000));
      check(
        'back_leaves_and_pauses',
        playerOpen.evaluate().isEmpty &&
            backend.calls.skip(calls).any((c) => c.$1 == 'pause'),
        '${playerOpen.evaluate().length} players, calls ${backend.calls.skip(calls).map((c) => c.$1).toList()}',
      );

      backend.stop();
      if (playerOpen.evaluate().isNotEmpty) {
        Navigator.of(_pageContext(tester), rootNavigator: true).pop();
        await _wait(const Duration(milliseconds: 800));
      }
      _binding.reportData!['phone_player_checks'] = {
        'checks': checks,
        'extra': {
          for (final MapEntry(:key, :value) in checks.entries)
            'check.$key': value == 'pass' ? 1 : 0,
        },
      };
      final failed = {
        for (final MapEntry(:key, :value) in checks.entries)
          if (value != 'pass') key: value,
      };
      if (failed.isNotEmpty) {
        fail('${failed.length} of ${checks.length} checks failed: $failed');
      }
    },
  );

  // ─────────────────────────────── TV: driven by D-pad key events ───────────────────────────────
  //
  // Each runs its action twice: once measured for frame timings, then once more with the framework's build
  // profiling on (debugProfileBuildsEnabled, which profile builds honour), counting how many times each widget type
  // was built or updated. The second pass is never timed: profiling every build slows it.

  // lib/home.dart: the TV drawer opened and closed from Home, with every page visited first (visited pages stay
  // built in Home's IndexedStack). Before the fix the drawer was HomeScreen state, so each open and close rebuilt
  // every visited page.
  _scenario('tv_drawer', skip: () => !isTv ? 'needs the TV layout' : null, (
    tester,
  ) async {
    await _openApp(tester);
    // Every page once, through the drawer, then Home again.
    for (var page = 1; page < _homePages.length; page++) {
      await _openDrawer(tester);
      await _dpad(tester, _down);
      await _dpad(tester, _ok, gap: const Duration(milliseconds: 1500));
    }
    await _openDrawer(tester);
    for (var page = 1; page < _homePages.length; page++) {
      await _dpad(tester, _up);
    }
    await _dpad(tester, _ok, gap: const Duration(milliseconds: 1500));
    final built = [
      for (final name in _homePages)
        if (_built(name)) name,
    ];
    if (built.length != _homePages.length) {
      throw StateError('Not every page was visited: $built');
    }
    var presses = 0;
    Future<void> cycle() async {
      for (var i = 0; i < 6; i++) {
        presses += await _openDrawer(tester);
        await _wait(const Duration(milliseconds: 400));
        await _dpad(tester, _right, gap: const Duration(milliseconds: 400));
        presses++;
        if (_inDrawer()) throw StateError('Right did not close the drawer');
      }
    }

    await _measure('tv_drawer', cycle);
    final builds = await _countBuilds(cycle);
    _noteTop('tv_drawer', builds);
    _note('tv_drawer', {
      'pages_built': built.length,
      'key_presses': presses,
      ..._buildsOf(builds, [..._homePages, 'HomeScreen', '_TvDrawer']),
    });
  });

  // lib/search.dart: D-pad focus snaking across a grid of results, the preview beside it following. Before the
  // fix each move set state on the whole search screen.
  _scenario(
    'tv_search_focus',
    skip: () => !isTv ? 'needs the TV layout' : null,
    (tester) async {
      await _openGrid(tester);
      final cards = find.byType(PosterCard);
      if (cards.evaluate().isEmpty) {
        throw StateError('No results: ${_texts()}');
      }
      final firstTop = tester.getRect(cards.first).top;
      final columns = cards
          .evaluate()
          .where(
            (e) =>
                (tester.getRect(find.byElementPredicate((x) => x == e)).top -
                        firstTop)
                    .abs() <
                1,
          )
          .length;
      final focused = <FocusNode>{};
      var moves = 0;
      Future<void> sweep() async {
        _mainScroll(tester).jumpTo(0);
        await _wait(const Duration(milliseconds: 400));
        // Onto the first result: its card's own focus node (the InkWell over its artwork).
        _focusNodeIn(tester, cards.first).requestFocus();
        await _wait(const Duration(milliseconds: 400));
        if (!_inside('PosterCard')) {
          throw StateError('Focus is not on a result: ${_focusName()}');
        }
        for (var row = 0; row < 5; row++) {
          for (var c = 1; c < columns; c++) {
            await _dpad(tester, row.isEven ? _right : _left);
            moves++;
            focused.add(FocusManager.instance.primaryFocus!);
          }
          await _dpad(tester, _down);
          moves++;
          focused.add(FocusManager.instance.primaryFocus!);
        }
        for (var row = 0; row < 5; row++) {
          await _dpad(tester, _up);
          moves++;
        }
      }

      await _measure('tv_search_focus', sweep);
      final distinct = focused.length;
      final builds = await _countBuilds(sweep);
      _noteTop('tv_search_focus', builds);
      _note('tv_search_focus', {
        'columns': columns,
        'moves': moves ~/ 2,
        'distinct_cards_focused': distinct,
        ..._buildsOf(builds, [
          'SearchScreen',
          '_TvPreview',
          'PosterCard',
          'FocusCard',
        ]),
      });
    },
  );

  // lib/player.dart: D-pad scrubs in the player, with the controls up (focus on the seek bar) and with them hidden
  // (the bare timeline), while the buffering spinner, the hint and the 2× badge come and go. Before the fix the
  // scrub target and the hint were player state: each repeat rebuilt the whole player, and a hint or the spinner
  // appearing remounted the controls after it in the Stack.
  _scenario(
    'tv_player_scrub',
    skip: () => !isTv ? 'needs the TV layout' : null,
    (tester) async {
      await _openApp(tester);
      final backend = _TickingBackend();
      addTearDown(backend.stop);
      _openPlayer(tester, backend);
      await _wait(const Duration(milliseconds: 2000));
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      Future<void> act() async {
        // Controls up, onto the seek bar (Up from play), and scrub there.
        if (!_controlsShown()) await _dpad(tester, _down);
        await _dpad(tester, _down); // into the controls: play
        await _dpad(tester, _up); // the seek bar
        await _hold(tester, _right, 15);
        await _wait(const Duration(milliseconds: 300));
        await _hold(tester, _left, 15);
        // The spinner, the hint (fast-forward key) and the 2× badge (a long press on the picture) come and go.
        for (var i = 0; i < 6; i++) {
          backend.emit({'buffering': i.isEven});
          await _wait(const Duration(milliseconds: 200));
        }
        for (var i = 0; i < 3; i++) {
          await _dpad(tester, _fastForward);
        }
        final hold = await tester.startGesture(
          Offset(size.width / 2, size.height / 2),
        );
        await _wait(const Duration(milliseconds: 900));
        await hold.up();
        await _wait(const Duration(milliseconds: 1600)); // the hint goes
        // Back hides the controls (unless their timer already has: Back would then leave the player); the same
        // scrubs over the bare timeline.
        if (_controlsShown()) await _systemBack(tester);
        await _hold(tester, _right, 15);
        await _wait(const Duration(milliseconds: 300));
        await _hold(tester, _left, 15);
        for (var i = 0; i < 3; i++) {
          await _dpad(tester, _right);
        }
        await _wait(const Duration(milliseconds: 2200)); // the timeline goes
      }

      await _measure('tv_player_scrub', act);
      final seeks = backend.seeks.length;
      final builds = await _countBuilds(act);
      _noteTop('tv_player_scrub', builds);
      _note('tv_player_scrub', {
        'seeks': seeks,
        ..._buildsOf(builds, [
          'PlayerScreen',
          '_TvControl',
          'Slider',
          'ValueListenableBuilder<Duration?>',
        ]),
      });
      backend.stop();
      Navigator.of(_pageContext(tester), rootNavigator: true).pop();
      await _wait(const Duration(milliseconds: 800));
    },
  );

  // lib/player.dart, behaviour: the TV scrub path, focus, the controls' timers and Back, as assertions over the fake
  // backend. Every check is recorded (extra.check.<name>: 1 pass, 0 fail; "checks" says why), then the test fails if
  // any did.
  _scenario('tv_player_checks', skip: () => !isTv ? 'needs the TV layout' : null, (
    tester,
  ) async {
    await _openApp(tester);
    final backend = _TickingBackend();
    addTearDown(backend.stop);
    final checks = <String, String>{};
    void check(String name, bool ok, [Object? detail]) {
      checks[name] = ok ? 'pass' : 'FAIL ${detail ?? ''}'.trim();
    }

    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    FocusNode? node() => FocusManager.instance.primaryFocus;
    // The same node, in the same element, still holding focus: neither moved nor remounted.
    bool same((FocusNode, BuildContext?) was) {
      final now = node();
      return now == was.$1 && now?.context == was.$2 && was.$1.hasPrimaryFocus;
    }

    (FocusNode, BuildContext?) here() => (node()!, node()!.context);
    String was((FocusNode, BuildContext?) f) =>
        'now ${_focusName()}${node() == f.$1 ? ' (same node, ${node()?.context == f.$2 ? 'same' : 'new'} element)' : ''}';
    final playerOpen = find.byType(PlayerScreen);

    _openPlayer(tester, backend);
    await _wait(const Duration(milliseconds: 1500));
    check('opens_with_controls_up', _controlsShown());

    // Into the controls: the first D-pad key lands on play/pause.
    await _dpad(tester, _down);
    final play = _focusName();
    check('first_key_focuses_play', play == 'control:Pause', play);
    // Paused from here, so the controls stay up while focus is checked.
    await _dpad(tester, _ok, gap: const Duration(milliseconds: 400));
    check(
      'ok_on_play_pauses',
      backend.calls.any((c) => c.$1 == 'pause') &&
          _focusName() == 'control:Play',
      '${backend.calls.map((c) => c.$1).toList()} ${_focusName()}',
    );
    await _dpad(tester, _right);
    final control = here();
    final controlName = _focusName();
    check(
      'right_moves_to_next_control',
      controlName.startsWith('control:') && controlName != 'control:Play',
      controlName,
    );

    backend.emit({'buffering': true});
    await _wait(const Duration(milliseconds: 400));
    check(
      'spinner_shows',
      find.byType(CircularProgressIndicator).evaluate().isNotEmpty,
    );
    check('focus_kept_spinner_on', same(control), was(control));
    backend.emit({'buffering': false});
    await _wait(const Duration(milliseconds: 400));
    check('focus_kept_spinner_off', same(control), was(control));

    await _dpad(tester, _fastForward, gap: const Duration(milliseconds: 300));
    check('hint_shows', find.text('+10s').evaluate().isNotEmpty, _texts());
    check('focus_kept_hint_on', same(control), was(control));
    await _wait(const Duration(milliseconds: 1700));
    check('hint_goes', find.text('+10s').evaluate().isEmpty);
    check('focus_kept_hint_off', same(control), was(control));

    // Holding a finger on the picture plays at 2× while held (the hold gesture; a remote can't, but it's the
    // badge's only trigger).
    final callsBeforeHold = backend.calls.length;
    final press = await tester.startGesture(
      Offset(size.width / 2, size.height / 2),
    );
    await _wait(const Duration(milliseconds: 900));
    check('badge_shows', _built('_FastForward'));
    check('focus_kept_badge_on', same(control), was(control));
    await press.up();
    await _wait(const Duration(milliseconds: 400));
    check('badge_goes', !_built('_FastForward'));
    check('focus_kept_badge_off', same(control), was(control));
    final rates = [
      for (final (m, a) in backend.calls.skip(callsBeforeHold))
        if (m == 'rate') a['rate'],
    ];
    check('badge_sets_rate_2x_and_back', rates.join(',') == '2.0,1.0', rates);
    await _dpad(tester, _right);
    check(
      'dpad_still_moves_after',
      _focusName().startsWith('control:') && node() != control.$1,
      _focusName(),
    );

    // On the seek bar, with the controls up: a held Right moves the target, and letting go seeks there once.
    await _dpad(tester, _up);
    check('up_reaches_seek_bar', _focusName() == 'seekbar', _focusName());
    final bar = here();
    Future<void> scrub(String name, _Dpad key, int repeats) async {
      final before = backend.seeks.length;
      final step = (key == _right ? 1 : -1) * Settings.seekSeconds * 1000;
      final wrong = <String>[];
      var target = 0;
      await _hold(
        tester,
        key,
        repeats,
        onDown: () {
          if (backend.seeks.length != before + 1) {
            wrong.add('press made ${backend.seeks.length - before} seeks');
          }
        },
        onRepeat: (i) {
          target = backend.seeks[before] + step * (i + 1);
          final shown = formatDuration(Duration(milliseconds: target));
          final bars = [
            for (final e in find.byType(Slider).evaluate())
              (e.widget as Slider).value.round(),
          ];
          if (bars.isEmpty || bars.any((v) => v != target)) {
            wrong.add('repeat $i: seek bars at $bars, target $target');
          }
          // The hint and the time played both say it.
          if (find.text(shown).evaluate().length < 2) {
            wrong.add(
              'repeat $i: "$shown" shown ${find.text(shown).evaluate().length}×',
            );
          }
          if (backend.seeks.length != before + 1) {
            wrong.add('repeat $i: seeked while held');
          }
          if (name == 'seek_bar' && !same(bar)) {
            wrong.add('repeat $i: focus ${was(bar)}');
          }
        },
      );
      await _wait(const Duration(milliseconds: 300));
      final landed = backend.seeks.skip(before).toList();
      check(
        '${name}_scrub_${key == _right ? 'right' : 'left'}_follows',
        wrong.isEmpty,
        wrong.take(4).join('; '),
      );
      check(
        '${name}_scrub_${key == _right ? 'right' : 'left'}_commits',
        landed.length == 2 && landed.last == target,
        'seeks $landed, target $target',
      );
      final bars = [
        for (final e in find.byType(Slider).evaluate())
          (e.widget as Slider).value.round(),
      ];
      check(
        '${name}_scrub_${key == _right ? 'right' : 'left'}_shows_landing',
        bars.isNotEmpty && bars.every((v) => (v - target).abs() < 1000),
        'seek bars at $bars, landed $target',
      );
    }

    await scrub('seek_bar', _right, 8);
    await scrub('seek_bar', _left, 5);
    check('focus_kept_on_seek_bar_through_scrubs', same(bar), was(bar));
    await _wait(const Duration(milliseconds: 1700));
    check('focus_kept_on_seek_bar_hint_gone', same(bar), was(bar));
    // A press without a hold seeks once, by one step; letting go adds nothing (there is no other cancel on TV).
    final before = backend.seeks.toList();
    await _dpad(tester, _left, gap: const Duration(milliseconds: 300));
    final after = backend.seeks.skip(before.length).toList();
    check(
      'press_seeks_once_release_adds_nothing',
      after.length == 1 &&
          after.single == before.last - Settings.seekSeconds * 1000,
      'before ${before.last}, then $after',
    );

    // Back with the controls up hides them and stays; focus goes to the player's own keys.
    await _systemBack(tester);
    check(
      'back_hides_controls',
      !_controlsShown() && playerOpen.evaluate().isNotEmpty,
    );
    check('focus_to_player_when_hidden', _focusName() == 'keys', _focusName());

    // Hidden: left/right scrub over the bare timeline, which goes 2 s after.
    await scrub('hidden', _right, 6);
    check(
      'timeline_shows_while_hidden',
      find.byType(Slider).evaluate().length == 2,
      '${find.byType(Slider).evaluate().length} seek bars',
    );
    await _wait(const Duration(milliseconds: 2300));
    check(
      'timeline_goes_after_2s',
      find.byType(Slider).evaluate().length == 1,
      '${find.byType(Slider).evaluate().length} seek bars',
    );
    await scrub('hidden', _left, 4);
    await _wait(const Duration(milliseconds: 2300));

    // Down brings the controls back, focus on play.
    await _dpad(tester, _down, gap: const Duration(milliseconds: 400));
    check(
      'down_shows_controls_on_play',
      _controlsShown() && _focusName() == 'control:Play',
      '${_controlsShown()} ${_focusName()}',
    );
    // Playing, they go 3 s after the last key.
    await _dpad(tester, _ok, gap: Duration.zero);
    await _wait(const Duration(milliseconds: 2400));
    check('controls_stay_2_4s_after_key', _controlsShown());
    await _wait(const Duration(milliseconds: 1300));
    check('controls_hide_3s_after_key', !_controlsShown());
    check('focus_to_player_after_hide', _focusName() == 'keys', _focusName());
    // OK with them hidden pauses and brings them up, on play.
    final calls = backend.calls.length;
    await _dpad(tester, _ok, gap: const Duration(milliseconds: 400));
    check(
      'ok_when_hidden_pauses_and_shows',
      backend.calls.skip(calls).any((c) => c.$1 == 'pause') &&
          _controlsShown() &&
          _focusName() == 'control:Play',
      '${backend.calls.skip(calls).map((c) => c.$1).toList()} ${_controlsShown()} ${_focusName()}',
    );
    // Play/pause on the remote works with them up.
    final calls2 = backend.calls.length;
    await _dpad(tester, _playPause, gap: const Duration(milliseconds: 300));
    check(
      'media_play_pause',
      backend.calls.skip(calls2).any((c) => c.$1 == 'play'),
      backend.calls.skip(calls2).map((c) => c.$1).toList(),
    );
    // Back twice: hides them, then leaves, pausing on the way out.
    await _systemBack(tester);
    check('back_once_stays', playerOpen.evaluate().isNotEmpty);
    final calls3 = backend.calls.length;
    await _systemBack(tester, gap: const Duration(milliseconds: 1000));
    check(
      'back_twice_leaves_and_pauses',
      playerOpen.evaluate().isEmpty &&
          backend.calls.skip(calls3).any((c) => c.$1 == 'pause'),
      '${playerOpen.evaluate().length} players, calls ${backend.calls.skip(calls3).map((c) => c.$1).toList()}',
    );

    backend.stop();
    if (playerOpen.evaluate().isNotEmpty) {
      Navigator.of(_pageContext(tester), rootNavigator: true).pop();
      await _wait(const Duration(milliseconds: 800));
    }
    _binding.reportData!['tv_player_checks'] = {
      'checks': checks,
      'extra': {
        for (final MapEntry(:key, :value) in checks.entries)
          'check.$key': value == 'pass' ? 1 : 0,
      },
    };
    final failed = {
      for (final MapEntry(:key, :value) in checks.entries)
        if (value != 'pass') key: value,
    };
    if (failed.isNotEmpty) {
      fail('${failed.length} of ${checks.length} checks failed: $failed');
    }
  });
}

/// A scenario: a test that records why it didn't run where it can't, and its frames where it can. [skip] is asked
/// when the test runs, after setUpAll has found the form factor (isTv is false until then), and says why not.
void _scenario(
  String name,
  Future<void> Function(WidgetTester tester) body, {
  String? Function()? skip,
}) {
  testWidgets(name, (tester) async {
    if (_only.isNotEmpty && !_only.split(',').contains(name)) return;
    if (skip?.call() case final why?) {
      _binding.reportData![name] = {'skipped': '$why ($_formFactor)'};
      return;
    }
    await body(tester);
    // Unmount the app, so the next scenario starts from a fresh one.
    await tester.pumpWidget(const SizedBox.shrink());
    await _wait(const Duration(milliseconds: 500));
  });
}

/// Times [action]'s frames under [name], and notes the rate they were drawn at: the gaps between consecutive frames'
/// vsyncs (only gaps under 25 ms, so frames drawn back to back), as `vsync_gap_ms_median` and how many of those gaps
/// were one 120 Hz period (`vsync_gaps_120hz`, under 12.5 ms) or one 60 Hz period (`vsync_gaps_60hz`).
Future<void> _measure(String name, Future<void> Function() action) async {
  final vsyncs = <int>[];
  void onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      vsyncs.add(t.timestampInMicroseconds(FramePhase.vsyncStart));
    }
  }

  SchedulerBinding.instance.addTimingsCallback(onTimings);
  try {
    await _binding.watchPerformance(action, reportKey: name);
  } finally {
    SchedulerBinding.instance.removeTimingsCallback(onTimings);
  }
  vsyncs.sort();
  final gaps = [
    for (var i = 1; i < vsyncs.length; i++)
      if (vsyncs[i] - vsyncs[i - 1] case final gap when gap > 0 && gap < 25000)
        gap,
  ]..sort();
  _note(name, {
    'vsync_gap_ms_median': gaps.isEmpty
        ? 0
        : (gaps[gaps.length ~/ 2] / 10).round() / 100,
    'vsync_gaps_120hz': gaps.where((g) => g < 12500).length,
    'vsync_gaps_60hz': gaps.where((g) => g >= 12500).length,
  });
}

/// Adds [extra] to what [name] reports (its counters, as `extra.*` in the summary).
void _note(String name, Map<String, Object?> extra) {
  final report = _binding.reportData![name] as Map;
  report['extra'] = {...?report['extra'] as Map?, ...extra};
}

/// Real time passing, with the app drawing whatever frames it asks for.
Future<void> _wait(Duration d) => Future<void>.delayed(d);

/// The app as main() runs it, on Home, once its posters have loaded.
Future<void> _openApp(WidgetTester tester) async {
  await tester.pumpWidget(App(key: UniqueKey()));
  await _wait(const Duration(milliseconds: 2500));
  // A dialog at startup (what's new, a survey) would sit over every scenario.
  for (var i = 0; i < 3 && find.byType(Dialog).evaluate().isNotEmpty; i++) {
    Navigator.of(tester.element(find.byType(Dialog).first)).pop();
    await _wait(const Duration(milliseconds: 400));
  }
}

/// The app on a search grid of 300 shows.
Future<void> _openGrid(WidgetTester tester) async {
  await _openApp(tester);
  unawaited(
    openSearch(
      _pageContext(tester),
      const SearchFilters(sort: 'TRENDING_DESC'),
    ),
  );
  await _wait(const Duration(milliseconds: 2500));
}

/// Where a page opens: the desktop's open section, else Home's navigator.
BuildContext _pageContext(WidgetTester tester) =>
    (isDesktop ? deskPageContext?.call() : null) ??
    tester.element(find.byType(Scaffold).first);

void _back(WidgetTester tester) {
  if (isDesktop && desktopBack != null && desktopBack!()) return;
  Navigator.of(_pageContext(tester)).maybePop();
}

List<ScrollPosition> _scrollables(WidgetTester tester, Axis axis) => [
  for (final e in find.byType(Scrollable).hitTestable().evaluate())
    if ((e as StatefulElement).state case final ScrollableState s
        when s.position.axis == axis && s.position.hasContentDimensions)
      s.position,
];

/// The page's own vertical list: the one that scrolls furthest.
ScrollPosition _mainScroll(WidgetTester tester) {
  final all = _scrollables(tester, Axis.vertical)
    ..sort((a, b) => b.maxScrollExtent.compareTo(a.maxScrollExtent));
  if (all.isEmpty || all.first.maxScrollExtent <= 0) {
    throw StateError('Nothing on this page scrolls');
  }
  return all.first;
}

/// Poster rects on screen, top first, the banner left out.
List<Rect> _rows(WidgetTester tester) =>
    _posters(tester).where((r) => r.height < 400).toList()
      ..sort((a, b) => a.top.compareTo(b.top));

/// Every poster and banner at least partly on screen. Not by hit test: a card's hover overlay can sit over its art
/// (invisible, but hit first) and the art then counts as hidden.
List<Rect> _posters(WidgetTester tester) {
  final screen =
      Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
  return [
        for (final e in find.byType(Artwork).evaluate())
          tester.getRect(find.byElementPredicate((x) => x == e)),
      ]
      .where(
        (r) => r.left >= 0 && r.right <= screen.right && r.overlaps(screen),
      )
      .toList();
}

/// The middle of the first poster row wholly below the banner.
double _rowY(WidgetTester tester) {
  final height = tester.view.physicalSize.height / tester.view.devicePixelRatio;
  final ys = _rows(tester)
      .where((r) => r.top > 0 && r.bottom < height)
      .toList();
  if (ys.isEmpty) {
    throw StateError(
      'No poster row on screen (height $height): '
      '${find.byType(Artwork).evaluate().take(12).map((e) => _ltrb(tester.getRect(find.byElementPredicate((x) => x == e)))).toList()}; '
      '${_texts()}',
    );
  }
  return ys.first.center.dy;
}

/// A tap that lets the app draw its response before the next.
Future<void> _click(WidgetTester tester, Finder target) async {
  await tester.tap(target, warnIfMissed: false);
  await _wait(const Duration(milliseconds: 180));
}

/// A finger or mouse drag at about 60 moves a second.
Future<void> _drag(WidgetTester tester, Offset from, Offset by) async {
  final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
  const steps = 45;
  for (var i = 0; i < steps; i++) {
    await g.moveBy(by / steps.toDouble());
    await _wait(const Duration(milliseconds: 16));
  }
  await g.up();
  await _wait(const Duration(milliseconds: 300));
}

Future<void> _swipe(WidgetTester tester, Offset from, Offset by) async {
  final g = await tester.startGesture(from);
  const steps = 30;
  for (var i = 0; i < steps; i++) {
    await g.moveBy(by / steps.toDouble());
    await _wait(const Duration(milliseconds: 16));
  }
  await g.up();
  await _wait(const Duration(milliseconds: 400));
}

/// 240 failed downloads over 24 shows: a big library, none of it needing files on disk.
List<Download> _failedLibrary() => [
  for (var s = 10; s < 34; s++)
    for (var n = 1; n <= 10; n++)
      Download(
        media: fakeShow(s),
        source: siteName,
        number: n,
        dub: false,
        ref: 'show-${fakeShow(s)['id']}/$n',
        status: DownloadStatus.failed,
      ),
];

Future<void> _writeDownloads(List<Download> items) async {
  final root = Directory('${Settings.desktopDownloadFolder}/AniView');
  await root.create(recursive: true);
  // The app saves its index after each change, through its own queue and `index.json.tmp`; that save (one follows
  // every finished download) is let finish, and this writes aside under its own name, so the two never race.
  await _wait(const Duration(milliseconds: 600));
  final temp = File('${root.path}/index.json.perf');
  await temp.writeAsString(
    jsonEncode([for (final d in items) d.toJson()]),
    flush: true,
  );
  await temp.rename('${root.path}/index.json');
  await Downloads.instance.load();
}

void _download(Map media, List<int> numbers) {
  _site.server = _files.uri;
  final episodes = [
    for (var i = 1; i <= _site.episodeCount; i++)
      Episode(i, ref: 'show-${media['id']}/$i'),
  ];
  Downloads.instance.enqueue(
    media,
    siteName,
    episodes.where((e) => numbers.contains(e.number)),
    dub: false,
    season: episodes,
  );
}

/// Waits until nothing is queued or downloading, or [limit] passes.
Future<void> _untilDownloaded(Duration limit) async {
  final end = DateTime.now().add(limit);
  bool busy() => Downloads.instance.items.any(
    (d) =>
        d.status == DownloadStatus.queued ||
        d.status == DownloadStatus.downloading,
  );
  await _wait(const Duration(milliseconds: 300));
  while (busy() && DateTime.now().isBefore(end)) {
    await _wait(const Duration(milliseconds: 100));
  }
  if (busy()) throw StateError('Downloads did not finish within $limit');
  final failed = Downloads.instance.items
      .where(
        (d) =>
            d.media['id'] == fakeShow(0)['id'] &&
            d.status == DownloadStatus.failed,
      )
      .map((d) => d.error)
      .toList();
  if (failed.isNotEmpty) throw StateError('Downloads failed: $failed');
}

/// A player that opens anything and reports its position four times a second while playing. It records every call
/// the app makes, so a scenario can check what was asked of the player.
class _TickingBackend extends PlayerBackend {
  late void Function(Map) _emit;
  Timer? _timer;
  var _position = 0;
  var _playing = false;
  static const _duration = 24 * 60 * 1000;

  /// Where it plays, in ms, and whether it does.
  int get position => _position;
  bool get playing => _playing;

  /// Every volume the app set, 0–1.
  final volumes = <double>[];

  /// How many updates it has sent the app.
  var emits = 0;

  void emit(Map event) {
    emits++;
    _emit(event);
  }

  /// Every call, in order: (method, args).
  final calls = <(String, Map<String, Object?>)>[];

  /// Where each seek asked to go, in ms.
  List<int> get seeks => [
    for (final (m, a) in calls)
      if (m == 'seek') a['ms'] as int,
  ];

  @override
  Future<void> start(void Function(Map) on) async => _emit = on;

  @override
  Future<void> call(String method, Map<String, Object?> args) async {
    calls.add((method, args));
    switch (method) {
      case 'open':
        _position = 0;
        _playing = true;
        emit({
          'position': 0,
          'buffer': 0,
          'duration': _duration,
          'playing': true,
          'buffering': false,
        });
        _timer ??= Timer.periodic(const Duration(milliseconds: 250), (_) {
          if (_playing) _position += 250;
          emit({
            'position': _position,
            'buffer': _position + 30000,
            'duration': _duration,
          });
        });
      case 'seek':
        // ExoPlayer.seek sends {'ms': …}.
        if (args['ms'] case final int at) _position = at;
      case 'play' || 'pause':
        _playing = method == 'play';
        emit({'playing': _playing});
    }
  }

  void stop() => _timer?.cancel();

  @override
  Future<void> setVolume(double level) async => volumes.add(level);
  @override
  Future<void> dispose() async => stop();
}

/// What the screen says, for a failure message.
String _texts() => [
  for (final e in find.byType(Text).hitTestable().evaluate().take(60))
    (e.widget as Text).data ?? (e.widget as Text).textSpan?.toPlainText(),
].join(' | ');

String _wh(Size s) => '${s.width.round()}x${s.height.round()}';

/// Release and profile builds drop Rect.toString.
String _ltrb(Rect r) =>
    '(${r.left.round()},${r.top.round()},${r.right.round()},${r.bottom.round()})';

/// The labels of the episode rows on screen, top first.
List<String> _episodeRows() {
  final label = RegExp(r'^Episode \d+$');
  return [
    for (final e
        in find
            .byWidgetPredicate((w) => w is Text && label.hasMatch(w.data ?? ''))
            .hitTestable()
            .evaluate())
      (e.widget as Text).data!,
  ];
}

Finder _row(String label) => find.text(label).hitTestable().first;

/// A key press. Profile builds drop the key names flutter_test finds the physical key by, so it's given.
Future<void> _key(
  WidgetTester tester,
  LogicalKeyboardKey key,
  PhysicalKeyboardKey physical,
) => tester.sendKeyEvent(key, physicalKey: physical);

// ─────────────────────────────── TV helpers ───────────────────────────────

/// Home's pages, by widget type, in drawer order (lib/home.dart `_pages`).
const _homePages = [
  '_HomeFeed',
  'ScheduleScreen',
  'SearchScreen',
  'MyListScreen',
  '_MeScreen',
];

/// A remote's key: logical, and the physical key flutter_test needs given in profile builds.
typedef _Dpad = (LogicalKeyboardKey, PhysicalKeyboardKey);
const _left = (LogicalKeyboardKey.arrowLeft, PhysicalKeyboardKey.arrowLeft);
const _right = (LogicalKeyboardKey.arrowRight, PhysicalKeyboardKey.arrowRight);
const _up = (LogicalKeyboardKey.arrowUp, PhysicalKeyboardKey.arrowUp);
const _down = (LogicalKeyboardKey.arrowDown, PhysicalKeyboardKey.arrowDown);
const _ok = (LogicalKeyboardKey.select, PhysicalKeyboardKey.select);
const _fastForward = (
  LogicalKeyboardKey.mediaFastForward,
  PhysicalKeyboardKey.mediaFastForward,
);
const _playPause = (
  LogicalKeyboardKey.mediaPlayPause,
  PhysicalKeyboardKey.mediaPlayPause,
);

/// A key pressed and let go, then [gap] for the app to answer.
Future<void> _dpad(
  WidgetTester tester,
  _Dpad key, {
  Duration gap = const Duration(milliseconds: 200),
}) async {
  await _key(tester, key.$1, key.$2);
  await _wait(gap);
}

/// A key held down: the press, Android's repeat delay, [repeats] repeats [every] apart, then the release.
Future<void> _hold(
  WidgetTester tester,
  _Dpad key,
  int repeats, {
  Duration every = const Duration(milliseconds: 50),
  void Function()? onDown,
  void Function(int i)? onRepeat,
}) async {
  await tester.sendKeyDownEvent(key.$1, physicalKey: key.$2);
  await _wait(const Duration(milliseconds: 50));
  onDown?.call();
  await _wait(const Duration(milliseconds: 350));
  for (var i = 0; i < repeats; i++) {
    await tester.sendKeyRepeatEvent(key.$1, physicalKey: key.$2);
    await _wait(every);
    onRepeat?.call(i);
  }
  await tester.sendKeyUpEvent(key.$1, physicalKey: key.$2);
  await _wait(const Duration(milliseconds: 150));
}

/// The system Back (a TV remote's Back reaches the app as a pop-route request).
Future<void> _systemBack(
  WidgetTester tester, {
  Duration gap = const Duration(milliseconds: 400),
}) async {
  await _binding.handlePopRoute();
  await _wait(gap);
}

/// Pushes the player over Home, on [backend].
void _openPlayer(WidgetTester tester, PlayerBackend backend) => unawaited(
  Navigator.of(_pageContext(tester), rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) => PlayerScreen(
        media: fakeShow(5),
        source: _site,
        episodes: [for (var i = 1; i <= 3; i++) Episode(i, ref: '$i')],
        index: 0,
        dub: false,
        backend: backend,
      ),
    ),
  ),
);

/// The focus node of the first Focus inside [target]: the one its own widgets put there.
FocusNode _focusNodeIn(WidgetTester tester, Finder target) {
  final focus = find.descendant(of: target, matching: find.byType(Focus));
  Element? child;
  tester.element(focus.first).visitChildElements((c) => child = c);
  return Focus.of(child!);
}

/// Matches widgets by type name: the private ones can't be named in code.
Finder _named(String type) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == type);

/// Whether a widget of [type] is in the tree, offstage ones too (Home keeps the pages it has left offstage in an
/// IndexedStack).
bool _built(String type) => find
    .byWidgetPredicate(
      (w) => w.runtimeType.toString() == type,
      skipOffstage: false,
    )
    .evaluate()
    .isNotEmpty;

/// The TV player's controls are up: one of its buttons takes a tap.
bool _controlsShown() =>
    _named('_TvControl').hitTestable().evaluate().isNotEmpty;

/// Whether the focused element sits inside a widget of type [type].
bool _inside(String type) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  var found = context.widget.runtimeType.toString() == type;
  if (!found) {
    context.visitAncestorElements((e) {
      found = e.widget.runtimeType.toString() == type;
      return !found;
    });
  }
  return found;
}

bool _inDrawer() => _inside('_TvDrawer');

/// Opens Home's TV drawer: Left until it opens (focus runs left along a row first), else Back. Returns the keys
/// it took.
Future<int> _openDrawer(WidgetTester tester) async {
  var presses = 0;
  for (; presses < 12 && !_inDrawer(); presses++) {
    await _dpad(tester, _left);
  }
  if (!_inDrawer()) {
    await _systemBack(tester);
    presses++;
  }
  if (!_inDrawer()) {
    throw StateError('The drawer did not open; focus on ${_focusName()}');
  }
  return presses;
}

/// What has focus, in the player's terms: `control:<label>`, `seekbar`, `keys` (the player itself), or the
/// focused widget's type.
String _focusName() {
  final node = FocusManager.instance.primaryFocus;
  final context = node?.context;
  if (node == null || context == null) return 'none';
  String? control;
  context.visitAncestorElements((e) {
    if (e.widget.runtimeType.toString() == '_TvControl') {
      control = 'control:${(e.widget as dynamic).label}';
      return false;
    }
    return e.widget is! PlayerScreen;
  });
  if (control != null) return control!;
  Finder below(Type t) => find.descendant(
    of: find.byElementPredicate((e) => e == context),
    matching: find.byType(t),
  );
  if (below(Scaffold).evaluate().isNotEmpty) return 'keys';
  if (below(Slider).evaluate().isNotEmpty) return 'seekbar';
  return context.widget.runtimeType.toString();
}

/// How many times each widget type was built or updated while [action] ran, from the framework's own build
/// timeline (debugProfileBuildsEnabled is honoured in profile builds).
Future<Map<String, int>> _countBuilds(Future<void> Function() action) async {
  FlutterTimeline.debugCollectionEnabled = true;
  debugProfileBuildsEnabled = true;
  try {
    await action();
  } finally {
    debugProfileBuildsEnabled = false;
  }
  final timings = FlutterTimeline.debugCollect();
  FlutterTimeline.debugCollectionEnabled = false;
  final counts = <String, int>{};
  for (final block in timings.timedBlocks) {
    counts[block.name] = (counts[block.name] ?? 0) + 1;
  }
  return counts;
}

/// Frames of [action] taken apart, for reading where a slow one's time went (PERF_TRACE).
///
/// Every frame's framework blocks (BUILD, LAYOUT, PAINT, COMPOSITING, SEMANTICS…) are collected at the end of its
/// drawFrame and paired with its FrameTiming, and frames slower than 6 ms to build or 8.3 ms to raster are reported
/// with each phase's time. With [widgets], every widget build, layout and paint is a block too (the framework's
/// debugProfile*Enabled, honoured in profile builds); that slows the frame, so read its shares, not its times. With
/// [engine], the VM's own timeline (the engine's raster and IO threads) is recorded through the app's VM service and
/// its slow raster frames are reported the same way. [action] calls `mark` at points worth placing frames against;
/// times are given as `<mark> +<ms>`.
Future<Map<String, Object?>> _traceFrames(
  Future<void> Function(void Function(String) mark) action, {
  bool widgets = false,
  bool engine = false,
}) async {
  final vm = engine ? await _Vm.connect() : null;
  await vm?.call('setVMTimelineFlags', {
    'recordedStreams': ['Dart', 'Embedder', 'GC'],
  });
  await vm?.call('clearVMTimeline');
  final marks = <(String, int)>[];
  final timings = <int, FrameTiming>{};
  final frames = <int, List<_Node>>{};
  var on = true;
  void onTimings(List<FrameTiming> list) {
    for (final t in list) {
      timings[t.frameNumber] = t;
    }
  }

  SchedulerBinding.instance.addTimingsCallback(onTimings);
  FlutterTimeline.debugCollectionEnabled = true;
  if (widgets) {
    debugProfileBuildsEnabled = true;
    debugProfileLayoutsEnabled = true;
    debugProfilePaintsEnabled = true;
  }
  // After the renderer's own: the frame's blocks are all closed by then (unlike in a post-frame callback, which runs
  // inside POST_FRAME). Persistent callbacks stay registered; `on` turns this one off.
  SchedulerBinding.instance.addPersistentFrameCallback((_) {
    if (!on) return;
    frames[SchedulerBinding.instance.platformDispatcher.frameData.frameNumber] =
        _tree([
          for (final b in FlutterTimeline.debugCollect().timedBlocks)
            (name: b.name, start: b.start, end: b.end),
        ]);
  });
  try {
    await action((m) => marks.add((m, developer.Timeline.now)));
  } finally {
    on = false;
    debugProfileBuildsEnabled = false;
    debugProfileLayoutsEnabled = false;
    debugProfilePaintsEnabled = false;
    FlutterTimeline.debugCollectionEnabled = false;
  }
  await _wait(const Duration(milliseconds: 600)); // the last timings arrive
  SchedulerBinding.instance.removeTimingsCallback(onTimings);
  String at(int micros) {
    final before = marks.lastWhere(
      (m) => m.$2 <= micros,
      orElse: () => marks.first,
    );
    return '${before.$1} +${((micros - before.$2) / 1000).round()}ms';
  }

  final slow = <Map<String, Object?>>[];
  for (final MapEntry(key: n, value: roots) in frames.entries) {
    final t = timings[n];
    if (t == null) continue;
    final build = t.buildDuration.inMicroseconds / 1000;
    final raster = t.rasterDuration.inMicroseconds / 1000;
    if (build < 6 && raster < 8.3) continue;
    slow.add({
      'frame': n,
      'at': at(t.timestampInMicroseconds(FramePhase.vsyncStart)),
      'build_ms': _ms(build),
      'raster_ms': _ms(raster),
      'phases': {for (final r in roots) r.name: _ms(r.ms)},
      if (widgets && build >= 6) ...{
        'heavy': _heavy(roots, (build * .04).clamp(.3, 2)),
        'self_top': _selfTop(roots, 25),
        'counts_top': _countTop(roots, 25),
      },
    });
  }
  return {
    'frames': frames.length,
    'slow': slow,
    if (vm != null) 'engine': await _engineSummary(vm, marks, at),
  };
}

/// The engine's slow raster frames during [marks] (from the first mark to 2 s after the last), each taken apart
/// like a UI frame, with the longest events on the other engine threads and the GC pauses.
Future<Map<String, Object?>> _engineSummary(
  _Vm vm,
  List<(String, int)> marks,
  String Function(int) at,
) async {
  final timeline = await vm.call('getVMTimeline');
  await vm.call('setVMTimelineFlags', {'recordedStreams': <String>[]});
  await vm.close();
  final events = (timeline['traceEvents'] as List).cast<Map>();
  final threads = <Object?, String>{
    for (final e in events)
      if (e['ph'] == 'M' && e['name'] == 'thread_name')
        e['tid']: '${(e['args'] as Map)['name']}',
  };
  final from = marks.first.$2, to = marks.last.$2 + 2000000;
  final perThread =
      <Object?, List<({String name, double start, double end})>>{};
  final open = <Object?, List<Map>>{};
  for (final e in events) {
    final ts = (e['ts'] as num?)?.toDouble();
    if (ts == null) continue;
    switch (e['ph']) {
      case 'X':
        final dur = (e['dur'] as num? ?? 0).toDouble();
        (perThread[e['tid']] ??= []).add((
          name: '${e['name']}',
          start: ts,
          end: ts + dur,
        ));
      case 'B':
        (open[e['tid']] ??= []).add(e);
      case 'E':
        final stack = open[e['tid']];
        if (stack == null || stack.isEmpty) continue;
        final b = stack.removeLast();
        (perThread[e['tid']] ??= []).add((
          name: '${b['name']}',
          start: (b['ts'] as num).toDouble(),
          end: ts,
        ));
    }
  }
  final rasterSlow = <Map<String, Object?>>[];
  final rasterRoots = <String, int>{};
  final longest = <({String thread, String name, double ms, int at})>[];
  var gcMs = 0.0;
  final gcs = <double>[];
  for (final MapEntry(key: tid, value: blocks) in perThread.entries) {
    final name = threads[tid] ?? '$tid';
    final inWindow = blocks.where((b) => b.start >= from && b.start <= to);
    final roots = _tree(inWindow);
    if (name.contains('raster')) {
      for (final r in roots) {
        rasterRoots[r.name] = (rasterRoots[r.name] ?? 0) + 1;
        if (r.ms < 8.3) continue;
        rasterSlow.add({
          'at': at(r.start.round()),
          'ms': _ms(r.ms),
          'root': r.name,
          'heavy': _heavy([r], .4),
          'self_top': _selfTop([r], 15),
        });
      }
    } else {
      for (final r in roots) {
        if (r.name.startsWith('Collect') || r.name.contains('GC')) {
          gcMs += r.ms;
          gcs.add(r.ms);
        }
        if (r.ms >= 2) {
          longest.add((
            thread: name,
            name: r.name,
            ms: r.ms,
            at: r.start.round(),
          ));
        }
      }
    }
  }
  longest.sort((a, b) => b.ms.compareTo(a.ms));
  gcs.sort((a, b) => b.compareTo(a));
  return {
    'events': events.length,
    'threads': threads.values.toList(),
    'raster_roots': rasterRoots,
    'raster_slow': rasterSlow,
    'other_longest': [
      for (final l in longest.take(25))
        '${l.thread} ${l.name} ${_ms(l.ms)}ms at ${at(l.at)}',
    ],
    'gc_ms': _ms(gcMs),
    'gc_longest': gcs.take(8).map(_ms).toList(),
  };
}

double _ms(double ms) => (ms * 100).round() / 100;

/// A block and the blocks it encloses, in µs.
class _Node {
  _Node(this.name, this.start, this.end);
  final String name;
  final double start, end;
  final children = <_Node>[];
  double get ms => (end - start) / 1000;
  double get selfMs => ms - children.fold(0.0, (s, c) => s + c.ms);
}

/// [blocks] of one thread, nested by time; the roots.
List<_Node> _tree(Iterable<({String name, double start, double end})> blocks) {
  final sorted = blocks.toList()
    ..sort(
      (a, b) => a.start != b.start
          ? a.start.compareTo(b.start)
          : b.end.compareTo(a.end),
    );
  final roots = <_Node>[], stack = <_Node>[];
  for (final b in sorted) {
    while (stack.isNotEmpty && stack.last.end <= b.start) {
      stack.removeLast();
    }
    final node = _Node(b.name, b.start, b.end);
    (stack.isEmpty ? roots : stack.last.children).add(node);
    stack.add(node);
  }
  return roots;
}

/// Where the time went, as an indented list: every block of at least [minMs], and its children of that much.
List<String> _heavy(List<_Node> roots, double minMs) {
  final lines = <String>[];
  void walk(_Node n, int depth) {
    if (lines.length >= 120 || n.ms < minMs) return;
    lines.add('${'  ' * depth}${n.name} ${_ms(n.ms)} (self ${_ms(n.selfMs)})');
    for (final c in n.children) {
      walk(c, depth + 1);
    }
  }

  for (final r in roots) {
    walk(r, 0);
  }
  return lines;
}

Iterable<_Node> _all(List<_Node> roots) sync* {
  for (final r in roots) {
    yield r;
    yield* _all(r.children);
  }
}

/// The [n] names with the most time spent in their own blocks, not their children's.
Map<String, double> _selfTop(List<_Node> roots, int n) {
  final self = <String, double>{};
  for (final b in _all(roots)) {
    self[b.name] = (self[b.name] ?? 0) + b.selfMs;
  }
  final top = self.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  return {for (final e in top.take(n)) e.key: _ms(e.value)};
}

/// The [n] names with the most blocks.
Map<String, int> _countTop(List<_Node> roots, int n) {
  final counts = <String, int>{};
  for (final b in _all(roots)) {
    counts[b.name] = (counts[b.name] ?? 0) + 1;
  }
  final top = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return {
    'all': counts.values.fold(0, (s, c) => s + c),
    for (final e in top.take(n)) e.key: e.value,
  };
}

/// The app's own VM service, spoken to as JSON-RPC over its WebSocket.
class _Vm {
  _Vm(this._socket) {
    _socket.listen((message) {
      final reply = jsonDecode(message as String) as Map;
      final waiting = _pending.remove(reply['id']);
      if (waiting == null) return;
      if (reply['error'] case final error?) {
        waiting.completeError(StateError('VM service: $error'));
      } else {
        waiting.complete(reply['result'] as Map);
      }
    });
  }

  final WebSocket _socket;
  final _pending = <Object?, Completer<Map>>{};
  var _id = 0;

  static Future<_Vm?> connect() async {
    final uri = (await developer.Service.getInfo()).serverWebSocketUri;
    return uri == null ? null : _Vm(await WebSocket.connect('$uri'));
  }

  Future<Map> call(String method, [Map<String, Object?> params = const {}]) {
    final id = '${_id++}';
    final reply = _pending[id] = Completer<Map>();
    _socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    return reply.future;
  }

  Future<void> close() => _socket.close();
}

/// What the downloads store sent while [action] ran: `notifications.list`, changes to the list (what
/// Downloads.instance's own listeners hear: an entry added, started, finished), and `notifications.progress`, progress
/// ticks (what Downloads.instance.ticks and each Download.ticks fire, at most 10 a second). `notifications` is their
/// sum, which is what Downloads.instance's listeners heard before ticks were split off it, so it compares across that.
Future<Map<String, int>> _countNotifications(
  Future<void> Function() action,
) async {
  var list = 0, ticks = 0;
  void onList() => list++;
  void onTick() => ticks++;
  Downloads.instance.addListener(onList);
  Downloads.instance.ticks.addListener(onTick);
  try {
    await action();
  } finally {
    Downloads.instance.removeListener(onList);
    Downloads.instance.ticks.removeListener(onTick);
  }
  return {
    'notifications': list + ticks,
    'notifications.list': list,
    'notifications.progress': ticks,
  };
}

/// Downloads [numbers] of [media] with builds counted, and what the store sent meanwhile (as `counted.*`).
Future<({Map<String, int> builds, Map<String, Object?> notes})>
_countDownloadBuilds(Map media, List<int> numbers) async {
  late Map<String, int> builds;
  final notified = await _countNotifications(() async {
    builds = await _countBuilds(() async {
      _download(media, numbers);
      await _untilDownloaded(const Duration(seconds: 30));
    });
  });
  return (
    builds: builds,
    notes: {for (final e in notified.entries) 'counted.${e.key}': e.value},
  );
}

/// The ten widget types built most while counting, for reading where the builds went.
void _noteTop(String name, Map<String, int> counts) {
  final top = counts.entries.where((e) => !_phase.hasMatch(e.key)).toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  (_binding.reportData![name] as Map)['builds_top'] = {
    for (final e in top.take(10)) e.key: e.value,
  };
}

/// The frame phases the framework times alongside widget builds; not widgets.
final _phase = RegExp(
  r'^[A-Z _]+( \(.*\))?$|^Semantics\.|^Framework |^Preparing |^POST_FRAME',
);

/// [counts] of [types], and all widgets built, as notes.
Map<String, int> _buildsOf(Map<String, int> counts, List<String> types) => {
  'builds.all_widgets': counts.entries
      .where((e) => !_phase.hasMatch(e.key))
      .fold(0, (sum, e) => sum + e.value),
  for (final type in types) 'builds.$type': counts[type] ?? 0,
};

// ─────────────────────────────── Phone helpers ───────────────────────────────

/// [f] inside the player, hidden (opacity 0) parts included.
Finder _inPlayer(Finder f) =>
    find.descendant(of: find.byType(PlayerScreen), matching: f);

/// The phone player's controls are up: they take taps.
bool _phoneControlsShown() =>
    _inPlayer(find.byTooltip('Lock controls'))
        .hitTestable()
        .evaluate()
        .isNotEmpty;

/// Where on the phone player a gesture reaches the picture rather than a control. The controls are laid out whether
/// shown or not, so this holds either way. [band] is the strip between the top bar and the middle row of buttons, for
/// taps, holds and sideways swipes; [leftX] and [rightX] are columns beside the middle row, free from below the top
/// bar ([top]) to above the seek bar ([bottom]), for up and down swipes.
({
  Size size,
  double band,
  double top,
  double bottom,
  double leftX,
  double rightX,
})
_phoneSpots(WidgetTester tester) {
  Rect rect(Finder f) => tester.getRect(_inPlayer(f).first);
  final size = tester.view.physicalSize / tester.view.devicePixelRatio;
  final back = rect(find.byTooltip('Back'));
  final previous = rect(find.byTooltip('Previous episode'));
  final next = rect(find.byTooltip('Next episode'));
  final seek = rect(find.byType(Slider));
  return (
    size: size,
    band: (back.bottom + previous.top) / 2,
    top: back.bottom + 12,
    bottom: seek.top - 12,
    leftX: previous.left / 2,
    rightX: (next.right + size.width) / 2,
  );
}

/// Two taps 120 ms apart: a double tap.
Future<void> _doubleTap(WidgetTester tester, Offset at) async {
  for (var i = 0; i < 2; i++) {
    final g = await tester.startGesture(at);
    await _wait(const Duration(milliseconds: 40));
    await g.up();
    await _wait(const Duration(milliseconds: 80));
  }
}

/// One tap, then long enough for it to count as a single tap (the player also listens for double taps).
Future<void> _singleTap(WidgetTester tester, Offset at) async {
  final g = await tester.startGesture(at);
  await _wait(const Duration(milliseconds: 40));
  await g.up();
  await _wait(const Duration(milliseconds: 500));
}

/// The pill over the phone player's picture: its text, when one shows.
String? _hintText() {
  final pill = find.descendant(
    of: find.byWidgetPredicate(
      (w) =>
          w is DecoratedBox &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).color ==
              Colors.black.withValues(alpha: .7),
    ),
    matching: find.byType(Text),
  );
  final texts = _inPlayer(pill).evaluate();
  return texts.isEmpty ? null : (texts.first.widget as Text).data;
}

/// The seek bars' values in ms, the controls' own first.
List<int> _bars() => [
  for (final e in _inPlayer(find.byType(Slider)).evaluate())
    (e.widget as Slider).value.round(),
];

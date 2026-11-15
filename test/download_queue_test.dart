import 'dart:convert';
import 'dart:io';

import 'package:aniview/downloads.dart';
import 'package:aniview/downloads_view.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/subtitles.dart';
import 'package:flutter_test/flutter_test.dart';

Download download(
  int show,
  num number, {
  DownloadStatus status = DownloadStatus.queued,
  bool dub = false,
  int bytes = 0,
  String? error,
}) => Download(
  media: {'id': show},
  source: 'Anikoto',
  number: number,
  dub: dub,
  ref: 'r',
  status: status,
  bytes: bytes,
  error: error,
);

void enqueue(DownloadQueue queue, Iterable<num> numbers, {bool dub = false}) =>
    queue.enqueue(
      {'id': 1},
      'Anikoto',
      [for (final n in numbers) Episode(n, ref: 'r')],
      dub: dub,
    );

void main() {
  group('DownloadQueue', () {
    test('a failed episode retries with the source and ref picked now', () {
      final failed = download(
        1,
        1,
        status: DownloadStatus.failed,
        error: 'Unavailable',
      );
      final queue = DownloadQueue(readIndex(jsonEncode([failed.toJson()])));
      queue.enqueue(
        {'id': 1},
        'Working source',
        [Episode(1, ref: 'new-ref')],
        dub: false,
      );
      final retry = queue.nextQueued!;
      expect(retry.source, 'Working source');
      expect(retry.ref, 'new-ref');
      expect(retry.error, isNull);
      expect(queue.items, hasLength(1));
    });

    test('enqueue skips queued and done episodes and retries failed ones', () {
      final queue = DownloadQueue([
        download(1, 1, status: DownloadStatus.done),
        download(1, 2, status: DownloadStatus.downloading),
        download(1, 3, status: DownloadStatus.failed, error: 'boom'),
      ]);
      queue.markStarted(queue.entry({'id': 1}, 2, false)!); // running now
      enqueue(queue, [1, 2, 3, 4]);
      expect(
        [for (final d in queue.items) (d.number, d.status)],
        [
          (1, DownloadStatus.done),
          (2, DownloadStatus.downloading),
          (3, DownloadStatus.queued),
          (4, DownloadStatus.queued),
        ],
      );
      expect(queue.items[2].error, isNull);
    });

    test('an episode in the other audio is a different download', () {
      final queue = DownloadQueue([
        download(1, 1, status: DownloadStatus.done),
      ]);
      enqueue(queue, [1], dub: true);
      expect(queue.items, hasLength(2));
    });

    test('needsDownload: never queued, or failed', () {
      expect(DownloadQueue.needsDownload(null), isTrue);
      expect(
        DownloadQueue.needsDownload(
          download(1, 1, status: DownloadStatus.failed),
        ),
        isTrue,
      );
      for (final status in [
        DownloadStatus.queued,
        DownloadStatus.downloading,
        DownloadStatus.done,
      ]) {
        expect(
          DownloadQueue.needsDownload(download(1, 1, status: status)),
          isFalse,
        );
      }
    });

    test('the next one is the earliest queued, and a failure moves on', () {
      final queue = DownloadQueue();
      enqueue(queue, [3, 1, 2]);
      final first = queue.nextQueued!;
      expect(first.number, 3);
      queue.markStarted(first);
      expect(first.status, DownloadStatus.downloading);
      expect(queue.nextQueued!.number, 1);
      queue.markFailed(first, 'boom');
      queue.finish();
      expect((first.status, first.error), (DownloadStatus.failed, 'boom'));
      expect(queue.nextQueued!.number, 1);
      queue.markDone(queue.nextQueued!);
      expect(queue.nextQueued!.number, 2);
      queue.retry(first);
      expect(first.status, DownloadStatus.queued);
      expect(queue.nextQueued, first); // retried: back in line, by list order
    });

    test(
      'removing the active download cancels it and never marks it failed',
      () {
        final queue = DownloadQueue();
        enqueue(queue, [1, 2]);
        final first = queue.nextQueued!;
        queue.markStarted(first);
        expect(queue.cancelled, isFalse);

        expect(queue.remove(first), isTrue);
        expect(queue.cancelled, isTrue);
        queue.markFailed(first, 'stopped');
        expect(first.status, isNot(DownloadStatus.failed));
        queue.finish();
        expect(queue.cancelled, isFalse);
        expect(queue.nextQueued!.number, 2);
      },
    );

    test('removing one that is not running does not cancel the run', () {
      final queue = DownloadQueue();
      enqueue(queue, [1, 2]);
      queue.markStarted(queue.items.first);
      expect(queue.remove(queue.items.last), isFalse);
      expect(queue.cancelled, isFalse);
    });

    test('clearing during a run cancels it', () {
      final queue = DownloadQueue();
      enqueue(queue, [1, 2]);
      expect(queue.clear(), isFalse);
      enqueue(queue, [1]);
      queue.markStarted(queue.items.single);
      expect(queue.clear(), isTrue);
      expect(queue.cancelled, isTrue);
    });

    test('reloading turns interrupted downloads back into queued ones', () {
      final queue = DownloadQueue([
        download(1, 1, status: DownloadStatus.downloading),
        download(1, 2, status: DownloadStatus.done),
        download(1, 3, status: DownloadStatus.failed),
      ]);
      expect(
        [for (final d in queue.items) d.status],
        [DownloadStatus.queued, DownloadStatus.done, DownloadStatus.failed],
      );
      expect(queue.nextQueued!.number, 1);
    });
  });

  group('DownloadStore', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('downloads'));
    tearDown(() => root.deleteSync(recursive: true));

    String index(int show) => jsonEncode([download(show, 1).toJson()]);

    test('reads saved downloads; a broken index requires recovery', () async {
      final store = DownloadStore(root);
      expect(await store.read(), isEmpty);
      await store.write(index(5));
      expect([for (final d in await store.read()) d.media['id']], [5]);
      File('${root.path}/index.json').writeAsStringSync('{broken');
      await expectLater(store.read(), throwsFormatException);
    });

    test('a failed write leaves the old index intact', () async {
      final store = DownloadStore(root);
      await store.write(index(5));
      // The aside file's path is taken by a folder, so writing it fails.
      Directory('${root.path}/index.json.tmp').createSync();
      await expectLater(store.write(index(6)), throwsA(anything));
      expect([for (final d in await store.read()) d.media['id']], [5]);
    });
  });

  group('DownloadsView', () {
    test('a filter that empties falls back to All', () {
      final items = [download(1, 1, status: DownloadStatus.done)];
      expect(DownloadsView(items, filter: 'Failed').filter, 'All');
      expect(DownloadsView(items, filter: 'Done').filter, 'Done');
      expect(DownloadsView([], filter: 'Failed').filter, 'All');
    });

    test('chips list filters with something in them, with counts', () {
      final view = DownloadsView([
        download(1, 1, status: DownloadStatus.done),
        download(1, 2, status: DownloadStatus.failed),
        download(1, 3, status: DownloadStatus.failed),
      ]);
      expect(view.chips, [('All', 3), ('Failed', 2), ('Done', 1)]);
    });

    test(
      'downloads group by show in order, filtered and sorted by episode',
      () {
        final view = DownloadsView([
          download(1, 2, status: DownloadStatus.done),
          download(2, 1, status: DownloadStatus.failed),
          download(1, 1, status: DownloadStatus.done, bytes: 2048),
        ], filter: 'Done');
        final shows = view.shows;
        expect([for (final s in shows) s.id], [1]);
        expect([for (final d in shows.single.shown) d.number], [1, 2]);
        expect(shows.single.all, hasLength(2));
        expect(shows.single.summary, '2 episodes · 2 KB');
      },
    );

    test('a show is open when it has something to act on, is alone, or under a filter', () {
      bool open(
        List<Download> items, {
        String filter = 'All',
        Set<Object?> toggled = const {},
      }) => DownloadsView(
        items,
        filter: filter,
        toggled: toggled,
      ).shows.first.open;
      final done = download(1, 1, status: DownloadStatus.done);
      final other = download(2, 1, status: DownloadStatus.done);
      expect(open([done, other]), isFalse); // finished, among several
      expect(open([done]), isTrue); // a single show
      expect(open([done, other], filter: 'Done'), isTrue); // narrowed down
      expect(open([done, download(1, 2), other]), isTrue); // something waiting
      expect(open([done, other], toggled: {1}), isTrue); // flipped by the user
      expect(open([done], toggled: {1}), isFalse);
    });

    test('status text per state', () {
      expect(DownloadsView.statusText(download(1, 1)), 'Waiting to download');
      expect(
        DownloadsView.statusText(
          download(1, 1, status: DownloadStatus.downloading, bytes: 2048)
            ..progress = 0.5,
        ),
        '50% · 2 KB',
      );
      expect(
        DownloadsView.statusText(
          download(1, 1, status: DownloadStatus.done, bytes: 2048, dub: true),
        ),
        '2 KB · Dub · Anikoto',
      );
      expect(
        DownloadsView.statusText(download(1, 1, status: DownloadStatus.failed)),
        'Download failed',
      );
      expect(
        DownloadsView.statusText(
          download(1, 1, status: DownloadStatus.failed, error: 'no servers'),
        ),
        'no servers',
      );
    });
  });

  test(
    'entry finds each episode after adds, replacements, removals and a reload',
    () {
      final queue = DownloadQueue([
        download(1, 1, status: DownloadStatus.done),
        download(
          1,
          1,
          status: DownloadStatus.failed,
        ), // a duplicate an old index can hold
        download(1, 2, dub: true),
      ]);
      final first = queue.items[0], duplicate = queue.items[1];
      expect(queue.entry({'id': 1}, 1, false), same(first));
      expect(queue.entry({'id': 1}, 2, true), same(queue.items[2]));
      expect(queue.entry({'id': 1}, 2, false), isNull);
      expect(queue.entry({'id': 1}, 2.0, true), same(queue.items[2]));

      enqueue(queue, [3]);
      expect(queue.entry({'id': 1}, 3, false), same(queue.items.last));

      queue.remove(first);
      expect(queue.entry({'id': 1}, 1, false), same(duplicate));
      enqueue(queue, [1]); // the failed one is replaced in place
      final replaced = queue.entry({'id': 1}, 1, false)!;
      expect(replaced, isNot(same(duplicate)));
      expect(queue.items, contains(replaced));
      queue.remove(replaced);
      expect(queue.entry({'id': 1}, 1, false), isNull);

      final reloaded = DownloadQueue(
        readIndex(jsonEncode([for (final d in queue.items) d.toJson()])),
      );
      for (final d in reloaded.items) {
        expect(reloaded.entry(d.media, d.number, d.dub), same(d));
      }
      expect(reloaded.entry({'id': 1}, 1, false), isNull);

      // Straight to the list, as the episode actions tests do.
      queue.items.add(download(5, 1));
      expect(queue.entry({'id': 5}, 1, false), same(queue.items.last));

      queue.clear();
      expect(queue.entry({'id': 1}, 3, false), isNull);
    },
  );

  test('a long season encodes off the UI isolate exactly as here', () async {
    List<Episode> season(int n) => [
      for (var i = 1; i <= n; i++)
        Episode(i, ref: {'id': 'e$i'}, title: 'Ep "$i"', overview: 'é\n$i'),
    ];
    for (final n in [3, 1200]) {
      expect(await encodeSeason(season(n)), jsonEncode(season(n)));
    }
  });

  test('a big subtitle file parses off the UI isolate exactly as here', () async {
    String srt(int n) => [
      for (var i = 1; i <= n; i++)
        '$i\n00:${(i ~/ 60 % 60).toString().padLeft(2, '0')}:${(i % 60).toString().padLeft(2, '0')},500 --> '
            '00:${(i ~/ 60 % 60).toString().padLeft(2, '0')}:${(i % 60).toString().padLeft(2, '0')},900\n<i>Line $i</i>\n',
    ].join('\n');
    for (final text in [srt(3), srt(3000)]) {
      final cues = await cuesOf(text, 'srt');
      expect(cues, isNotEmpty);
      expect(cues, parseCues(text, 'srt'));
    }
    expect(srt(3000).length, greaterThan(32 * 1024));
  });
}

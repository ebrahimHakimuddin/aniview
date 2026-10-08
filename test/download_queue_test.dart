import 'dart:convert';
import 'dart:io';

import 'package:aniview/downloads.dart';
import 'package:aniview/downloads_view.dart';
import 'package:aniview/sources.dart';
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
    test('a failed episode retries with the newly selected source and ref after restart', () {
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
      queue.markStarted(retry);
      queue.markDone(retry);
      expect(queue.entry({'id': 1}, 1, false)!.status, DownloadStatus.done);
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

    test(
      'reads back what it wrote, and nothing from a missing or broken index',
      () async {
        final store = DownloadStore(root);
        expect(await store.read(), isEmpty);
        await store.write(index(5));
        expect([for (final d in await store.read()) d.media['id']], [5]);
        File('${root.path}/index.json').writeAsStringSync('{broken');
        expect(await store.read(), isEmpty);
      },
    );

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
}

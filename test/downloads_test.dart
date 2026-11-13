import 'dart:convert';
import 'dart:io';

import 'package:aniview/downloads.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/stream_address.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('gallery export chooses exactly one destination', () {
    expect(downloadExport(false, ''), DownloadExport.private);
    expect(downloadExport(false, 'chosen'), DownloadExport.private);
    expect(downloadExport(true, ''), DownloadExport.gallery);
    expect(downloadExport(true, 'chosen'), DownloadExport.customFolder);
  });
  test('named export folders survive restart and document address routing', () {
    final download = Download(
      media: {
        'id': 7,
        'title': {'romaji': 'Frieren: Beyond'},
      },
      source: 'Fixture',
      number: 2,
      dub: false,
      ref: '2',
    );
    download.storagePath = download.exportFolder;
    download.storageUri = 'content://tree';
    final restored = Download.fromJson(download.toJson());
    expect(restored.relativeFolder, 'Frieren Beyond/Episode 2-sub');
    final (location, file) = DownloadLocation.parse(
      Downloads.instance.streamFor(restored).url,
    )!;
    expect((location as DocumentFolder).id, restored.relativeFolder);
    expect(file, 'index.m3u8');
    expect(
      Download.fromJson({...download.toJson(), 'storagePath': null})
          .relativeFolder,
      download.id,
    );
  });

  test(
    'sandbox downloads survive restart with a different container path',
    () async {
      final container = await Directory.systemTemp.createTemp(
        'aniview_sandbox',
      );
      addTearDown(() => container.delete(recursive: true));
      final originalRoot = await Directory('${container.path}/before/downloads')
          .create(recursive: true);
      final download = Download(
        media: {'id': 42},
        source: 'Anikoto',
        number: 1,
        dub: false,
        ref: 'ep1',
        status: DownloadStatus.done,
        subtitles: [Subtitle('English', 'sub0.vtt')],
      );
      final episode = await Directory('${originalRoot.path}/${download.id}')
          .create();
      await File('${episode.path}/index.m3u8')
          .writeAsString('#EXTM3U\n#EXTINF:5,\nseg00000.ts\n#EXT-X-ENDLIST');
      await File('${episode.path}/seg00000.ts')
          .writeAsBytes([0x47, 0x40, 0x11]);
      await File('${episode.path}/sub0.vtt').writeAsString('WEBVTT\n');
      await DownloadStore(originalRoot).write(jsonEncode([download.toJson()]));

      final relocated = await originalRoot.rename('${container.path}/after');
      final restored = (await DownloadStore(relocated).read()).single;
      final folder = LocalFolder('${relocated.path}/${restored.id}');
      expect(restored.status, DownloadStatus.done);
      expect(restored.storageUri, isNull);
      expect(
        restored.video,
        isNull,
      ); // iOS keeps HLS, without launching ffmpeg.
      expect(
        await File(folder.urlOf('index.m3u8')).readAsString(),
        contains('seg00000.ts'),
      );
      expect(
        await File(folder.urlOf(restored.subtitles.single.url)).exists(),
        isTrue,
      );
      expect(jsonEncode(restored.toJson()), isNot(contains(originalRoot.path)));
    },
  );

  test(
    'partial segments resume from the same source, not from another',
    () async {
      final dir = Directory.systemTemp.createTempSync('aniview_segments');
      addTearDown(() => dir.deleteSync(recursive: true));
      await prepareHlsFiles(dir, 'Old\nep-1');
      final segment = File('${dir.path}/seg00000.ts')..writeAsStringSync('old');
      await prepareHlsFiles(dir, 'Old\nep-1');
      expect(segment.readAsStringSync(), 'old');
      await prepareHlsFiles(dir, 'New\nep-1');
      expect(segment.existsSync(), isFalse);
    },
  );

  desktopFolderTests();
  sameTitleTests();
  test('one unreadable download is skipped, not the whole list', () {
    final good = Download(
      media: {'id': 1},
      source: 'Anikoto',
      number: 3,
      dub: false,
      ref: 'r',
    ).toJson();
    final downloads = readIndex(
      jsonEncode([
        good,
        {...good, 'number': 'three'}, // wrong type
        {'source': 'Anikoto'}, // missing fields
        'not a map',
      ]),
    );
    expect([for (final d in downloads) (d.media['id'], d.number)], [(1, 3)]);
  });

  test('chosen folder remains attached to a saved episode after restart', () {
    final original = Download(
      media: {'id': 7},
      source: 'Anikoto',
      number: 12,
      dub: false,
      ref: 'r',
      status: DownloadStatus.done,
      storageUri: 'content://com.android.externalstorage.documents/tree/primary%3AAnime',
    );
    final restored = readIndex(jsonEncode([original.toJson()])).single;
    expect(restored.storageUri, original.storageUri);
    expect(restored.status, DownloadStatus.done);
    final stream = Downloads.instance.streamFor(restored);
    expect(stream.isLocal, isTrue);
    expect(stream.isHls, isTrue);
  });

  test('tells a playlist from a video by how a file starts', () {
    expect(isPlaylist(utf8.encode('\uFEFF #EXTM3U\n#EXT-X-VERSION:3')), isTrue);
    expect(isPlaylist([0, 0, 0, 32, ...'ftypisom'.codeUnits]), isFalse);
    expect(isVideoFile([0, 0, 0, 32, ...'ftypisom'.codeUnits]), isTrue);
    expect(isVideoFile([0x1A, 0x45, 0xDF, 0xA3, 1]), isTrue); // Matroska
    expect(isVideoFile([0x47, 0x40, 0x11]), isTrue); // MPEG-TS
    expect(isVideoFile(utf8.encode('<html>Forbidden')), isFalse);
  });

  test('a saved MP4 is what plays, under the show\'s name', () {
    final original = Download(
      media: {
        'id': 7,
        'title': {'romaji': 'Frieren: Beyond'},
      },
      source: 'Anikoto',
      number: 12,
      dub: true,
      ref: 'r',
      status: DownloadStatus.done,
    );
    expect(original.name, 'Frieren Beyond - Episode 12 (Dub)');
    original.video = '${original.name}.mp4';
    final restored = readIndex(jsonEncode([original.toJson()])).single;
    final stream = Downloads.instance.streamFor(restored);
    expect(
      stream.url,
      endsWith('/7-12-dub/Frieren Beyond - Episode 12 (Dub).mp4'),
    );
    expect(stream.isHls, isFalse);
  });
  deleteFreesSpaceTests();
}

void desktopFolderTests() {
  test('the desktop moves its downloads to a folder you pick', () async {
    final a = Directory.systemTemp.createTempSync('aniview_a');
    final b = Directory.systemTemp.createTempSync('aniview_b');
    addTearDown(() {
      a.deleteSync(recursive: true);
      b.deleteSync(recursive: true);
    });
    SharedPreferences.setMockInitialValues({'desktop_download_folder': a.path});
    await Settings.load();
    await Downloads.instance.load();
    expect(Downloads.instance.folder, '${a.path}/AniView');
    Directory('${Downloads.instance.folder}/abc').createSync();
    File('${Downloads.instance.folder}/abc/ep.ts').writeAsStringSync('x');

    await Downloads.instance.moveTo(b.path);

    expect(Downloads.instance.folder, '${b.path}/AniView');
    expect(File('${b.path}/AniView/abc/ep.ts').existsSync(), isTrue);
    expect(Directory('${a.path}/AniView/abc').existsSync(), isFalse);
    expect(Settings.desktopDownloadFolder, b.path);
  });
}

Download _episode(int id, num number, {String? folder}) => Download(
  media: {
    'id': id,
    'title': {'romaji': 'Hunter x Hunter'},
  },
  source: 'Anikoto',
  number: number,
  dub: false,
  ref: '$number',
  status: DownloadStatus.done,
  storagePath: folder,
);

void sameTitleTests() {
  test('a show downloaded alone keeps the plain title folder', () {
    final only = _episode(1, 1);
    expect(newDownloadFolder(only, [only]), 'Hunter x Hunter/Episode 1-sub');
  });

  test('same-titled shows get separate folders, a show never splits', () {
    final first = _episode(1, 1);
    first.storagePath = newDownloadFolder(first, [first]);
    final second = _episode(2, 1);
    second.storagePath = newDownloadFolder(second, [first, second]);
    expect(first.relativeFolder, 'Hunter x Hunter/Episode 1-sub');
    expect(second.relativeFolder, 'Hunter x Hunter [2]/Episode 1-sub');

    final next = _episode(2, 2);
    expect(
      newDownloadFolder(next, [first, second, next]),
      'Hunter x Hunter [2]/Episode 2-sub',
    );
    final firstNext = _episode(1, 2);
    expect(
      newDownloadFolder(firstNext, [first, second, firstNext]),
      'Hunter x Hunter/Episode 2-sub',
    );
  });

  test('a title differing only in case still gets its own folder', () {
    final first = _episode(1, 1, folder: 'hunter x hunter/Episode 1-sub');
    final second = _episode(2, 1);
    expect(
      newDownloadFolder(second, [first, second]),
      'Hunter x Hunter [2]/Episode 1-sub',
    );
  });

  test('removing one show leaves the same-titled show on disk', () async {
    final parent = Directory.systemTemp.createTempSync('aniview_same_title');
    addTearDown(() => parent.deleteSync(recursive: true));
    final root = Directory('${parent.path}/AniView')..createSync();
    final first = _episode(1, 1, folder: 'Hunter x Hunter/Episode 1-sub');
    final second = _episode(2, 1, folder: 'Hunter x Hunter [2]/Episode 1-sub');
    for (final d in [first, second]) {
      File('${root.path}/${d.relativeFolder}/index.m3u8')
        ..createSync(recursive: true)
        ..writeAsStringSync('#EXTM3U');
    }
    await DownloadStore(root)
        .write(jsonEncode([first.toJson(), second.toJson()]));
    SharedPreferences.setMockInitialValues({
      'desktop_download_folder': parent.path,
    });
    await Settings.load();
    await Downloads.instance.load();

    await Downloads.instance.remove(Downloads.instance.items.first);

    expect(
      Directory('${root.path}/Hunter x Hunter/Episode 1-sub').existsSync(),
      isFalse,
    );
    expect(
      File('${root.path}/Hunter x Hunter [2]/Episode 1-sub/index.m3u8')
          .existsSync(),
      isTrue,
    );
    expect([for (final d in Downloads.instance.items) d.media['id']], [2]);
  });
}

/// An index whose next [failures] writes fail, as on a full disk.
class _FlakyStore extends DownloadStore {
  _FlakyStore(super.root, this.failures);
  int failures;

  @override
  Future<void> write(String json) async {
    if (failures > 0) {
      failures--;
      throw const FileSystemException('No space left on device');
    }
    await super.write(json);
  }
}

void deleteFreesSpaceTests() {
  /// A library of two finished episodes of different shows, on disk and loaded.
  Future<Directory> library() async {
    final parent = Directory.systemTemp.createTempSync('aniview_full_disk');
    addTearDown(() => parent.deleteSync(recursive: true));
    final root = Directory('${parent.path}/AniView')..createSync();
    final episodes = [
      _episode(1, 1, folder: 'First/Episode 1-sub'),
      _episode(2, 1, folder: 'Second/Episode 1-sub'),
    ];
    for (final d in episodes) {
      File('${root.path}/${d.relativeFolder}/index.m3u8')
        ..createSync(recursive: true)
        ..writeAsStringSync('#EXTM3U');
    }
    await DownloadStore(root)
        .write(jsonEncode([for (final d in episodes) d.toJson()]));
    SharedPreferences.setMockInitialValues({
      'desktop_download_folder': parent.path,
    });
    await Settings.load();
    await Downloads.instance.load();
    expect(Downloads.instance.storageError, isNull);
    return root;
  }

  List<Object?> saved(Directory root) => [
    for (final d in readIndex(
      File('${root.path}/index.json').readAsStringSync(),
    ))
      d.media['id'],
  ];

  test('a delete whose index write fails once retries it', () async {
    final root = await library();
    Downloads.instance.store = _FlakyStore(root, 1);

    await Downloads.instance.remove(Downloads.instance.items.first);

    expect(Downloads.instance.storageError, isNull);
    expect(Directory('${root.path}/First/Episode 1-sub').existsSync(), isFalse);
    expect(saved(root), [2]);
  });

  test('a delete still frees space when the index cannot be written', () async {
    final root = await library();
    final store = _FlakyStore(root, 2);
    Downloads.instance.store = store;

    await Downloads.instance.remove(Downloads.instance.items.first);

    expect(Downloads.instance.storageError, isNotNull);
    expect(Directory('${root.path}/First/Episode 1-sub').existsSync(), isFalse);
    expect(saved(root), [1, 2]);

    // Other changes wait for storage, but deleting more is still allowed, and clears the error once a write works.
    expect(
      () => Downloads.instance.retry(Downloads.instance.items.single),
      throwsStateError,
    );
    await Downloads.instance.remove(Downloads.instance.items.single);
    expect(Downloads.instance.storageError, isNull);
    expect(
      Directory('${root.path}/Second/Episode 1-sub').existsSync(),
      isFalse,
    );
    expect(saved(root), isEmpty);
  });

  test('deleting everything retries the index write once', () async {
    final root = await library();
    Downloads.instance.store = _FlakyStore(root, 1);

    await Downloads.instance.removeAll();

    expect(Downloads.instance.storageError, isNull);
    expect(root.listSync().whereType<Directory>(), isEmpty);
    expect(saved(root), isEmpty);
  });

  test(
    'deleting everything frees space when the index cannot be written',
    () async {
      final root = await library();
      final store = _FlakyStore(root, 2);
      Downloads.instance.store = store;

      await Downloads.instance.removeAll();

      expect(Downloads.instance.storageError, isNotNull);
      expect(root.listSync().whereType<Directory>(), isEmpty);
      expect(saved(root), [1, 2]);

      await Downloads.instance.removeAll();
      expect(Downloads.instance.storageError, isNull);
      expect(saved(root), isEmpty);
    },
  );

  test(
    'a finished download whose files are gone is not offered to play',
    () async {
      final root = await library();
      Directory('${root.path}/First').deleteSync(recursive: true);

      await Downloads.instance.load();

      final missing = Downloads.instance.items.first;
      expect(missing.status, DownloadStatus.failed);
      expect(Downloads.instance.find(missing.media, 1), isNull);
      expect(Downloads.instance.find({'id': 2}, 1), isNotNull);
    },
  );

  test('a missing download folder still refuses deletes', () async {
    final root = await library();
    final parent = root.parent.path;
    final detached = await root.parent.rename('$parent-detached');
    // Put back for the library's own clean-up.
    addTearDown(() => detached.renameSync(parent));
    await Downloads.instance.load();
    expect(Downloads.instance.storageError, isNotNull);

    await expectLater(
      Downloads.instance.remove(Downloads.instance.items.first),
      throwsStateError,
    );
    await expectLater(Downloads.instance.removeAll(), throwsStateError);
  });
}

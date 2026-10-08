import 'dart:convert';
import 'dart:io';

import 'package:aniview/downloads.dart';
import 'package:aniview/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('staged video files', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('aniview_video'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('matching playlists resume; changing source discards old segments and keys', () async {
      final files = {
        'seg00000.ts': Uri.parse('https://old.test/a.ts'),
        'key0.bin': Uri.parse('https://old.test/key'),
      };
      await prepareHlsFiles(dir, files);
      final segment = File('${dir.path}/seg00000.ts')..writeAsStringSync('old');
      File('${dir.path}/key0.bin').writeAsStringSync('old key');
      await prepareHlsFiles(dir, files);
      expect(segment.readAsStringSync(), 'old');
      await prepareHlsFiles(dir, {
        'seg00000.ts': Uri.parse('https://new.test/b.ts'),
      });
      expect(segment.existsSync(), isFalse);
      expect(File('${dir.path}/key0.bin').existsSync(), isFalse);
    });

    test(
      'successful conversion keeps only the playable MP4 and subtitles',
      () async {
        for (final file in [
          'index.m3u8',
          'seg00000.ts',
          'key0.bin',
          'segments.json',
          'sub0.vtt',
        ]) {
          File('${dir.path}/$file').writeAsStringSync('staged');
        }
        final output = await finishHlsVideo(
          dir,
          convert: (path) async {
            expect(File('$path/index.m3u8').existsSync(), isTrue);
            File('$path/episode.mp4').writeAsStringSync('converted video');
          },
        );
        expect(output, 'episode.mp4');
        expect(
          dir.listSync().map((f) => f.uri.pathSegments.last),
          unorderedEquals(['episode.mp4', 'sub0.vtt']),
        );
      },
    );

    test(
      'failed or empty conversion preserves the staged segments for retry',
      () async {
        final segment = File('${dir.path}/seg00000.ts')
          ..writeAsStringSync('video data');
        await expectLater(
          finishHlsVideo(
            dir,
            convert: (_) async => throw Exception('Unsupported codec'),
          ),
          throwsException,
        );
        expect(segment.readAsStringSync(), 'video data');
        await expectLater(
          finishHlsVideo(dir, convert: (_) async {}),
          throwsFormatException,
        );
        expect(segment.existsSync(), isTrue);
      },
    );
  });

  desktopFolderTests();
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

  test(
    'MP4 downloads retain their video file and document address after restart',
    () {
      final original = Download(
        media: {'id': 7},
        source: 'Working',
        number: 1,
        dub: false,
        ref: 'r',
        status: DownloadStatus.done,
        storageUri: 'content://tree/anime',
        videoFile: 'episode.mp4',
      );
      final restored = readIndex(jsonEncode([original.toJson()])).single;
      final stream = Downloads.instance.streamFor(restored);
      expect(restored.videoFile, 'episode.mp4');
      expect(stream.url, endsWith('/episode.mp4'));
      expect(stream.isHls, isFalse);
      expect(stream.isLocal, isTrue);
    },
  );
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

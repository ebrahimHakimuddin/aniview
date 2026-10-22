import 'dart:convert';
import 'dart:io';

import 'package:aniview/downloads.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/stream_address.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
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

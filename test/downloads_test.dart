import 'dart:convert';
import 'dart:io';

import 'package:aniview/downloads.dart';
import 'package:aniview/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
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

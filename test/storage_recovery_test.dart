import 'dart:io';
import 'dart:convert';

import 'package:aniview/downloads.dart';
import 'package:aniview/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'copy failure and restart preserve the complete original library',
    () async {
      final parent = await Directory.systemTemp.createTemp('storage_partial');
      addTearDown(() => parent.delete(recursive: true));
      final before = await Directory('${parent.path}/before').create();
      SharedPreferences.setMockInitialValues({
        'desktop_download_folder': before.path,
      });
      await Settings.load();
      await Downloads.instance.load();
      final root = Downloads.instance.folder;
      await File('$root/first').writeAsString('first');
      await Link('$root/unsupported').create('missing');
      await expectLater(
        Downloads.instance.moveTo('${parent.path}/after'),
        throwsA(isA<FileSystemException>()),
      );
      await Downloads.instance.load();
      expect(Downloads.instance.storageError, isNull);
      expect(await File('$root/first').readAsString(), 'first');
      expect(Settings.desktopDownloadFolder, before.path);
      expect(await Directory('${parent.path}/after/AniView').exists(), isFalse);
    },
    skip: Platform.isWindows,
  );

  test('reconnecting a missing folder restores its original index', () async {
    final parent = await Directory.systemTemp.createTemp('storage_reconnect');
    addTearDown(() => parent.delete(recursive: true));
    final chosen = await Directory('${parent.path}/mounted').create();
    final root = await Directory('${chosen.path}/AniView').create();
    final download = Download(
      media: {'id': 42},
      source: 'Fixture',
      number: 1,
      dub: false,
      ref: '1',
      status: DownloadStatus.done,
    );
    await DownloadStore(root).write(jsonEncode([download.toJson()]));
    SharedPreferences.setMockInitialValues({
      'desktop_download_folder': chosen.path,
    });
    await Settings.load();
    final detached = await chosen.rename('${parent.path}/detached');
    await Downloads.instance.load();
    expect(Downloads.instance.storageError, isNotNull);
    expect(await chosen.exists(), isFalse);
    await detached.rename(chosen.path);
    await Downloads.instance.reconnect();
    expect(Downloads.instance.storageError, isNull);
    expect(Downloads.instance.items.single.id, download.id);
  });

  test('unavailable download root does not abort startup', () async {
    final parent = await Directory.systemTemp.createTemp('storage_recovery');
    addTearDown(() => parent.delete(recursive: true));
    final blocked = File('${parent.path}/blocked');
    await blocked.writeAsString('not a directory');
    SharedPreferences.setMockInitialValues({
      'desktop_download_folder': blocked.path,
    });
    await Settings.load();
    await expectLater(Downloads.instance.load(), completes);
    expect(Settings.desktopDownloadFolder, blocked.path);
  });
  test(
    'failed migration leaves every original file and setting intact',
    () async {
      final parent = await Directory.systemTemp.createTemp('storage_migration');
      addTearDown(() => parent.delete(recursive: true));
      final before = await Directory('${parent.path}/before').create();
      final after = await Directory('${parent.path}/after/AniView')
          .create(recursive: true);
      SharedPreferences.setMockInitialValues({
        'desktop_download_folder': before.path,
      });
      await Settings.load();
      await Downloads.instance.load();
      final root = Downloads.instance.folder;
      await File('$root/first').writeAsString('first');
      await Directory('$root/second').create();
      await File('$root/second/video').writeAsString('video');
      await File('${after.path}/second').writeAsString('collision');
      await expectLater(
        Downloads.instance.moveTo(after.parent.path),
        throwsA(anything),
      );
      expect(await File('$root/first').readAsString(), 'first');
      expect(await File('$root/second/video').readAsString(), 'video');
      expect(Settings.desktopDownloadFolder, before.path);
    },
  );
}

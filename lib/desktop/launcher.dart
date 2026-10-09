import 'dart:io';

import 'package:flutter/services.dart';

/// The app's id on Linux: its window class, and the name of its menu entry.
const launcherId = 'com.kidfury.aniview';

String? get _home => Platform.environment['HOME'];

File? get _entry => _home == null
    ? null
    : File('$_home/.local/share/applications/$launcherId.desktop');

/// Whether AniView is in the app menu (a .desktop entry for it exists).
Future<bool> launcherInstalled() async =>
    Platform.isLinux && (await _entry?.exists() ?? false);

/// Puts AniView in the app menu, with its icon, and makes it the handler of `aniview://` links (which bring the browser's
/// sign-in back). Run again after moving the app, to point the entry at its new place. A package would install
/// the same file.
Future<void> installLauncher() async {
  final home = _home, entry = _entry;
  if (!Platform.isLinux || home == null || entry == null) return;
  final data = Directory('$home/.local/share/$launcherId');
  await data.create(recursive: true);
  final icon = File('${data.path}/icon.png');
  final bytes = await rootBundle.load('assets/icon/aniview_app_icon.png');
  await icon.writeAsBytes(
    bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
  );
  await entry.parent.create(recursive: true);
  await entry.writeAsString(
    '[Desktop Entry]\n'
    'Type=Application\n'
    'Name=AniView\n'
    'GenericName=Anime player\n'
    'Comment=Watch anime and keep track of it on AniList\n'
    'Exec="${Platform.resolvedExecutable}" %U\n'
    'Icon=${icon.path}\n'
    'Terminal=false\n'
    'Categories=AudioVideo;Video;Player;\n'
    'StartupWMClass=$launcherId\n'
    'MimeType=x-scheme-handler/aniview;\n',
  );
  try {
    await Process.run('update-desktop-database', [entry.parent.path]);
    await Process.run('xdg-mime', [
      'default',
      '$launcherId.desktop',
      'x-scheme-handler/aniview',
    ]);
  } catch (_) {} // the entry is still in place; a desktop that lacks these finds it on its own
}

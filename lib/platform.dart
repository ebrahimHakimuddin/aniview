import 'dart:io';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Linux, Windows or macOS: a mouse and keyboard, a resizable window, no phone sensors. Tests run on one of them, so
/// they set it themselves (see test/flutter_test_config.dart).
bool isDesktop = Platform.isLinux || Platform.isWindows || Platform.isMacOS;

/// The desktop's shortcut key: Cmd on a Mac, Ctrl on Windows and Linux.
String get shortcutKey => Platform.isMacOS ? 'Cmd' : 'Ctrl';

/// Whether the shortcut key is held, for Ctrl+click (Cmd+click on a Mac) to select several.
bool get shortcutKeyHeld => Platform.isMacOS
    ? HardwareKeyboard.instance.isMetaPressed
    : HardwareKeyboard.instance.isControlPressed;

/// The Android side of the app: MainActivity.kt's 'aniview/app' and 'aniview/volume' channels. Off Android every
/// call throws [MissingPluginException]; failures on Android arrive as [PlatformException] with the reason.
class AndroidApp {
  static const _app = MethodChannel('aniview/app');
  static const _folder = MethodChannel('aniview/folder');
  static const _volume = MethodChannel('aniview/volume');
  static const _extensions = MethodChannel('aniview/extensions');

  static Future<String?> version() async => Platform.isAndroid
      ? _app.invokeMethod<String>('version')
      : (await PackageInfo.fromPlatform()).version;

  /// "Android 14; Pixel 7"; the OS version elsewhere.
  static Future<String?> device() async => Platform.isAndroid
      ? _app.invokeMethod<String>('device')
      : Platform.operatingSystemVersion;

  /// The primary ABI, to pick the matching release APK.
  static Future<String?> abi() async =>
      Platform.isAndroid ? _app.invokeMethod<String>('abi') : null;

  /// The phone's wallpaper accent (ARGB) on Android 12+; null before Material You or off Android.
  static Future<int?> accent() async {
    try {
      return await _app.invokeMethod<int>('accent');
    } catch (_) {
      return null;
    }
  }

  /// A call to the installed Aniyomi extensions (Extensions.kt); a failure is a [PlatformException] with the reason, or
  /// with code 'cloudflare' and the site's address when its check needs passing by hand.
  static Future<Object?> extensions(String method, [Map? args]) =>
      _extensions.invokeMethod(method, args);

  /// Whether Android shows navigation buttons (three-button, or the old two-button) rather than gestures.
  static Future<bool> buttonNavigation() async {
    try {
      return await _app.invokeMethod<int>('navigationMode') != 2;
    } catch (_) {
      return false;
    }
  }

  /// Running on a TV (leanback UI mode); false off Android.
  static Future<bool> isTv() async {
    try {
      return await _app.invokeMethod<bool>('tv') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens [url] in the browser or whichever app handles it.
  static Future<void> open(String url) async {
    try {
      await _app.invokeMethod('open', url);
    } on MissingPluginException {
      // `start` takes the first quoted argument as a window title, hence the empty one.
      await (Platform.isWindows
          ? Process.run('cmd', ['/c', 'start', '', url])
          : Process.run(Platform.isMacOS ? 'open' : 'xdg-open', [url]));
    }
  }

  /// Installs the APK at [path] as an update (Android asks to confirm). False when Android first needs
  /// "Install unknown apps" allowed: its settings page opens, and the install goes on once you're back.
  static Future<bool> installApk(String path) async =>
      await _app.invokeMethod<bool>('install', {'path': path}) ?? false;

  /// A persisted Android document tree URI, or null when the picker was cancelled.
  static Future<String?> pickDownloadFolder() =>
      _folder.invokeMethod<String>('pick');

  static Future<void> exportDownloadFolder(
    String tree,
    String id,
    String path,
  ) => _folder.invokeMethod('export', {'tree': tree, 'id': id, 'path': path});

  static Future<Uint8List?> readDownloadFile(
    String tree,
    String id,
    String file,
  ) => _folder.invokeMethod<Uint8List>('read', {
    'tree': tree,
    'id': id,
    'file': file,
  });

  static Future<void> deleteDownloadFolder(String tree, String id) =>
      _folder.invokeMethod('delete', {'tree': tree, 'id': id});

  /// Plays a stream in another video app until it returns: {position, duration, completed}, empty from apps that
  /// don't report back. Throws code "no_player" when none is installed.
  static Future<Map<String, Object?>?> playExternal({
    required String url,
    required Map<String, String>? headers,
    required String title,
    required Duration position,
    required List<Map<String, String>> subtitles,
  }) => _app.invokeMapMethod<String, Object?>('external', {
    'url': url,
    'headers': headers,
    'title': title,
    'position': position.inMilliseconds,
    'subtitles': subtitles,
  });

  /// Copies the downloaded episode in [dir] to the gallery as [name].
  static Future<void> saveToGallery(String dir, String name) =>
      _app.invokeMethod('gallery', {'dir': dir, 'name': name});

  /// The media volume, 0–1.
  static Future<double?> volume() => _volume.invokeMethod<double>('get');

  static Future<void> setVolume(double level) =>
      _volume.invokeMethod('set', level);
}

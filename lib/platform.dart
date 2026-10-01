import 'package:flutter/services.dart';

/// The Android side of the app: MainActivity.kt's 'aniview/app' and 'aniview/volume' channels. Off Android every
/// call throws [MissingPluginException]; failures on Android arrive as [PlatformException] with the reason.
class AndroidApp {
  static const _app = MethodChannel('aniview/app');
  static const _folder = MethodChannel('aniview/folder');
  static const _volume = MethodChannel('aniview/volume');

  static Future<String?> version() => _app.invokeMethod<String>('version');

  /// "Android 14; Pixel 7".
  static Future<String?> device() => _app.invokeMethod<String>('device');

  /// The primary ABI, to pick the matching release APK.
  static Future<String?> abi() => _app.invokeMethod<String>('abi');

  /// The phone's wallpaper accent (ARGB) on Android 12+; null before Material You or off Android.
  static Future<int?> accent() async {
    try {
      return await _app.invokeMethod<int>('accent');
    } catch (_) {
      return null;
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
  static Future<void> open(String url) => _app.invokeMethod('open', url);

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

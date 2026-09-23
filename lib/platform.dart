import 'package:flutter/services.dart';

/// The Android side of the app: MainActivity.kt's 'aniview/app' and 'aniview/volume' channels. Off Android every
/// call throws [MissingPluginException]; failures on Android arrive as [PlatformException] with the reason.
class AndroidApp {
  static const _app = MethodChannel('aniview/app');
  static const _volume = MethodChannel('aniview/volume');

  static Future<String?> version() => _app.invokeMethod<String>('version');

  /// "Android 14; Pixel 7".
  static Future<String?> device() => _app.invokeMethod<String>('device');

  /// The primary ABI, to pick the matching release APK.
  static Future<String?> abi() => _app.invokeMethod<String>('abi');

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

  /// Downloads an APK through the system download manager, whose notification opens the installer.
  static Future<void> downloadApk(String url, {required String title}) =>
      _app.invokeMethod('download', {'url': url, 'title': title});

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

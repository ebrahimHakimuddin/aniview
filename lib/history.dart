import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Where the user stopped in each show (newest first), kept on-device for the continue-watching buttons.
class WatchHistory {
  static const _key = 'watch_history';

  static Future<List<Map<String, dynamic>>> all() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    return raw == null ? [] : (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  }

  static Future<Map<String, dynamic>?> latest() async => (await all()).firstOrNull;

  static Future<Map<String, dynamic>?> of(Map media) async =>
      (await all()).where((r) => r['media']['id'] == media['id']).firstOrNull;

  static Future<void> save(
    Map media, {
    required String source,
    required num episode,
    required Duration position,
    required bool dub,
  }) async {
    final entries = [
      {'media': media, 'source': source, 'episode': episode, 'position': position.inMilliseconds, 'dub': dub},
      ...(await all()).where((r) => r['media']['id'] != media['id']),
    ];
    await _write(entries.take(20).toList());
  }

  static Future<void> remove(Map media) async =>
      _write((await all()).where((r) => r['media']['id'] != media['id']).toList());

  static Future<void> clear() => _write(const []);

  static Future<void> _write(List<Map> entries) async =>
      (await SharedPreferences.getInstance()).setString(_key, jsonEncode(entries));
}

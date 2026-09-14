import 'dart:convert';

import 'package:flutter/services.dart';

import 'anilist.dart';
import 'settings.dart';

/// "New episode" notifications. An Android background job (EpisodeJob.kt) checks AniList every hour, with the app
/// closed, for episodes that aired of the shows on your AniList watching list and the ones you watched recently.
/// The app only keeps the job's inputs current: the recently watched ids and the AniList sign-in.
class EpisodeNotifications {
  static const _channel = MethodChannel('aniview/notifications');

  /// [recent] are media maps from watch history; ones without an AniList id (MAL-only) are skipped.
  static Future<void> refresh(Iterable recent) async {
    try {
      final token = AniList.token;
      // The user id is cached after the first lookup; offline, the job keeps the one it has.
      final me = token == null
          ? null
          : await AniList.viewer().catchError((Object _) => null);
      await _channel.invokeMethod(
        'configure',
        jsonEncode({
          'enabled': Settings.episodeNotifications,
          'ids': {
            for (final m in recent)
              if (m['id'] is int) m['id'],
          }.toList(),
          'token': token,
          'user': me?['id'],
        }),
      );
    } catch (_) {} // not on Android
  }

  /// Calls [open] with the AniList id of a tapped notification's show: the one that launched the app, and any
  /// tapped while it runs.
  static Future<void> listen(void Function(int id) open) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'open') open(call.arguments as int);
    });
    try {
      final launched = await _channel.invokeMethod<int>('launchMedia');
      if (launched != null) open(launched);
    } catch (_) {} // not on Android
  }

  static bool _asked = false;

  /// Asks for Android 13's notification permission when it hasn't been granted, at most once per app launch
  /// unless [again] (the user just switched notifications on).
  static Future<void> requestPermission({bool again = false}) async {
    if (_asked && !again) return;
    _asked = true;
    await _channel.invokeMethod('permission').catchError((Object _) => null);
  }
}

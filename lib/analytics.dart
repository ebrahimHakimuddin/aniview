import 'dart:convert';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'settings.dart';

/// Screen views and feature use, sent to Rybbit. The Rybbit site is a "mobile" site, which accepts native traffic
/// with just its public site id, so no API key ships in the app. Events carry ids, numbers and fixed choices only,
/// never free text such as search queries. Off when the build has no RYBBIT_SITE_ID or the user opts out.
class Analytics {
  static const siteId = String.fromEnvironment('RYBBIT_SITE_ID');
  static const _host = String.fromEnvironment(
    'RYBBIT_HOST',
    defaultValue: 'https://app.rybbit.io',
  );
  static const _app = MethodChannel('aniview/app');

  static bool get available => siteId.isNotEmpty;

  static String _path = '/';
  static Future<String>? _userAgent;

  static void screen(String path, {String? title}) {
    _path = path;
    _send({'type': 'pageview', 'pathname': path, 'page_title': ?title});
  }

  static void event(
    String name, [
    Map<String, Object?> properties = const {},
  ]) => _send({
    'type': 'custom_event',
    'pathname': _path,
    'event_name': name,
    'properties': jsonEncode(properties),
  });

  static Future<void> _send(Map<String, Object?> event) async {
    if (!available || !Settings.analytics) return;
    try {
      final view = PlatformDispatcher.instance.implicitView;
      final size = view == null
          ? null
          : view.physicalSize / view.devicePixelRatio;
      await http
          .post(
            Uri.parse('$_host/api/track'),
            headers: {
              'Content-Type': 'application/json',
              // Rybbit reads the OS and device from the request's user agent.
              'User-Agent': await (_userAgent ??= _agent()),
            },
            body: jsonEncode({
              'site_id': siteId,
              'hostname': 'com.kidfury.aniview', // the app id the Rybbit site is set up with
              'anonymous_id': Settings.installId,
              'language': PlatformDispatcher.instance.locale.toLanguageTag(),
              if (size != null) ...{
                'screenWidth': size.width.round(),
                'screenHeight': size.height.round(),
              },
              ...event,
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {} // analytics must never get in the way of the app
  }

  static Future<String> _agent() async {
    try {
      final version = await _app.invokeMethod<String>('version');
      final device = await _app.invokeMethod<String>('device');
      return 'AniView/$version (Linux; $device)';
    } catch (_) {
      return 'AniView';
    }
  }
}

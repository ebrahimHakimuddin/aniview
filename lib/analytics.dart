import 'dart:convert';
import 'dart:ui';

import 'package:http/http.dart' as http;

import 'settings.dart';
import 'platform.dart';

/// Screen views and feature use, sent to Rybbit. The Rybbit site is a "mobile" site, which accepts native traffic
/// with just its public site id, so no API key ships in the app. Events carry ids, numbers and fixed choices only,
/// never free text such as search queries. Off when the build has no RYBBIT_SITE_ID or the user opts out.
class Analytics {
  static const siteId = String.fromEnvironment('RYBBIT_SITE_ID');
  static const _host = String.fromEnvironment(
    'RYBBIT_HOST',
    defaultValue: 'https://rybbit.clouderp.co.tz',
  );

  static bool get available => siteId.isNotEmpty;

  static String _path = '/';
  static String? _userAgent;

  static void screen(String path, {String? title}) {
    _path = path;
    _send({'type': 'pageview', 'pathname': path, 'page_title': ?title});
  }

  static Future<bool> event(
    String name, [
    Map<String, Object?> properties = const {},
  ]) => _send({
    'type': 'custom_event',
    'pathname': _path,
    'event_name': name,
    'properties': jsonEncode(properties),
  });

  static Future<bool> _send(Map<String, Object?> event) async {
    if (!available || !Settings.analytics) return false;
    try {
      final view = PlatformDispatcher.instance.implicitView;
      final size = view == null
          ? null
          : view.physicalSize / view.devicePixelRatio;
      final response = await http
          .post(
            Uri.parse('$_host/api/track'),
            headers: {
              'Content-Type': 'application/json',
              // Rybbit reads the OS and device from the request's user agent.
              'User-Agent': _userAgent ??= await _agent().timeout(
                const Duration(seconds: 2),
                onTimeout: () => 'AniView',
              ),
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
      if (response.statusCode < 200 || response.statusCode >= 300) return false;
      final body = jsonDecode(response.body);
      return body is Map<String, dynamic> && body['success'] == true;
    } catch (_) {
      return false; // analytics must never get in the way of the app
    }
  }

  static Future<String> _agent() async {
    try {
      final version = await AndroidApp.version();
      final device = await AndroidApp.device();
      return 'AniView/$version (Linux; $device)';
    } catch (_) {
      return 'AniView';
    }
  }
}

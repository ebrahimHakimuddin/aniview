import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Localhost relay for HLS streams: sends each stream's headers upstream and strips the fake image
/// prefix some hosts put in front of MPEG-TS segments (FFmpeg would otherwise probe them as PNG).
class HlsProxy {
  static final _client = http.Client();
  // ponytail: header sets are never evicted; one small map per opened stream is fine for a session
  static final _headers = <Map<String, String>>[];
  static final Future<HttpServer> _server =
      HttpServer.bind(InternetAddress.loopbackIPv4, 0).then((server) => server..listen(_handle));

  static Future<String> url(String upstream, Map<String, String> headers) async {
    final port = (await _server).port;
    _headers.add(headers);
    return _local(port, _headers.length - 1, upstream, 'm3u8');
  }

  // The upstream URL lives in the path (no query) so FFmpeg's segment-extension check sees `.ts`/`.m3u8`.
  static String _local(int port, int id, String upstream, String ext) =>
      'http://127.0.0.1:$port/$id/${base64Url.encode(utf8.encode(upstream)).replaceAll('=', '')}.$ext';

  static Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final [id, file] = request.uri.pathSegments;
      final encoded = file.substring(0, file.lastIndexOf('.'));
      final upstream = Uri.parse(utf8.decode(base64Url.decode(base64Url.normalize(encoded))));
      final res = await _client.get(upstream, headers: _headers[int.parse(id)]);
      response.statusCode = res.statusCode;
      if (file.endsWith('.m3u8')) {
        response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        response.write(rewritePlaylist(
          utf8.decode(res.bodyBytes, allowMalformed: true),
          upstream,
          (url, ext) => _local(request.requestedUri.port, int.parse(id), url, ext),
        ));
      } else {
        response.add(stripToTs(res.bodyBytes));
      }
    } catch (_) {
      response.statusCode = HttpStatus.badGateway;
    }
    await response.close();
  }
}

/// Points every URI in [playlist] back through [proxy]: entries of a master playlist stay `.m3u8`,
/// entries of a media playlist (segments, keys, init maps) become `.ts`.
String rewritePlaylist(String playlist, Uri base, String Function(String url, String ext) proxy) {
  final ext = playlist.contains('#EXT-X-STREAM-INF') || playlist.contains('#EXT-X-MEDIA:') ? 'm3u8' : 'ts';
  return playlist.split('\n').map((line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return line;
    if (trimmed.startsWith('#')) {
      return trimmed.replaceAllMapped(
        RegExp(r'URI="([^"]+)"'),
        (m) => 'URI="${proxy(base.resolve(m[1]!).toString(), ext)}"',
      );
    }
    return proxy(base.resolve(trimmed).toString(), ext);
  }).join('\n');
}

/// Drops any bytes before the first run of MPEG-TS sync bytes (0x47 every 188 bytes).
/// Anything that isn't TS (keys, fMP4, plain AAC) passes through untouched.
Uint8List stripToTs(Uint8List data) {
  if (data.isEmpty || data[0] == 0x47) return data;
  final limit = data.length - 188 * 3;
  for (var i = 0; i < limit && i < 65536; i++) {
    if (data[i] == 0x47 && data[i + 188] == 0x47 && data[i + 376] == 0x47 && data[i + 564] == 0x47) {
      return Uint8List.sublistView(data, i);
    }
  }
  return data;
}

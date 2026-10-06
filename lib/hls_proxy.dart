import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'downloads.dart' show bestVariant;
import 'sources.dart';
import 'platform.dart';

/// Localhost relay for HLS streams: sends each stream's headers upstream (over HTTP/2 where a host refuses
/// FFmpeg's HTTP/1.1, via [fetchBytes]) and strips the fake image prefix some hosts put in front of MPEG-TS
/// segments (FFmpeg would otherwise probe them as PNG).
class HlsProxy {
  // ponytail: header sets are never evicted; one small map per opened stream is fine for a session
  static final _headers = <Map<String, String>>[];
  static final _keys = <Uint8List?>[];
  static final _dirs = <String>[];
  static final _documents = <(String, String)>[];

  /// Leads every path, so other apps on the device can't use the relay or read downloads without an address it gave out.
  static final _token = base64Url
      .encode([for (var i = 0; i < 16; i++) Random.secure().nextInt(256)])
      .replaceAll('=', '');
  static final Future<HttpServer> _server = HttpServer.bind(
    InternetAddress.loopbackIPv4,
    0,
  ).then((server) => server..listen(_handle));

  /// Local URL for [upstream]; [ext] is `m3u8` for a stream, or the file's own extension (e.g. a `.vtt`
  /// subtitle, whose host also rejects requests without the stream's Referer).
  static Future<String> url(
    String upstream,
    Map<String, String> headers, {
    String ext = 'm3u8',
    Uint8List? key,
  }) async {
    final port = (await _server).port;
    _headers.add(headers);
    _keys.add(key);
    return _local(port, _headers.length - 1, upstream, ext);
  }

  /// Serves [file] from download folder [dir] to other apps (an external player), which can't read app storage.
  /// Only registered folders are served, so other apps can't reach the rest of the app's files.
  static Future<String> localFile(String dir, String file) async {
    final port = (await _server).port;
    var id = _dirs.indexOf(dir);
    if (id == -1) {
      _dirs.add(dir);
      id = _dirs.length - 1;
    }
    return 'http://127.0.0.1:$port/$_token/local/$id/$file';
  }

  /// Serves a file in an Android folder chosen through the system picker.
  static Future<String> documentFile(
    String tree,
    String id,
    String file,
  ) async {
    final port = (await _server).port;
    var index = _documents.indexOf((tree, id));
    if (index == -1) {
      _documents.add((tree, id));
      index = _documents.length - 1;
    }
    return 'http://127.0.0.1:$port/$_token/document/$index/$file';
  }

  // The upstream URL lives in the path (no query) so FFmpeg's segment-extension check sees `.ts`/`.m3u8`.
  static String _local(int port, int id, String upstream, String ext) =>
      'http://127.0.0.1:$port/$_token/$id/${base64Url.encode(utf8.encode(upstream)).replaceAll('=', '')}.$ext';

  static Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final [token, ...path] = request.uri.pathSegments;
      if (token != _token) {
        response.statusCode = HttpStatus.forbidden;
        return await response.close();
      }
      if (path case [
        ('local' || 'document') && final kind,
        final id,
        final file,
      ]) {
        // Playlist entries are relative, so segments and keys resolve to this same folder.
        if (!RegExp(r'^\w[\w.-]*$').hasMatch(file)) {
          throw const FormatException();
        }
        if (file.endsWith('.m3u8')) {
          response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
        }
        if (kind == 'local') {
          final local = File('${_dirs[int.parse(id)]}/$file');
          if (!await local.exists()) throw const FileSystemException();
          await response.addStream(local.openRead());
        } else {
          final (tree, folder) = _documents[int.parse(id)];
          final bytes = await AndroidApp.readDownloadFile(tree, folder, file);
          if (bytes == null) throw const FileSystemException();
          response.add(bytes);
        }
        return await response.close();
      }
      if (path case ['key', final id]) {
        response.add(_keys[int.parse(id)]!);
        return await response.close();
      }
      final [id, file] = path;
      final encoded = file.substring(0, file.lastIndexOf('.'));
      final upstream = Uri.parse(
        utf8.decode(base64Url.decode(base64Url.normalize(encoded))),
      );
      final headers = _headers[int.parse(id)];
      if (file.endsWith('.m3u8')) {
        final body = await fetchBytes('$upstream', headers: headers);
        response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        response.write(
          rewritePlaylist(
            // FFmpeg (desktop) opens every variant and rendition before playing, and mpv has no quality pick.
            switch (utf8.decode(body, allowMalformed: true)) {
              final text when isDesktop => oneVariant(text),
              final text => text,
            },
            upstream,
            (url, ext) =>
                _local(request.requestedUri.port, int.parse(id), url, ext),
            key: _keys[int.parse(id)] == null
                ? null
                : 'http://127.0.0.1:${request.requestedUri.port}/$_token/key/$id',
          ),
        );
      } else {
        // Passed on as it arrives: players give up on a large segment that takes seconds to start.
        final body = await streamBytes('$upstream', headers: headers);
        await response.addStream(
          file.endsWith('.ts') ? stripStart(body) : body,
        );
      }
    } catch (_) {
      try {
        response.statusCode = HttpStatus.badGateway;
      } on StateError {
        // A body that broke off midway has already sent its status; closing it short is all that's left.
      }
    }
    await response.close();
  }
}

/// [master] cut to its best variant and that variant's default audio rendition; subtitles stay. A media playlist
/// comes back as it is.
String oneVariant(String master) {
  if (!master.contains('#EXT-X-STREAM-INF')) return master;
  final lines = master.split('\n').map((l) => l.trim()).toList();
  final uri = lines.indexOf(bestVariant(master));
  final inf = lines.lastIndexWhere(
    (l) => l.startsWith('#EXT-X-STREAM-INF'),
    uri,
  );
  final group = RegExp(r'AUDIO="([^"]+)"').firstMatch(lines[inf])?[1];
  bool isAudio(String l) =>
      l.startsWith('#EXT-X-MEDIA:') && l.contains('TYPE=AUDIO');
  final audio = lines.where(
    (l) => isAudio(l) && l.contains('GROUP-ID="$group"'),
  );
  final pick =
      audio.where((l) => l.contains('DEFAULT=YES')).firstOrNull ??
      audio.firstOrNull;
  return [
    for (final (i, l) in lines.indexed)
      if (i == inf ||
          i == uri ||
          l.isEmpty ||
          (l.startsWith('#') &&
              !l.startsWith('#EXT-X-STREAM-INF') &&
              !l.startsWith('#EXT-X-I-FRAME-STREAM-INF') &&
              (!isAudio(l) || l == pick)))
        l,
  ].join('\n');
}

/// Points every URI in [playlist] back through [proxy]: entries of a master playlist stay `.m3u8`,
/// entries of a media playlist (segments, keys, init maps) become `.ts`. [key], when given, is where every
/// #EXT-X-KEY points instead.
String rewritePlaylist(
  String playlist,
  Uri base,
  String Function(String url, String ext) proxy, {
  String? key,
}) {
  final ext =
      playlist.contains('#EXT-X-STREAM-INF') ||
          playlist.contains('#EXT-X-MEDIA:')
      ? 'm3u8'
      : 'ts';
  return playlist
      .split('\n')
      .map((line) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) return line;
        if (key != null && trimmed.startsWith('#EXT-X-KEY')) {
          return trimmed.replaceFirst(RegExp(r'URI="[^"]+"'), 'URI="$key"');
        }
        if (trimmed.startsWith('#')) {
          return trimmed.replaceAllMapped(
            RegExp(r'URI="([^"]+)"'),
            (m) => 'URI="${proxy(base.resolve(m[1]!).toString(), ext)}"',
          );
        }
        return proxy(base.resolve(trimmed).toString(), ext);
      })
      .join('\n');
}

/// [body] with [stripToTs] applied to the start, the only part it looks at.
Stream<List<int>> stripStart(Stream<List<int>> body) async* {
  const looked = 65536 + 188 * 3;
  final head = BytesBuilder(copy: false);
  var passing = false;
  await for (final chunk in body) {
    if (passing) {
      yield chunk;
      continue;
    }
    head.add(chunk);
    if (head.length >= looked) {
      passing = true;
      yield stripToTs(head.takeBytes());
    }
  }
  if (!passing) yield stripToTs(head.takeBytes());
}

/// Drops any bytes before the first run of MPEG-TS sync bytes (0x47 every 188 bytes).
/// Anything that isn't TS (keys, fMP4, plain AAC) passes through untouched.
Uint8List stripToTs(Uint8List data) {
  if (data.isEmpty || data[0] == 0x47) return data;
  final limit = data.length - 188 * 3;
  for (var i = 0; i < limit && i < 65536; i++) {
    if (data[i] == 0x47 &&
        data[i + 188] == 0x47 &&
        data[i + 376] == 0x47 &&
        data[i + 564] == 0x47) {
      return Uint8List.sublistView(data, i);
    }
  }
  return data;
}

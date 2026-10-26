import 'dart:io';
import 'dart:typed_data';

import 'hls_proxy.dart';
import 'platform.dart';
import 'sources.dart';
import 'subtitles.dart';

/// A file's own extension, for the relay address ("bin" when the address has none: `…/audio?id=3`).
String _extOf(String url) {
  final last = Uri.parse(url).pathSegments.lastOrNull ?? '';
  final ext = last.contains('.') ? last.split('.').last.toLowerCase() : '';
  return RegExp(r'^[a-z0-9]{1,5}$').hasMatch(ext) ? ext : 'bin';
}

/// Where a download's files live: a folder in app storage, or a folder in an Android document tree picked in the
/// system file picker. Owns the address format a [VideoStream] and its subtitles carry: a plain path, or
/// `saf://<tree>/<id>/<file>`.
sealed class DownloadLocation {
  const DownloadLocation();

  /// The address of [file] in this folder.
  String urlOf(String file);

  /// The folder and file name an address points into; null for a remote one.
  static (DownloadLocation, String)? parse(String url) {
    if (url.startsWith('saf://')) {
      final [tree, id, file, ...] = url.substring('saf://'.length).split('/');
      return (
        DocumentFolder(Uri.decodeComponent(tree), Uri.decodeComponent(id)),
        file,
      );
    }
    if (url.startsWith('http')) return null;
    return (LocalFolder(File(url).parent.path), url.split('/').last);
  }
}

class LocalFolder extends DownloadLocation {
  const LocalFolder(this.path);
  final String path;

  @override
  String urlOf(String file) => '$path/$file';
}

/// Folder [id] inside the document tree [tree].
class DocumentFolder extends DownloadLocation {
  const DocumentFolder(this.tree, this.id);
  final String tree, id;

  @override
  String urlOf(String file) =>
      'saf://${Uri.encodeComponent(tree)}/${Uri.encodeComponent(id)}/$file';
}

/// What a player is given to open a stream.
class PlayableAddress {
  const PlayableAddress(
    this.url, {
    this.headers,
    this.hls = false,
    this.subtitles = const [],
    this.audios = const [],
  });

  final String url;

  /// Sent with the request; null when the address needs none (HLS goes through the relay, which sends them).
  final Map<String, String>? headers;
  final bool hls;
  final List<({String url, String label})> subtitles, audios;
}

/// The localhost relay [StreamAddress] routes through ([HlsProxy] in the app).
abstract interface class Relay {
  /// A remote file, fetched with [headers]; [ext] is its own extension. A playlist's segments open with [key] when
  /// given, instead of the one it names.
  Future<String> remote(
    String url,
    Map<String, String> headers,
    String ext, {
    Uint8List? key,
    String? audioLanguage,
  });

  /// [file] in the app-storage folder [dir].
  Future<String> localFile(String dir, String file);

  Future<String> documentFile(String tree, String id, String file);

  /// A whole video (an MP4) in a picked folder, opened by players straight from the system.
  Future<String> documentVideo(String tree, String id, String file);

  /// The format of the subtitle at [url], whose address doesn't say (see [subtitleExts]).
  Future<String> subtitleFormat(String url, Map<String, String> headers);
}

class _HlsRelay implements Relay {
  const _HlsRelay();

  @override
  Future<String> remote(
    String url,
    Map<String, String> headers,
    String ext, {
    Uint8List? key,
    String? audioLanguage,
  }) => HlsProxy.url(
    url,
    headers,
    ext: ext,
    key: key,
    audioLanguage: audioLanguage,
  );

  @override
  Future<String> localFile(String dir, String file) =>
      HlsProxy.localFile(dir, file);

  @override
  Future<String> documentFile(String tree, String id, String file) =>
      HlsProxy.documentFile(tree, id, file);

  @override
  Future<String> subtitleFormat(String url, Map<String, String> headers) async {
    try {
      return sniffSubtitle(await fetchBytes(url, headers: headers));
    } catch (_) {
      return 'vtt'; // the player says so if it can't load it either
    }
  }

  @override
  Future<String> documentVideo(String tree, String id, String file) async =>
      await AndroidApp.downloadFileUri(tree, id, file) ??
      (throw const FileSystemException('Downloaded file is missing'));
}

/// Turns a [VideoStream] into the address a player opens: a document in a picked folder, a local file, an HLS
/// stream, or a direct file (mp4) fetched with its headers. Only HLS and subtitles need the relay (to send the
/// stream's headers, and to strip the fake image prefix some hosts put on segments); our own player reads local
/// files itself, while another app can't read app storage.
class StreamAddress {
  const StreamAddress([this.relay = const _HlsRelay()]);
  static const instance = StreamAddress();

  final Relay relay;

  Future<PlayableAddress> forPlayer(VideoStream stream) =>
      _address(stream, external: false);

  /// For another video app, which can't read app storage either. (MX Player takes the headers of a direct file.)
  Future<PlayableAddress> forExternalApp(VideoStream stream) =>
      _address(stream, external: true);

  Future<PlayableAddress> _address(
    VideoStream stream, {
    required bool external,
  }) async => PlayableAddress(
    stream.isHls || stream.isLocal
        ? await _route(
            stream,
            stream.url,
            external,
            ext: stream.isHls ? 'm3u8' : null,
          )
        : stream.url,
    headers: stream.isHls || stream.isLocal ? null : stream.headers,
    hls: stream.isHls,
    // Loaded with the video, so switching to one later needs no reload.
    subtitles: await Future.wait([
      for (final s in stream.subtitles)
        _route(
          stream,
          s.url,
          external,
          ext:
              subtitleExtOf(s.url) ??
              // An extension's subtitle often comes from an address with no extension; players need the format.
              (s.url.startsWith('http')
                  ? await relay.subtitleFormat(s.url, stream.headers)
                  : null),
        ).then((url) => (url: url, label: s.label)),
    ]),
    audios: [
      for (final a in stream.audios)
        (url: await _route(stream, a.url, external), label: a.label),
    ],
  );

  Future<String> _route(
    VideoStream stream,
    String url,
    bool external, {
    String? ext,
  }) => switch (DownloadLocation.parse(url)) {
    (DocumentFolder(:final tree, :final id), final file)
        when file.endsWith('.mp4') =>
      relay.documentVideo(tree, id, file),
    (DocumentFolder(:final tree, :final id), final file) => relay.documentFile(
      tree,
      id,
      file,
    ),
    (LocalFolder(:final path), final file) =>
      external ? relay.localFile(path, file) : Future.value(url),
    _ => relay.remote(
      url,
      stream.headers,
      ext ?? _extOf(url),
      key: url == stream.url ? stream.key : null,
      audioLanguage: url == stream.url ? stream.audioLanguage : null,
    ),
  };
}

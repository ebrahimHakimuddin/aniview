import 'dart:io';
import 'dart:typed_data';

import 'hls_proxy.dart';
import 'sources.dart';
import 'platform.dart';

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
      return (DocumentFolder(Uri.decodeComponent(tree), id), file);
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
  String urlOf(String file) => 'saf://${Uri.encodeComponent(tree)}/$id/$file';
}

/// What a player is given to open a stream.
class PlayableAddress {
  const PlayableAddress(
    this.url, {
    this.headers,
    this.hls = false,
    this.subtitles = const [],
  });

  final String url;

  /// Sent with the request; null when the address needs none (HLS goes through the relay, which sends them).
  final Map<String, String>? headers;
  final bool hls;
  final List<({String url, String label})> subtitles;
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
  });

  /// [file] in the app-storage folder [dir].
  Future<String> localFile(String dir, String file);

  Future<String> documentFile(String tree, String id, String file);
}

class _HlsRelay implements Relay {
  const _HlsRelay();

  @override
  Future<String> remote(
    String url,
    Map<String, String> headers,
    String ext, {
    Uint8List? key,
  }) => HlsProxy.url(url, headers, ext: ext, key: key);

  @override
  Future<String> localFile(String dir, String file) =>
      HlsProxy.localFile(dir, file);

  @override
  Future<String> documentFile(String tree, String id, String file) =>
      file.endsWith('.mp4')
      ? AndroidApp.downloadFileUri(tree, id, file).then(
          (uri) =>
              uri ??
              (throw const FileSystemException('Downloaded video is missing')),
        )
      : HlsProxy.documentFile(tree, id, file);
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
        ? await _route(stream, stream.url, external)
        : stream.url,
    headers: stream.isHls ? null : stream.headers,
    hls: stream.isHls,
    // Loaded with the video, so switching to one later needs no reload.
    subtitles: [
      for (final s in stream.subtitles)
        (url: await _route(stream, s.url, external), label: s.label),
    ],
  );

  Future<String> _route(VideoStream stream, String url, bool external) =>
      switch (DownloadLocation.parse(url)) {
        (DocumentFolder(:final tree, :final id), final file) =>
          relay.documentFile(tree, id, file),
        (LocalFolder(:final path), final file) =>
          external ? relay.localFile(path, file) : Future.value(url),
        _ => relay.remote(
          url,
          stream.headers,
          Uri.parse(url).path.split('.').last,
          key: url == stream.url ? stream.key : null,
        ),
      };
}

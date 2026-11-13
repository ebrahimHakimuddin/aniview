import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

import 'net.dart';

/// Where posters are kept between launches; null (tests, a platform without a cache directory) loads them from the
/// network each time, as [NetworkImage] does.
Directory? posterCache;

/// About how much the poster cache may hold before the oldest-used files go.
@visibleForTesting
int posterCacheLimit = 200 * 1024 * 1024;

/// Opens the poster cache at startup, then trims it in the background once.
Future<void> openPosterCache() async {
  try {
    final dir = Directory(
      '${(await getApplicationCacheDirectory()).path}/posters',
    );
    await dir.create(recursive: true);
    posterCache = dir;
    trimPosters(dir).ignore();
  } catch (_) {
    // No cache directory: posters come from the network.
  }
}

/// Deletes the least recently used posters until [dir] holds no more than [posterCacheLimit]. Last use is a file's
/// modification time, which a read moves forward at most once a day.
Future<void> trimPosters(Directory dir) async {
  final files = <(File, FileStat)>[];
  var total = 0;
  await for (final entity in dir.list()) {
    if (entity is! File) continue;
    final stat = await entity.stat();
    files.add((entity, stat));
    total += stat.size;
  }
  if (total <= posterCacheLimit) return;
  files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
  for (final (file, stat) in files) {
    if (total <= posterCacheLimit) break;
    try {
      await file.delete();
      total -= stat.size;
    } on FileSystemException {
      // Already gone, or in use: leave it.
    }
  }
}

/// A poster from [cache], downloaded through [fetchBytes] and kept there when it is not yet.
@immutable
class CachedPoster extends ImageProvider<CachedPoster> {
  const CachedPoster(this.url, this.cache);

  final String url;
  final Directory cache;

  /// Downloads in progress, so two posters showing one URL fetch it once.
  static final _pending = <String, Future<Uint8List>>{};

  @override
  Future<CachedPoster> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    CachedPoster key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: key.load(decode),
    scale: 1,
    debugLabel: url,
    informationCollector: () => [DiagnosticsProperty('URL', url)],
  );

  /// The file this URL is kept in: a hash of it, so any URL makes a safe name.
  File get file => File('${cache.path}/${_hash(url)}');

  /// The cached copy when it decodes, otherwise a fresh download. A file that will not decode is deleted.
  @visibleForTesting
  Future<ui.Codec> load(ImageDecoderCallback decode) async {
    final file = this.file;
    try {
      final bytes = await file.readAsBytes();
      final codec = await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
      _touch(file);
      return codec;
    } on PathNotFoundException {
      // Not cached yet.
    } catch (_) {
      await file.delete().then((_) {}, onError: (_) {});
    }
    // A block, not an arrow: whenComplete would wait on the removed future, which is this one.
    final bytes = await (_pending[url] ??= _download().whenComplete(() {
      _pending.remove(url);
    }));
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  /// [url]'s bytes, written beside [file] and renamed into place so a reader never sees half a poster. A failed write
  /// still returns them.
  Future<Uint8List> _download() async {
    final bytes = await fetchBytes(url);
    final temp = File('${file.path}.tmp');
    try {
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(file.path);
    } catch (_) {
      await temp.delete().then((_) {}, onError: (_) {});
    }
    return bytes;
  }

  /// Marks [file] used now, for [trimPosters], unless it already was today.
  static void _touch(File file) {
    final now = DateTime.now();
    file.lastModified().then((at) {
      if (now.difference(at) > const Duration(days: 1)) {
        return file.setLastModified(now);
      }
    }).ignore();
  }

  @override
  bool operator ==(Object other) =>
      other is CachedPoster &&
      other.url == url &&
      other.cache.path == cache.path;

  @override
  int get hashCode => Object.hash(url, cache.path);

  @override
  String toString() => 'CachedPoster("$url")';
}

/// 64-bit FNV-1a of [s], in hex.
String _hash(String s) {
  var h = 0xcbf29ce484222325;
  for (final b in utf8.encode(s)) {
    h = (h ^ b) * 0x100000001b3;
  }
  String half(int x) => x.toRadixString(16).padLeft(8, '0');
  return half(h >>> 32) + half(h & 0xffffffff);
}

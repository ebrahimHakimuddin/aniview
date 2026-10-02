import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aniview/sources.dart';

/// An extension host that answers what the test sets, and records installs.
class FakeHost implements ExtensionHost {
  List<HostSource> sourceList = [];
  Object? sourceError;
  bool sourcesStall = false;
  List<Episode> episodeList = [];
  List<VideoStream> videoList = [];
  final installed = <String>[], removed = <String>[];

  @override
  Future<List<HostSource>> sources() async {
    if (sourcesStall) await Completer<void>().future;
    if (sourceError case final error?) throw error;
    return sourceList;
  }

  @override
  Future<List<SearchResult>> search(String id, String query) async => [];

  @override
  Future<List<Episode>> episodes(String id, String url) async => episodeList;

  @override
  Future<List<VideoStream>> videos(String id, Episode episode) async =>
      videoList;

  @override
  Future<void> install(String path, String fingerprint) async =>
      installed.add('${path.split('/').last}:$fingerprint');

  @override
  Future<void> uninstall(String pkg) async => removed.add(pkg);
}

/// A network that serves the page whose key a URL contains (first listed wins), or answers 404 as an HttpException.
class FakeNet implements Net {
  FakeNet(this.pages);

  final Map<String, String> pages;
  final requests = <String>[];

  @override
  Future<String> text(String url, {Map<String, String>? headers}) async {
    requests.add(url);
    for (final MapEntry(:key, :value) in pages.entries) {
      if (url.contains(key)) return value;
    }
    throw HttpException('HTTP 404', uri: Uri.parse(url));
  }

  @override
  Future<Uint8List> bytes(String url, {Map<String, String>? headers}) async =>
      Uint8List.fromList((await text(url, headers: headers)).codeUnits);
}

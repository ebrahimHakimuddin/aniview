// Fake data for integration_test/perf_test.dart: a catalog, a site, posters drawn on the device, a loopback server
// for downloads, and a network guard so nothing the scenarios do reaches the internet.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aniview/anilist.dart';
import 'package:aniview/image_cache.dart';
import 'package:aniview/net.dart' as net;
import 'package:aniview/sources.dart';
import 'package:aniview/tracker.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;

/// Host the fake posters claim to live on; never resolved (see [LocalOnlyClient]).
const imageHost = 'perf-images.invalid';

/// Shows in the fake catalog. Every row and grid is a slice of these.
const showCount = 72;

/// The fake site's name, as downloads record it.
const siteName = 'PerfSite';

String coverUrl(int i) => 'https://$imageHost/cover/$i.png';
String bannerUrl(int i) => 'https://$imageHost/banner/$i.png';

/// An AniList-shaped show, with every field the cards and pages read.
Map<String, dynamic> fakeShow(int i, {int episodes = 24}) => {
  'id': 900000 + i,
  'idMal': 800000 + i,
  'title': {
    'userPreferred': 'Perf Show ${i + 1}',
    'romaji': 'Perf Show ${i + 1}',
    'english': 'Performance Show Number ${i + 1}',
  },
  'coverImage': {
    'extraLarge': coverUrl(i),
    'large': coverUrl(i),
    'color': _hex(_hue(i)),
  },
  'bannerImage': i < 8 ? bannerUrl(i) : null,
  'description':
      'A deterministic synopsis for show ${i + 1}. <br><br>It has <i>some</i> markup, like the real ones do, and '
          'runs long enough to wrap over several lines on a hover card or the banner. ' *
      2,
  'averageScore': 60 + i % 35,
  'popularity': 100000 - i * 997,
  'episodes': episodes,
  'duration': 24,
  'genres': const [
    'Action',
    'Fantasy',
    'Comedy',
    'Drama',
  ].sublist(0, 1 + i % 4),
  'format': i % 7 == 0 ? 'MOVIE' : 'TV',
  'status': i % 3 == 0 ? 'RELEASING' : 'FINISHED',
  'season': 'FALL',
  'seasonYear': 2024 - i % 5,
  'startDate': {'year': 2024 - i % 5, 'month': 1 + i % 12, 'day': 1},
  'isAdult': false,
  'nextAiringEpisode': null,
  'mediaListEntry': null,
};

/// The same 72 shows, in a fixed order per [salt], so rows differ but every run gets the same ones.
List<Map<String, dynamic>> showSlice(int salt, int count) => [
  for (var k = 0; k < count; k++) fakeShow((k * 7 + salt * 11) % showCount),
];

/// Browsing answered from [showSlice]; search pages run out after [searchPages].
class FakeCatalog implements Catalog {
  FakeCatalog({this.searchPages = 6, this.pageSize = 50});

  final int searchPages, pageSize;

  @override
  bool get usable => true;
  @override
  Future<List> trending() async => showSlice(0, 30);
  @override
  Future<List> season() async => showSlice(1, 30);
  @override
  Future<(List, bool)> search(
    String text,
    SearchFilters filters,
    int page,
  ) async {
    final salt = (filters.sort ?? '').length + filters.genres.length * 3;
    return (
      [
        for (var k = 0; k < pageSize; k++)
          fakeShow(((page - 1) * pageSize + k + salt) % showCount),
      ],
      page < searchPages,
    );
  }

  @override
  Future<List<(String, Map)>> relations(Map media) async => [];
}

/// One site that matches every show, lists [episodeCount] episodes, and serves each from [server] when there is one.
class FakeSite extends Source {
  FakeSite({this.episodeCount = 24})
    : super(siteName, 'https://perf-site.invalid');

  int episodeCount;

  /// Where downloads fetch from; null answers no servers.
  Uri? server;

  @override
  Future<List<SearchResult>> search(String query) async => [];
  @override
  Future<String?> match(Map media) async => 'show-${media['id']}';
  @override
  Future<List<Episode>> episodesOf(String id) async => [
    for (var i = 1; i <= episodeCount; i++) Episode(i, ref: '$id/$i'),
  ];
  @override
  Future<List<VideoStream>> streams(
    Map media,
    Episode episode, {
    required bool dub,
  }) async => [
    if (server case final s?)
      VideoStream(
        siteName,
        s.resolve('/episode/${media['id']}/${episode.number}.mp4').toString(),
        const {},
      ),
  ];
}

/// No extensions installed.
class NoExtensions implements ExtensionHost {
  @override
  Future<List<HostSource>> sources() async => [];
  @override
  Future<List<SearchResult>> search(String id, String query) async => [];
  @override
  Future<List<Episode>> episodes(String id, String url) async => [];
  @override
  Future<List<VideoStream>> videos(String id, Episode episode) async => [];
  @override
  Future<void> install(String path, String fingerprint) async {}
  @override
  Future<void> uninstall(String pkg) async {}
}

bool _local(String host) =>
    host == '127.0.0.1' || host == 'localhost' || host == '::1';

/// Every request the app makes through package:http: loopback goes through, anything else is answered 404 at once,
/// so no scenario waits on, or is shaped by, the internet.
class LocalOnlyClient extends http.BaseClient {
  final _inner = http.Client();
  final blocked = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (_local(request.url.host)) return _inner.send(request);
    blocked.add(request.url.toString());
    return Future.value(
      http.StreamedResponse(const Stream.empty(), 404, request: request),
    );
  }
}

/// The same for dart:io's HttpClient (NetworkImage, package:http's top-level calls).
class LocalOnlyOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..connectionFactory = (uri, proxyHost, proxyPort) => _local(uri.host)
            ? Socket.startConnect(uri.host, uri.port)
            : Future.error(
                SocketException('Blocked by the perf harness: $uri'),
              );
}

/// Installs the guard; returns the client to read what was blocked from.
LocalOnlyClient guardNetwork() {
  HttpOverrides.global = LocalOnlyOverrides();
  final client = LocalOnlyClient();
  net.httpClient = client;
  return client;
}

int _hue(int i) => (i * 47) % 360;

String _hex(int hue) {
  final c = HSVColor.fromAHSV(1, hue.toDouble(), .55, .7).toColor();
  String two(double v) => (v * 255).round().toRadixString(16).padLeft(2, '0');
  return '#${two(c.r)}${two(c.g)}${two(c.b)}';
}

/// A poster-like PNG: gradient, a few shapes and some text, so decode and raster costs resemble real artwork.
Future<Uint8List> _drawPng(int seed, int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final rect = Offset.zero & Size(width.toDouble(), height.toDouble());
  final hue = _hue(seed).toDouble();
  canvas.drawRect(
    rect,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          HSVColor.fromAHSV(1, hue, .7, .9).toColor(),
          HSVColor.fromAHSV(1, (hue + 120) % 360, .8, .35).toColor(),
        ],
      ).createShader(rect),
  );
  final random = Random(seed);
  for (var k = 0; k < 14; k++) {
    canvas.drawCircle(
      Offset(random.nextDouble() * width, random.nextDouble() * height),
      20 + random.nextDouble() * width / 4,
      Paint()
        ..color = HSVColor.fromAHSV(
          .35,
          (hue + random.nextInt(180)) % 360,
          .6,
          1,
        ).toColor(),
    );
  }
  final text = TextPainter(
    text: TextSpan(
      text: 'PERF\n#$seed',
      style: TextStyle(
        fontSize: width / 6,
        fontWeight: FontWeight.w900,
        color: const Color(0xEEFFFFFF),
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: width.toDouble());
  text.paint(canvas, Offset(width * .08, height * .6));
  final image = await recorder.endRecording().toImage(width, height);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return png!.buffer.asUint8List();
}

/// Points the app's poster cache at [dir] and fills it with a drawn cover for every show and a banner for the first
/// eight, so every poster loads from local disk through the app's own [CachedPoster] path.
Future<void> seedPosters(Directory dir) async {
  await dir.create(recursive: true);
  Future<void> put(String url, int seed, int w, int h) async {
    final file = CachedPoster(url, dir).file;
    if (await file.exists()) return;
    await file.writeAsBytes(await _drawPng(seed, w, h), flush: true);
  }

  for (var i = 0; i < showCount; i++) {
    await put(coverUrl(i), i, 460, 650);
  }
  for (var i = 0; i < 8; i++) {
    await put(bannerUrl(i), 100 + i, 1900, 400);
  }
  posterCache = dir;
}

/// Serves `/episode/<id>/<n>.mp4` as [size] bytes of zeros, [chunk] bytes every [every]: a download that takes a
/// few seconds, like a real one over a fast line, with progress arriving far more often than frames.
class SlowFileServer {
  SlowFileServer._(this._server);

  final HttpServer _server;
  int size = 16 * 1024 * 1024;
  int chunk = 32 * 1024;
  Duration every = const Duration(milliseconds: 4);
  int served = 0;

  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}/');

  static Future<SlowFileServer> start() async {
    final server = SlowFileServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    server._server.listen(server._serve);
    return server;
  }

  Future<void> _serve(HttpRequest request) async {
    final res = request.response;
    try {
      if (!request.uri.path.startsWith('/episode/')) {
        res.statusCode = 404;
        return;
      }
      served++;
      res
        ..statusCode = 200
        ..contentLength = size
        ..headers.contentType = ContentType('video', 'mp4');
      final block = Uint8List(chunk);
      // An MP4's first box, so the app's check that a video arrived passes.
      final first = Uint8List(chunk)
        ..setAll(0, [0, 0, 0, 0x20, ...'ftypisom'.codeUnits]);
      for (var sent = 0; sent < size; sent += chunk) {
        res.add(
          sent == 0
              ? first
              : sent + chunk <= size
              ? block
              : Uint8List(size - sent),
        );
        await res.flush();
        await Future<void>.delayed(every);
      }
    } catch (_) {
      // The app cancelled or the test ended.
    } finally {
      await res.close().catchError((Object _) {});
    }
  }

  Future<void> close() => _server.close(force: true);
}

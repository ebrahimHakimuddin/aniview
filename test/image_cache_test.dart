import 'dart:convert';
import 'dart:io';

import 'package:aniview/image_cache.dart';
import 'package:aniview/net.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A 1×1 PNG.
final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

const url = 'https://img.example/poster.png';

void main() {
  final original = httpClient, limit = posterCacheLimit;
  late Directory dir;
  var requests = 0;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('posters');
    requests = 0;
    httpClient = MockClient((_) async {
      requests++;
      return http.Response.bytes(png, 200);
    });
  });
  tearDown(() {
    httpClient = original;
    posterCacheLimit = limit;
    dir.deleteSync(recursive: true);
  });

  // Images decode for real, off the widget test's clock.
  Future<void> real(WidgetTester tester, Future<void> Function() body) =>
      tester.runAsync(body);

  Future<void> load() async {
    final codec = await CachedPoster(
      url,
      dir,
    ).load(PaintingBinding.instance.instantiateImageCodecWithSize);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 1);
    frame.image.dispose();
    codec.dispose();
  }

  testWidgets(
    'a second load of one URL makes no request',
    (tester) => real(tester, () async {
      await load();
      await load();
      expect(requests, 1);
      final file = CachedPoster(url, dir).file;
      expect(file.readAsBytesSync(), png);
      expect(file.uri.pathSegments.last, matches(RegExp(r'^[0-9a-f]{16}$')));
    }),
  );

  testWidgets(
    'two loads at once share one download',
    (tester) => real(tester, () async {
      await Future.wait([load(), load()]);
      expect(requests, 1);
    }),
  );

  testWidgets(
    'a corrupt cached file is fetched again and replaced',
    (tester) => real(tester, () async {
      final file = CachedPoster(url, dir).file..writeAsStringSync('not a png');
      await load();
      expect(requests, 1);
      expect(file.readAsBytesSync(), png);
    }),
  );

  testWidgets(
    'with the network failing, a cached URL still loads',
    (tester) => real(tester, () async {
      await load();
      httpClient = MockClient((_) async {
        requests++;
        return http.Response('', 500);
      });
      await load();
      expect(requests, 1);
    }),
  );

  testWidgets(
    'a failed write still shows the downloaded image',
    (tester) => real(tester, () async {
      final missing = Directory('${dir.path}/gone');
      final codec = await CachedPoster(
        url,
        missing,
      ).load(PaintingBinding.instance.instantiateImageCodecWithSize);
      expect(codec.frameCount, 1);
      codec.dispose();
      expect(missing.existsSync(), isFalse);
    }),
  );

  test('trimming removes the least recently used files past the cap', () async {
    final now = DateTime.now();
    for (var i = 0; i < 4; i++) {
      File('${dir.path}/$i')
        ..writeAsBytesSync(List.filled(100, 0))
        ..setLastModifiedSync(now.subtract(Duration(days: i)));
    }
    posterCacheLimit = 250;
    await trimPosters(dir);
    final left = dir.listSync().map((f) => f.uri.pathSegments.last).toSet();
    expect(left, {'0', '1'});
  });

  test('a cache under the cap is left alone', () async {
    File('${dir.path}/0').writeAsBytesSync(List.filled(100, 0));
    await trimPosters(dir);
    expect(dir.listSync(), hasLength(1));
  });
}

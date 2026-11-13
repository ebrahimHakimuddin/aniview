import 'dart:async';
import 'dart:io';

import 'package:aniview/net.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final original = httpClient, limit = patience;
  setUp(() => patience = const Duration(milliseconds: 200));
  tearDown(() {
    httpClient = original;
    patience = limit;
  });

  test('a host that never answers fails with an HttpException', () async {
    httpClient = MockClient((_) => Completer<http.Response>().future);
    await expectLater(
      fetch('https://quiet.example/'),
      throwsA(isA<HttpException>()),
    );
  });

  test('a body that stops arriving fails with an HttpException', () async {
    final body = StreamController<List<int>>()..add([1]);
    httpClient = MockClient.streaming(
      (_, _) async => http.StreamedResponse(body.stream, 200),
    );
    await expectLater(
      fetch('https://stalls.example/'),
      throwsA(isA<HttpException>()),
    );
  });

  test('a body that keeps arriving may take longer than the limit', () async {
    Stream<List<int>> slow() async* {
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(patience ~/ 2);
        yield 'ab'.codeUnits;
      }
    }

    httpClient = MockClient.streaming(
      (_, _) async => http.StreamedResponse(slow(), 200),
    );
    final clock = Stopwatch()..start();
    expect(await fetch('https://slow.example/'), 'ab' * 6);
    expect(clock.elapsed, greaterThan(patience * 2));
  });

  test('a streamed segment that stops arriving fails mid-stream', () async {
    final body = StreamController<List<int>>()..add([1]);
    httpClient = MockClient.streaming(
      (_, _) async => http.StreamedResponse(body.stream, 200),
    );
    await expectLater(
      await streamBytes('https://segment.example/'),
      emitsInOrder([
        [1],
        emitsError(isA<HttpException>()),
      ]),
    );
  });

  test('a download answer that stops arriving fails mid-stream', () async {
    final body = StreamController<List<int>>()..add([1]);
    httpClient = MockClient.streaming(
      (_, _) async => http.StreamedResponse(body.stream, 206),
    );
    final response = await openGet('https://file.example/');
    expect(response.statusCode, 206);
    await expectLater(
      response.stream,
      emitsInOrder([
        [1],
        emitsError(isA<HttpException>()),
      ]),
    );
  });
}

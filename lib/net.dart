import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http2/http2.dart' hide Settings;

const userAgent =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36';

/// How long a request waits for an answer, and for the next part of a body that has stopped arriving. A large
/// download that keeps arriving takes as long as it needs. Shortened in tests.
Duration patience = const Duration(seconds: 30);

/// A site wants its Cloudflare check passed by hand (the verification page can).
class CloudflareChallenge implements Exception {
  CloudflareChallenge(this.url);
  final String url;
  @override
  String toString() =>
      'Cloudflare verification required for ${Uri.parse(url).host}';
}

/// How the site adapters reach the network: plain GETs ([HttpNet]), or through a Cloudflare clearance
/// (`CloudflareNet`, cloudflare.dart). A fake in tests. Failures are an [HttpException] (or a [CloudflareChallenge]).
abstract class Net {
  Future<String> text(String url, {Map<String, String>? headers});
  Future<Uint8List> bytes(String url, {Map<String, String>? headers});
}

/// Every plain HTTP request the sites make; a MockClient in tests.
@visibleForTesting
http.Client httpClient = http.Client();

/// Hosts whose Cloudflare turns away HTTP/1.1 (all package:http speaks), e.g. animepahe's kwik player and its CDN.
final _h2Hosts = <String>{};

/// HTTP/1.1, then HTTP/2 for the hosts that refuse it (and from then on).
class HttpNet implements Net {
  const HttpNet();

  Future<http.Response> _get(String url, Map<String, String>? headers) async {
    final uri = Uri.parse(url);
    final all = {'User-Agent': userAgent, ...?headers};
    if (!_h2Hosts.contains(uri.host)) {
      final res = await _send(uri, all);
      if (res.statusCode == 200) {
        return http.Response.bytes(
          await _body(res.stream, uri),
          200,
          headers: res.headers,
          request: res.request,
        );
      }
      await res.stream.drain<void>();
      if (res.statusCode != 403) {
        throw HttpException('HTTP ${res.statusCode}', uri: uri);
      }
    }
    final (int, Map<String, String>, Uint8List) h2;
    try {
      h2 = await h2Get(uri, all);
    } on TimeoutException {
      throw HttpException('Timed out', uri: uri);
    }
    final (status, response, body) = h2;
    if (status != 200) throw HttpException('HTTP $status', uri: uri);
    _h2Hosts.add(uri.host);
    return http.Response.bytes(
      body,
      status,
      headers: {'content-type': ?response['content-type']},
    );
  }

  @override
  Future<String> text(String url, {Map<String, String>? headers}) async =>
      (await _get(url, headers)).body;

  @override
  Future<Uint8List> bytes(String url, {Map<String, String>? headers}) async =>
      (await _get(url, headers)).bodyBytes;
}

Future<String> postJson(
  String url,
  Object body, {
  Map<String, String>? headers,
}) async {
  final uri = Uri.parse(url);
  final response = await httpClient
      .post(
        uri,
        headers: {
          'User-Agent': userAgent,
          ...?headers,
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      )
      .timeout(patience);
  if (response.statusCode != 200) {
    throw HttpException('HTTP ${response.statusCode}', uri: uri);
  }
  return response.body;
}

Future<String> fetch(String url, {Map<String, String>? headers}) =>
    const HttpNet().text(url, headers: headers);

/// [url]'s body as it arrives, once the host has answered 200, for the relay to pass on before a large segment has
/// finished downloading; HTTP/2 (all at once) for the hosts that refuse HTTP/1.1.
Future<Stream<List<int>>> streamBytes(
  String url, {
  Map<String, String>? headers,
}) async {
  final uri = Uri.parse(url);
  if (!_h2Hosts.contains(uri.host)) {
    final res = await _send(uri, {'User-Agent': userAgent, ...?headers});
    if (res.statusCode == 200) return _unquiet(res.stream, uri);
    await res.stream.drain<void>();
    if (res.statusCode != 403) {
      throw HttpException('HTTP ${res.statusCode}', uri: uri);
    }
  }
  return Stream.value(await fetchBytes(url, headers: headers));
}

/// [url] answered as it arrives, whatever the status, for a caller saving a large file in parts (a Range header
/// answered 206). HTTP/1.1 only.
Future<http.StreamedResponse> openGet(
  String url, {
  Map<String, String>? headers,
}) async {
  final uri = Uri.parse(url);
  final res = await _send(uri, {'User-Agent': userAgent, ...?headers});
  return http.StreamedResponse(
    _unquiet(res.stream, uri),
    res.statusCode,
    contentLength: res.contentLength,
    request: res.request,
    headers: res.headers,
    isRedirect: res.isRedirect,
    persistentConnection: res.persistentConnection,
    reasonPhrase: res.reasonPhrase,
  );
}

/// A GET answered within [patience], or an [HttpException].
Future<http.StreamedResponse> _send(Uri uri, Map<String, String> headers) =>
    httpClient
        .send(http.Request('GET', uri)..headers.addAll(headers))
        .timeout(
          patience,
          onTimeout: () => throw HttpException('Timed out', uri: uri),
        );

/// [body] as it arrives, failing with an [HttpException] once it goes quiet for [patience].
Stream<List<int>> _unquiet(Stream<List<int>> body, Uri uri) => body.timeout(
  patience,
  onTimeout: (sink) => sink
    ..addError(HttpException('Timed out', uri: uri))
    ..close(),
);

/// All of [body], or an [HttpException] once it goes quiet for [patience].
// Not through [_unquiet]: under a widget test's clock a Stream.timeout only ends once the test does.
Future<Uint8List> _body(Stream<List<int>> body, Uri uri) async {
  final bytes = BytesBuilder(copy: false);
  final parts = StreamIterator(body);
  try {
    while (await parts.moveNext().timeout(patience)) {
      bytes.add(parts.current);
    }
  } on TimeoutException {
    parts.cancel().ignore();
    throw HttpException('Timed out', uri: uri);
  }
  return bytes.takeBytes();
}

Future<Uint8List> fetchBytes(String url, {Map<String, String>? headers}) =>
    const HttpNet().bytes(url, headers: headers);

/// One HTTP/2 GET. package:http speaks only HTTP/1.1, which Cloudflare turns away on some sites (animepahe).
/// [extra] overrides the default user agent; names are lowercased as HTTP/2 requires.
// ponytail: a new connection per request (HLS segments included); pool ClientTransportConnections per host if
// segment loads get slow
Future<(int, Map<String, String>, Uint8List)> h2Get(
  Uri uri, [
  Map<String, String> extra = const {},
]) async {
  final headers = {
    'user-agent': userAgent,
    for (final MapEntry(:key, :value) in extra.entries)
      key.toLowerCase(): value,
  };
  final socket = await SecureSocket.connect(
    uri.host,
    443,
    supportedProtocols: const ['h2'],
    timeout: const Duration(seconds: 15),
  );
  final connection = ClientTransportConnection.viaSocket(socket);
  try {
    final stream = connection.makeRequest([
      Header.ascii(':method', 'GET'),
      Header.ascii(
        ':path',
        uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path,
      ),
      Header.ascii(':scheme', 'https'),
      Header.ascii(':authority', uri.host),
      for (final MapEntry(:key, :value) in headers.entries)
        Header.ascii(key, value),
    ], endStream: true);
    final response = <String, String>{};
    final body = BytesBuilder(copy: false);
    await for (final message in stream.incomingMessages.timeout(patience)) {
      switch (message) {
        case HeadersStreamMessage(:final headers):
          for (final h in headers) {
            response[utf8.decode(h.name)] = utf8.decode(h.value);
          }
        case DataStreamMessage(:final bytes):
          body.add(bytes);
      }
    }
    return (
      int.tryParse(response[':status'] ?? '') ?? 0,
      response,
      body.takeBytes(),
    );
  } finally {
    // terminate, not finish: finish waits forever on a stream abandoned by the timeout.
    await connection.terminate();
  }
}

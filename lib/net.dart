import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http2/http2.dart' hide Settings;

const userAgent =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36';

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
      final res = await httpClient.get(uri, headers: all);
      if (res.statusCode == 200) return res;
      if (res.statusCode != 403) {
        throw HttpException('HTTP ${res.statusCode}', uri: uri);
      }
    }
    final (status, response, body) = await h2Get(uri, all);
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

Future<String> fetch(String url, {Map<String, String>? headers}) =>
    const HttpNet().text(url, headers: headers);

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
    await for (final message in stream.incomingMessages.timeout(
      const Duration(seconds: 30),
    )) {
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

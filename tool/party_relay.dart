// The watch party's own relay: the NIP-01 subset lib/party_transport.dart speaks, and nothing else. Nothing is
// stored; each event goes to whoever is subscribed to its room tag right now, the sender included (a client only
// counts a relay usable once an event comes back). Messages are end-to-end encrypted, so the relay sees only tags,
// ids and ciphertext.
//
//   dart compile exe tool/party_relay.dart -o party_relay
//   HOST=127.0.0.1 PORT=7447 ./party_relay       # behind a Cloudflare Tunnel, which terminates TLS
//
// Imports only dart: libraries, so it compiles standalone.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The one event kind rooms use (`partyEventKind`).
const _kind = 21000;

/// Clients drop events further than this from their clock (`NostrTransport.clockSlack`), so there's no point
/// passing them on.
const _clockSlack = 900;

/// A party message is at most 2048 bytes (`partyMaxMessage`); sealed and base64'd that's ~2.8 KB, ~3.3 KB as a
/// whole EVENT frame, so 16 KiB is ~5× headroom while keeping one socket's buffer small.
const maxFrame = 16 * 1024;

/// Per connection: subscriptions, and the EVENT token bucket (honest peers send at most 5 a second).
const _maxSubs = 4, _burst = 40.0, _refillPerSecond = 10.0;

final _hex64 = RegExp(r'^[0-9a-f]{64}$'), _hex128 = RegExp(r'^[0-9a-f]{128}$');

Future<void> main() async {
  final env = Platform.environment;
  await runZonedGuarded(
    () async {
      final server = await serveRelay(
        host: env['HOST'] ?? '127.0.0.1',
        port: int.parse(env['PORT'] ?? '7447'),
      );
      stdout.writeln('party relay on ${server.address.host}:${server.port}');
    },
    (e, s) => stderr.writeln('party relay: $e'),
  ); // one bad socket never takes the others down
}

/// Serves the relay on [host]:[port] (0 picks a free port) until the returned server is closed.
Future<HttpServer> serveRelay({
  Object host = '127.0.0.1',
  int port = 7447,
  int maxConnections = 2000,
  int maxPerIp = 20,
}) async {
  final server = await HttpServer.bind(host, port);
  final perIp = <String, int>{};
  // Room tag → connections with a subscription to it, so an event only visits its own room.
  final byTag = <String, Set<_Conn>>{};
  var total = 0;

  server.listen((request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.write('party relay\n'); // health check
      return request.response.close().ignore();
    }
    final remote = request.connectionInfo?.remoteAddress;
    // cloudflared, on the same machine, passes Cloudflare's CF-Connecting-IP, which the edge overwrites (its
    // X-Forwarded-For keeps whatever the client sent); anyone else is the client.
    final ip = remote == null || remote.isLoopback
        ? request.headers['cf-connecting-ip']?.first.trim() ??
              remote?.address ??
              ''
        : remote.address;
    final full = total >= maxConnections
        ? HttpStatus.serviceUnavailable
        : (perIp[ip] ?? 0) >= maxPerIp
        ? HttpStatus.tooManyRequests
        : null;
    if (full != null) {
      request.response.statusCode = full;
      return request.response.close().ignore();
    }
    total++;
    perIp[ip] = (perIp[ip] ?? 0) + 1;
    void release() {
      total--;
      if ((perIp[ip] = perIp[ip]! - 1) == 0) perIp.remove(ip);
    }

    final WebSocket socket;
    try {
      socket = await WebSocketTransformer.upgrade(
        request,
        compression: CompressionOptions
            .compressionOff, // no inflating small frames into big ones
      );
    } catch (_) {
      return release();
    }
    socket.pingInterval = const Duration(
      seconds: 30,
    ); // drops peers that vanished without closing
    final conn = _Conn(socket);
    var closed = false;
    void cleanUp() {
      if (closed) return;
      closed = true;
      release();
      for (final tag in {for (final tags in conn.subs.values) ...tags}) {
        final conns = byTag[tag]?..remove(conn);
        if (conns != null && conns.isEmpty) byTag.remove(tag);
      }
      conn.subs.clear();
    }

    socket.listen(
      (data) {
        // shortcut: dart:io hands over a whole frame before its length can be checked, so a huge one is buffered
        // first and the systemd MemoryMax is the backstop; read frames off the raw socket if that cap is ever hit.
        if (data is! String || data.length > maxFrame) {
          socket.close(WebSocketStatus.messageTooBig).ignore();
          return cleanUp();
        }
        try {
          conn.onFrame(data, byTag);
        } catch (e) {
          stderr.writeln('party relay: $e');
        }
      },
      onDone: cleanUp,
      onError: (_) => cleanUp(),
      cancelOnError: true,
    );
  });
  return server;
}

void _unindex(Map<String, Set<_Conn>> byTag, _Conn conn, Set<String> tags) {
  for (final tag in tags) {
    // Only when no other subscription of this connection still wants the tag.
    if (conn.subs.values.where((t) => t.contains(tag)).length > 1) continue;
    final conns = byTag[tag]?..remove(conn);
    if (conns != null && conns.isEmpty) byTag.remove(tag);
  }
}

/// One client: its subscriptions (id → room tags) and its EVENT allowance.
class _Conn {
  _Conn(this.socket);
  final WebSocket socket;
  final subs = <String, Set<String>>{};
  double _tokens = _burst;
  final _clock = Stopwatch()..start();

  void send(String frame) {
    try {
      socket.add(frame);
    } catch (_) {} // gone: its onDone cleans up
  }

  /// Malformed frames get no answer: the client gives up on a relay that sends NOTICE.
  void onFrame(String data, Map<String, Set<_Conn>> byTag) {
    final Object? frame;
    try {
      frame = jsonDecode(data);
    } on FormatException {
      return;
    }
    switch (frame) {
      case ['REQ', final String sub, ...final filters] when sub.length <= 64:
        final tags = <String>{};
        for (final f in filters) {
          if (f case {'#d': final List ds}
              when ds.isNotEmpty &&
                  ds.every((d) => d is String) &&
                  switch (f['kinds']) {
                    null => true,
                    final List kinds => kinds.contains(_kind),
                    _ => false,
                  }) {
            tags.addAll(ds.cast<String>());
          } else {
            return send(
              jsonEncode([
                'CLOSED',
                sub,
                'unsupported: only #d filters for kind $_kind',
              ]),
            );
          }
        }
        if (tags.isEmpty ||
            (!subs.containsKey(sub) && subs.length >= _maxSubs)) {
          return send(
            jsonEncode([
              'CLOSED',
              sub,
              'unsupported: no filter, or too many subscriptions',
            ]),
          );
        }
        final old = subs[sub];
        if (old != null) _unindex(byTag, this, old);
        subs[sub] = tags;
        for (final tag in tags) {
          (byTag[tag] ??= {}).add(this);
        }
        send(jsonEncode(['EOSE', sub]));
      case ['CLOSE', final String sub]:
        final old = subs[sub];
        if (old != null) _unindex(byTag, this, old);
        subs.remove(sub);
      case ['EVENT', final Map event]:
        final id = event['id'] is String ? event['id'] as String : '';
        final tag = _check(event);
        if (tag == null) {
          return send(
            jsonEncode(['OK', id, false, 'invalid: not a party event']),
          );
        }
        // shortcut: ids and Schnorr signatures aren't verified (no crypto without packages; clients check both and
        // the tag comes from the secret room code), verify them here if events ever get stored or relayed onwards.
        _tokens =
            (_tokens + _clock.elapsedMicroseconds / 1e6 * _refillPerSecond)
                .clamp(0, _burst);
        _clock.reset();
        if (_tokens < 1) {
          return send(jsonEncode(['OK', id, false, 'rate-limited: slow down']));
        }
        _tokens--;
        send(jsonEncode(['OK', id, true, '']));
        // The event's own bytes, so the id the clients recompute can't be thrown off by re-encoding.
        final raw = data.substring(
          data.indexOf('{'),
          data.lastIndexOf('}') + 1,
        );
        for (final conn in [...?byTag[tag]]) {
          for (final MapEntry(key: sub, value: tags) in conn.subs.entries) {
            if (tags.contains(tag)) {
              conn.send('["EVENT",${jsonEncode(sub)},$raw]');
            }
          }
        }
    }
  }

  /// The room tag of a well-formed, current party event, or null.
  static String? _check(Map event) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (event
        case {
          'id': final String id,
          'pubkey': final String pubkey,
          'sig': final String sig,
          'kind': _kind,
          'created_at': final int at,
          'content': String _,
          'tags': final List tags,
        }
        when _hex64.hasMatch(id) &&
            _hex64.hasMatch(pubkey) &&
            _hex128.hasMatch(sig) &&
            (now - at).abs() <= _clockSlack) {
      for (final t in tags) {
        if (t case ['d', final String tag, ...] when _hex64.hasMatch(tag)) {
          return tag;
        }
      }
    }
    return null;
  }
}

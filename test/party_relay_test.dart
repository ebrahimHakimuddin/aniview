import 'dart:convert';
import 'dart:io';

import 'package:aniview/party_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/party_relay.dart' show maxFrame, serveRelay;
import 'party_transport_test.dart' show Inbox, msg, nowS, until;

/// A bare WebSocket to the relay, keeping every frame it gets back as text.
class Client {
  Client._(this.socket) {
    socket.listen((d) => frames.add(d as String), onDone: () => closed = true);
  }

  static Future<Client> connect(int port) async =>
      Client._(await WebSocket.connect('ws://127.0.0.1:$port'));

  final WebSocket socket;
  final frames = <String>[];
  bool closed = false;

  void send(Object frame) => socket.add(jsonEncode(frame));

  /// The [i]th frame received, decoded.
  Future<Object?> frame(int i) async {
    await until(() => frames.length > i);
    return jsonDecode(frames[i]);
  }
}

final tag = 'd' * 64;

/// A well-formed party event; the relay doesn't check ids or signatures, so any hex will do.
Map<String, Object> event({int kind = partyEventKind, int? at, String? d}) => {
  'id': 'a' * 64,
  'pubkey': 'b' * 64,
  'created_at': at ?? nowS(),
  'kind': kind,
  'tags': [
    ['d', d ?? tag],
  ],
  'content': 'sealed',
  'sig': 'c' * 128,
};

void main() {
  late HttpServer server;
  final closers = <Future<void> Function()>[];

  setUp(() async => server = await serveRelay(port: 0));
  tearDown(() async {
    for (final close in closers) {
      await close();
    }
    closers.clear();
    await server.close(force: true);
  });

  Future<Client> client([HttpServer? on]) async {
    final c = await Client.connect((on ?? server).port);
    closers.add(c.socket.close);
    return c;
  }

  test(
    'two transports in a room talk through it, and another room hears nothing',
    () async {
      final room = PartyRoom.create();
      NostrTransport join(PartyRoom room) {
        final t = NostrTransport(
          room,
          relays: ['ws://127.0.0.1:${server.port}'],
        );
        closers.add(t.close);
        return t;
      }

      final a = join(room), b = join(room), c = join(PartyRoom.create());
      final inB = Inbox(b), inC = Inbox(c);
      await Future.wait([room.keys, c.room.keys]);
      // Usable only once an event comes back, so keep talking (well under the rate limit) until both have.
      final end = DateTime.now().add(const Duration(seconds: 15));
      for (var n = 0; a.usable.value + b.usable.value < 2; n++) {
        if (DateTime.now().isAfter(end)) fail('never usable');
        await a.send(msg(a, 'hello', n));
        await b.send(msg(b, 'hi', n));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      // Nothing is stored, so what a said before b subscribed is gone; this one isn't.
      final hello = msg(a, 'now you are here', 1000);
      await a.send(hello);
      await until(() => inB.messages.contains(hello));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(inC.messages, isEmpty);
      expect(c.usable.value, 0);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'an event reaches every subscriber, the sender included, byte for byte',
    () async {
      final a = await client(), b = await client(), other = await client();
      for (final c in [a, b]) {
        c.send([
          'REQ',
          's',
          {
            'kinds': [partyEventKind],
            '#d': [tag],
            'since': 0,
          },
        ]);
        expect(await c.frame(0), ['EOSE', 's']);
      }
      other.send([
        'REQ',
        'x',
        {
          '#d': ['e' * 64],
        },
      ]);
      expect(await other.frame(0), ['EOSE', 'x']);
      // Escapes and non-ASCII that re-encoding would change.
      final raw = jsonEncode(event())
          .replaceFirst('"sealed"', r'"café é \/ \n"');
      a.socket.add('["EVENT", $raw]');
      expect(await a.frame(1), ['OK', 'a' * 64, true, '']);
      for (final c in [a, b]) {
        await until(() => c.frames.any((f) => f.contains('"EVENT"')));
        expect(c.frames.where((f) => f.contains('"EVENT"')), [
          '["EVENT","s",$raw]',
        ]);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(other.frames, hasLength(1));
    },
  );

  test('events of the wrong kind, stale or misshapen are refused', () async {
    final c = await client();
    final bad = [
      event(kind: 1),
      event(at: nowS() - 1000),
      event(at: nowS() + 1000),
      event(d: 'short'),
      {...event(), 'sig': 'c' * 127},
      {...event(), 'id': 'A' * 64},
    ];
    for (final (i, e) in bad.indexed) {
      c.send(['EVENT', e]);
      expect(await c.frame(i), ['OK', e['id'], false, startsWith('invalid:')]);
    }
    // Junk gets no answer at all: a NOTICE would make the client drop the relay.
    c.socket.add('not json');
    c.send(['WHAT', 1]);
    c.send(['EVENT', 'x']);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(c.frames, hasLength(bad.length));
  });

  test('subscriptions need a #d filter for kind 21000, four at most', () async {
    final c = await client();
    c.send([
      'REQ',
      'a',
      {
        'kinds': [partyEventKind],
      },
    ]);
    expect(await c.frame(0), ['CLOSED', 'a', startsWith('unsupported:')]);
    c.send([
      'REQ',
      'b',
      {
        'kinds': [1],
        '#d': [tag],
      },
    ]);
    expect(await c.frame(1), ['CLOSED', 'b', startsWith('unsupported:')]);
    for (var i = 0; i < 5; i++) {
      c.send([
        'REQ',
        's$i',
        {
          '#d': [tag],
        },
      ]);
    }
    for (var i = 0; i < 4; i++) {
      expect(await c.frame(2 + i), ['EOSE', 's$i']);
    }
    expect(await c.frame(6), ['CLOSED', 's4', startsWith('unsupported:')]);
    // Replacing one is fine; closing one makes room.
    c.send([
      'REQ',
      's0',
      {
        '#d': [tag],
      },
    ]);
    expect(await c.frame(7), ['EOSE', 's0']);
    c.send(['CLOSE', 's1']);
    c.send([
      'REQ',
      's4',
      {
        '#d': [tag],
      },
    ]);
    expect(await c.frame(8), ['EOSE', 's4']);
  });

  test('an oversized frame closes the socket', () async {
    final c = await client();
    c.socket.add('["EVENT",{"content":"${'x' * maxFrame}"}]');
    await until(() => c.closed);
    expect(c.socket.closeCode, WebSocketStatus.messageTooBig);
  });

  test('events past the burst are rate-limited', () async {
    final c = await client();
    for (var i = 0; i < 60; i++) {
      c.send(['EVENT', event()]);
    }
    await c.frame(59);
    final oks = c.frames.map(jsonDecode).toList();
    expect(oks.take(40), everyElement(['OK', 'a' * 64, true, '']));
    expect(
      oks,
      contains(equals(['OK', 'a' * 64, false, 'rate-limited: slow down'])),
    );
  });

  test('a plain HTTP request is a health check', () async {
    final http = HttpClient();
    final response = await (await http.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/'),
    )).close();
    expect(response.statusCode, 200);
    expect(await utf8.decodeStream(response), contains('relay'));
    http.close();
  });

  test('connections per client address are capped', () async {
    final small = await serveRelay(port: 0, maxPerIp: 2);
    closers.add(() => small.close(force: true));
    await client(small);
    await client(small);
    await expectLater(
      WebSocket.connect('ws://127.0.0.1:${small.port}'),
      throwsA(isA<WebSocketException>()),
    );
    // Cloudflare keeps a client's own X-Forwarded-For, so it can't name the client...
    await expectLater(
      WebSocket.connect(
        'ws://127.0.0.1:${small.port}',
        headers: {'X-Forwarded-For': '203.0.113.7'},
      ),
      throwsA(isA<WebSocketException>()),
    );
    // ...but from loopback (cloudflared), CF-Connecting-IP does.
    final proxied = await WebSocket.connect(
      'ws://127.0.0.1:${small.port}',
      headers: {'CF-Connecting-IP': '203.0.113.7'},
    );
    closers.add(proxied.close);
  });
}

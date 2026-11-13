import 'dart:convert';
import 'dart:io';

import 'package:aniview/pairing.dart' show seal;
import 'package:aniview/party.dart';
import 'package:aniview/party_transport.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// How a [FakeRelay] behaves, after the bad relays seen in the wild.
enum RelayMode {
  good,

  /// Accepts the connection, the subscription and every event, and delivers nothing.
  silent,

  /// Answers every event with `OK false`, and delivers nothing.
  reject,

  /// Asks for authentication and closes the subscription.
  auth,
}

/// Just enough of a NIP-01 relay on 127.0.0.1: REQ with `kinds` and `#d`, EVENT fanned out to every matching
/// subscription (the sender's included), OK and EOSE.
class FakeRelay {
  FakeRelay._(this._server) {
    _server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      connections++;
      final subs = _subs[socket] = {};
      socket.listen(
        (data) => _onFrame(socket, subs, data as String),
        onDone: () => _subs.remove(socket),
      );
    });
  }

  static Future<FakeRelay> start() async =>
      FakeRelay._(await HttpServer.bind('127.0.0.1', 0));

  final HttpServer _server;
  final _subs = <WebSocket, Map<String, Map>>{};
  RelayMode mode = RelayMode.good;

  /// Sockets ever accepted, REQs ever received, and events delivered to subscribers.
  int connections = 0, reqs = 0, delivered = 0;

  String get url => 'ws://127.0.0.1:${_server.port}';
  int get open => _subs.length;

  void _onFrame(WebSocket socket, Map<String, Map> subs, String data) {
    switch (jsonDecode(data)) {
      case ['REQ', final String sub, final Map filter]:
        reqs++;
        if (mode == RelayMode.auth) {
          _write(socket, jsonEncode(['AUTH', 'challenge']));
          _write(socket, jsonEncode(['CLOSED', sub, 'auth-required: sign in']));
          return;
        }
        subs[sub] = filter;
        _write(socket, jsonEncode(['EOSE', sub]));
      case ['EVENT', final Map event]:
        final ok = mode != RelayMode.reject;
        _write(
          socket,
          jsonEncode([
            'OK',
            event['id'],
            ok,
            ok ? '' : 'restricted: not allowed',
          ]),
        );
        if (mode == RelayMode.good) inject(event);
    }
  }

  /// Sends [event] to every subscription it matches (every one, when [force]d), as if someone had published it.
  void inject(Map event, {bool force = false}) {
    for (final MapEntry(key: socket, value: subs) in _subs.entries) {
      for (final MapEntry(key: sub, value: filter) in subs.entries) {
        final kinds = filter['kinds'] as List?, ds = filter['#d'] as List?;
        final d = [
          for (final t in event['tags'] as List)
            if (t is List && t.length > 1 && t[0] == 'd') t[1],
        ];
        if (!force && kinds != null && !kinds.contains(event['kind'])) {
          continue;
        }
        if (!force && ds != null && !d.any(ds.contains)) continue;
        _write(socket, jsonEncode(['EVENT', sub, event]));
        delivered++;
      }
    }
  }

  static void _write(WebSocket socket, String frame) {
    try {
      socket.add(frame);
    } on StateError {
      // the peer has gone
    }
  }

  /// Drops every connection, as a relay restarting would.
  Future<void> dropAll() async {
    for (final socket in [..._subs.keys]) {
      await socket.close();
    }
    _subs.clear();
  }

  Future<void> stop() async {
    await dropAll();
    await _server.close(force: true);
  }
}

/// Waits until [condition] holds, failing after [timeout].
Future<void> until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Collects what a transport receives.
class Inbox {
  Inbox(NostrTransport t) {
    t.incoming.listen(messages.add, onDone: () => done = true);
  }
  final messages = <String>[];
  bool done = false;
}

String msg(NostrTransport t, String text, [int n = 0]) =>
    jsonEncode({'t': 'chat', 'text': text, 'from': t.peerId, 'n': n});

int nowS() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// A player that does what it's told.
class Controls implements PartyControls {
  Controls({this.episode, this.position = Duration.zero, this.playing = false});
  @override
  Duration position;
  @override
  Duration duration = const Duration(minutes: 24);
  @override
  bool playing, buffering = false;
  @override
  double rate = 1;
  @override
  PartyEpisode? episode;

  @override
  void applyPlay() => playing = true;
  @override
  void applyPause() => playing = false;
  @override
  void applySeek(Duration to) => position = to;
  @override
  void applyRate(double rate) => this.rate = rate;
  @override
  void openEpisode(PartyEpisode episode, Duration at) {
    this.episode = episode;
    position = at;
  }
}

void main() {
  group('PartyRoom', () {
    test('create makes 12 unambiguous characters that parse back', () {
      for (var i = 0; i < 50; i++) {
        final room = PartyRoom.create();
        expect(room.code, matches(RegExp(r'^[A-HJKMNP-Z2-9]{12}$')));
        expect(
          room.display,
          matches(RegExp(r'^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$')),
        );
        expect(PartyRoom.parse(room.display), room);
        expect(PartyRoom.parse(room.link), room);
      }
      expect(PartyRoom.create().toString(), isNot(contains('-')));
    });

    test('parse accepts the ways a code gets pasted', () {
      const code = 'K7QM2XVD9RTA';
      for (final text in [
        'K7QM-2XVD-9RTA',
        'K7QM2XVD9RTA',
        'k7qm-2xvd-9rta',
        '  K7qm2xVD9rta \n',
        'aniview://party/K7QM-2XVD-9RTA',
        'ANIVIEW://PARTY/k7qm2xvd9rta',
        'Join my watch party on AniView: aniview://party/K7QM-2XVD-9RTA (expires when I leave)',
        'Join my watch party, code K7QM-2XVD-9RTA',
      ]) {
        expect(PartyRoom.parse(text)?.code, code, reason: text);
      }
      for (final text in [
        '',
        'K7QM-2XVD-9RT',
        'K7QM-2XVD-9RTAB',
        'K0QM-2XVD-9RTA', // 0
        'KOQM-2XVD-9RTA', // O
        'K1QM-2XVD-9RTA', // 1
        'KIQM-2XVD-9RTA', // I
        'KLQM-2XVD-9RTA', // L
        'aniview://party/',
        'aniview://party/K7QM-2XVD',
        'nothing to see here',
      ]) {
        expect(PartyRoom.parse(text), isNull, reason: text);
      }
    });

    test('derivation is deterministic and the tag is not the key', () async {
      final a = PartyKeys.derive('K7QM2XVD9RTA');
      final b = await PartyRoom.parse('k7qm-2xvd-9rta')!.keys;
      final other = PartyKeys.derive('K7QM2XVD9RTB');
      expect(a.key, hasLength(32));
      expect(a.tag, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(b.key, a.key);
      expect(b.tag, a.tag);
      expect(other.key, isNot(a.key));
      expect(other.tag, isNot(a.tag));
      final keyHex = a.key
          .map((x) => x.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(a.tag, isNot(keyHex));
      expect(a.tag, isNot(contains(keyHex.substring(0, 16))));
    });
  });

  group('BIP-340', () {
    // From https://github.com/bitcoin/bips/blob/master/bip-0340/test-vectors.csv
    const vectors = [
      (
        '0000000000000000000000000000000000000000000000000000000000000003',
        'f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9',
        '0000000000000000000000000000000000000000000000000000000000000000',
        '0000000000000000000000000000000000000000000000000000000000000000',
        'e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca821525f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0',
      ),
      (
        'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef',
        'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659',
        '0000000000000000000000000000000000000000000000000000000000000001',
        '243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89',
        '6896bd60eeae296db48a229ff71dfe071bde413e6d43f917dc8dcf8c78de33418906d11ac976abccb20b091292bff4ea897efcb639ea871cfa95f6de339e4b0a',
      ),
      (
        'c90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b14e5c9',
        'dd308afec5777e13121fa72b9cc1b7cc0139715309b086c960e18fd969774eb8',
        'c87aa53824b4d7ae2eb035a2b5bbbccc080e76cdc6d1692c4b0b62d798e6d906',
        '7e2d58d8b3bcdf1abadec7829054f90dda9805aab56c77333024b9d0a508b75c',
        '5831aaeed7b44bb74e5eab94ba9d4294c49bcf2a60728d8b4c200f50dd313c1bab745879a5ad954a72c45a91c3a51d3c7adea98d82f8481e0e1e03674a6f3fb7',
      ),
      (
        '0b432b2677937381aef05bb02a66ecd012773062cf3fa2549e44f58ed2401710',
        '25d1dff95105f5253c4022f628a996ad3a0d95fbf21d468a1b33f8c160d8f517',
        'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
        'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
        '7eb0509757e246f19449885651611cb965ecc1a187dd51b64fda1edc9637d5ec97582b9cb13db3933705b32ba982af5af25fd78881ebb32771fc5922efc66ea3',
      ),
    ];

    test('signing matches the official vectors', () {
      for (final (secret, pubkey, aux, message, signature) in vectors) {
        final key = NostrKey(secret);
        expect(key.pubkey, pubkey);
        expect(key.signHash(message, aux: aux), signature);
        expect(NostrKey.verify(pubkey, message, signature), isTrue);
      }
    });

    test('verification rejects the official bad vectors and junk', () {
      const message =
          '243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89';
      // Vector 5: public key not on the curve.
      expect(
        NostrKey.verify(
          'eefdea4cdb677750a420fee807eacf21eb9898ae79b9768766e4faa04a2d4a34',
          message,
          '6cff5c3ba86c69ea4b7376f31a9bcb4f74c1976089b2d9963da2e5543e17776969e89b4c5564d00349106b8497785dd7d1d713a8ae82b32fa79d5f7fc407d39b',
        ),
        isFalse,
      );
      // Vector 6: has_even_y(R) is false.
      expect(
        NostrKey.verify(
          'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659',
          message,
          'fff97bd5755eeea420453a14355235d382f6472f8568a18b2f057a14602975563cc27944640ac607cd107ae10923d9ef7a73c643e166be5ebeafa34b1ac553e2',
        ),
        isFalse,
      );
      expect(NostrKey.verify('zz', message, 'zz'), isFalse);
    });
  });

  group('NostrTransport', () {
    late PartyRoom room;
    late PartyKeys keys;
    final relays = <FakeRelay>[];
    final transports = <NostrTransport>[];

    setUp(() async {
      room = PartyRoom.create();
      keys = await room.keys;
    });

    tearDown(() async {
      for (final t in transports) {
        await t.close();
      }
      for (final r in relays) {
        await r.stop();
      }
      transports.clear();
      relays.clear();
    });

    Future<FakeRelay> relay([RelayMode mode = RelayMode.good]) async {
      final r = await FakeRelay.start()
        ..mode = mode;
      relays.add(r);
      return r;
    }

    NostrTransport join(List<FakeRelay> on, {PartyRoom? inRoom}) {
      final t = NostrTransport(
        inRoom ?? room,
        relays: [for (final r in on) r.url],
      );
      transports.add(t);
      return t;
    }

    Future<void> connected(List<FakeRelay> on, int count) =>
        until(() => on.every((r) => r.reqs >= count));

    test('two peers exchange a message and do not hear their own', () async {
      final r = await relay();
      final a = join([r]), b = join([r]);
      final inA = Inbox(a), inB = Inbox(b);
      expect(a.peerId, matches(RegExp(r'^[0-9a-f]{24}$')));
      expect(a.peerId, isNot(b.peerId));
      await connected([r], 2);
      final hello = msg(a, 'hi');
      await a.send(hello);
      await until(() => inB.messages.isNotEmpty);
      await b.send(msg(b, 'back'));
      await until(() => inA.messages.isNotEmpty);
      expect(inB.messages, [hello]);
      expect(inA.messages, [msg(b, 'back')]);
      expect(a.usable.value, 1);
      expect(b.usable.value, 1);
    });

    test('an event delivered by two relays arrives once', () async {
      final r1 = await relay(), r2 = await relay();
      final a = join([r1, r2]), b = join([r1, r2]);
      final inB = Inbox(b);
      await connected([r1, r2], 2);
      await a.send(msg(a, 'once'));
      // Each relay delivers it to both peers.
      await until(() => r1.delivered == 2 && r2.delivered == 2);
      await until(() => b.usable.value == 2 && a.usable.value == 2);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(inB.messages, [msg(a, 'once')]);
    });

    test('a relay that never delivers never becomes usable', () async {
      final good = await relay(),
          silent = await relay(RelayMode.silent),
          reject = await relay(RelayMode.reject),
          auth = await relay(RelayMode.auth);
      final a = join([good, silent, reject, auth]);
      final seen = <int>[];
      a.usable.addListener(() => seen.add(a.usable.value));
      expect(a.usable.value, 0);
      await connected([good, silent, reject, auth], 1);
      await a.send(msg(a, 'anyone?'));
      await until(() => a.usable.value == 1);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(a.usable.value, 1);
      expect(seen, [1]);
      // The auth relay closed our subscription, so it's being retried rather than crashing anything.
      await until(() => auth.connections >= 2);
    });

    test(
      'forged, badly signed, foreign, stale and unreadable events are dropped',
      () async {
        final r = await relay();
        final a = join([r]), b = join([r]);
        final inB = Inbox(b);
        await connected([r], 2);

        final mallory = NostrKey.random();
        Map<String, Object> event(
          NostrKey key,
          String text, {
          String? tag,
          int? at,
          String? content,
        }) => key.event(
          createdAt: at ?? nowS(),
          kind: partyEventKind,
          tags: [
            ['d', tag ?? keys.tag],
          ],
          content: content ?? base64.encode(seal(keys.key, text)),
        );

        // Each of these breaks one rule and is otherwise a good message from mallory.
        var n = 0;
        String own(String text) => jsonEncode({
          't': 'chat',
          'text': text,
          'from': mallory.pubkey.substring(0, 24),
          'n': n++,
        });
        final other = await PartyRoom.create().keys;

        // Claims to be a, signed by mallory.
        r.inject(event(mallory, msg(a, 'forged')));
        // Signature broken.
        final broken = event(mallory, own('bad sig'));
        final sig = broken['sig'] as String;
        broken['sig'] =
            '${sig.substring(0, 127)}${sig[127] == '0' ? '1' : '0'}';
        r.inject(broken);
        // Content swapped after signing, so the id no longer matches (the signature does, over the old id).
        final tampered = event(mallory, own('before'));
        tampered['content'] = base64.encode(seal(keys.key, own('after')));
        r.inject(tampered);
        // Another room's tag (forced past the relay's filter); sealed with our key, so only the tag gives it away.
        r.inject(
          event(mallory, own('other room'), tag: other.tag),
          force: true,
        );
        // Tags changed after signing.
        final retagged = event(mallory, own('retagged'), tag: other.tag);
        retagged['tags'] = [
          ['d', keys.tag],
        ];
        r.inject(retagged);
        // Two minutes old, and two minutes ahead.
        r.inject(event(mallory, own('old'), at: nowS() - 1000));
        r.inject(event(mallory, own('early'), at: nowS() + 1000));
        // Sealed with another room's key, and not base64.
        r.inject(
          event(
            mallory,
            '',
            content: base64.encode(seal(other.key, own('wrong key'))),
          ),
        );
        r.inject(event(mallory, '', content: 'not base64!'));
        // A properly signed event of the wrong kind.
        r.inject(
          mallory.event(
            createdAt: nowS(),
            kind: 1,
            tags: [
              ['d', keys.tag],
            ],
            content: base64.encode(seal(keys.key, own('kind 1'))),
          ),
          force: true,
        );

        // Then an honest message from mallory's own key, which must be the only thing that arrives.
        final honest = own('ok');
        r.inject(event(mallory, honest));
        await until(() => inB.messages.isNotEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(inB.messages, [honest]);
      },
    );

    test('reconnects and resubscribes after the relay drops it', () async {
      final r = await relay();
      final a = join([r]), b = join([r]);
      final inB = Inbox(b);
      await connected([r], 2);
      await a.send(msg(a, 'one'));
      await until(() => a.usable.value == 1 && inB.messages.length == 1);

      await r.dropAll();
      await until(() => a.usable.value == 0);
      // Backoff starts at 1 s.
      await until(() => r.open == 2 && r.reqs == 4);
      await a.send(msg(a, 'two', 1));
      await until(() => inB.messages.length == 2);
      expect(inB.messages.last, msg(a, 'two', 1));
      expect(a.usable.value, 1);
    });

    test('close stops everything', () async {
      final r = await relay();
      final a = join([r]);
      final inA = Inbox(a);
      await connected([r], 1);
      await a.close();
      await until(() => r.open == 0 && inA.done);
      expect(a.usable.value, 0);
      await a.send(msg(a, 'too late'));
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(r.connections, 1);
      expect(r.open, 0);
    });

    test('a host and a guest end up on the same episode', () async {
      final r = await relay();
      final ht = join([r]), gt = join([r]);
      await connected([r], 2);
      const ep = PartyEpisode(anilist: 21, mal: 21, number: 4);
      final hostPlayer = Controls(
        episode: ep,
        position: const Duration(minutes: 3),
        playing: true,
      );
      final guestPlayer = Controls();
      final host = PartySession(
        transport: ht,
        controls: hostPlayer,
        isHost: true,
        name: 'Host',
        id: ht.peerId,
        tickEvery: null,
      );
      final guest = PartySession(
        transport: gt,
        controls: guestPlayer,
        isHost: false,
        name: 'Guest',
        id: gt.peerId,
        tickEvery: null,
      );
      expect(host.id, ht.peerId);
      host.start();
      guest.start();
      await until(() {
        host.tick();
        guest.tick();
        return guestPlayer.episode?.sameAs(ep) ?? false;
      });
      expect(guestPlayer.position.inSeconds, closeTo(180, 5));
      expect(guest.peers[host.id]?.host, isTrue);
      expect(host.peers.keys, [guest.id]);
      await guest.leave();
      await host.leave();
    });
  });

  test('derivation time', () {
    final sw = Stopwatch()..start();
    PartyKeys.derive('K7QM2XVD9RTA');
    debugPrint('scrypt derivation: ${sw.elapsedMilliseconds} ms');
  });
}

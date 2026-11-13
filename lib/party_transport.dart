/// The watch party's real transport: a room's messages, end-to-end encrypted, through public Nostr relays.
///
/// A room is a 12-character code ([PartyRoom]) that friends share. From it, scrypt and labelled hashes derive an
/// AES key and a relay tag ([PartyKeys]); relays only ever see the tag and ciphertext. Each message is a NIP-01
/// ephemeral event (kind 21000) tagged `["d", tag]`, whose content is the message sealed with [seal], signed with
/// a key made fresh for each join ([NostrKey]). A peer's id is the first 24 hex characters of that key's public
/// key, so holding the room code isn't enough to speak as someone else.
///
/// [NostrTransport] keeps a socket to every relay, publishes to all of them and reads from all of them,
/// dropping duplicates. A relay only counts as usable once it has delivered an event to us: some relays accept
/// everything and deliver nothing.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:bip340/bip340.dart' as bip340;
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart'
    show ECDomainParameters, SHA256Digest, Scrypt, ScryptParameters;

import 'pairing.dart' show seal, unseal;
import 'party.dart';

// ───────────────────────────── room ─────────────────────────────

/// A room's shareable code: 12 characters from [alphabet], shown as `K7QM-2XVD-9RTA`.
class PartyRoom {
  PartyRoom._(this.code);

  /// Uppercase letters and digits without the easily confused 0, O, 1, I and L.
  static const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

  /// The 12 characters, without dashes.
  final String code;

  factory PartyRoom.create() {
    final r = Random.secure();
    return PartyRoom._(
      List.generate(12, (_) => alphabet[r.nextInt(alphabet.length)]).join(),
    );
  }

  /// The room in [text]: a code typed or pasted in any case, with or without dashes, or an
  /// `aniview://party/<code>` link, alone or in a longer message. Null when there's no valid code.
  static PartyRoom? parse(String text) {
    final upper = text.toUpperCase();
    final link = RegExp(r'ANIVIEW://PARTY/([A-Z0-9-]+)').firstMatch(upper);
    final candidates = [
      if (link != null) link[1]! else upper.trim(),
      if (link == null)
        for (final m in RegExp(
          r'(?<![A-Z0-9])[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}(?![A-Z0-9])',
        ).allMatches(upper))
          m[0]!,
    ];
    for (final candidate in candidates) {
      final code = candidate.replaceAll(RegExp(r'[\s-]'), '');
      if (code.length == 12 && code.split('').every(alphabet.contains)) {
        return PartyRoom._(code);
      }
    }
    return null;
  }

  /// `K7QM-2XVD-9RTA`.
  String get display =>
      '${code.substring(0, 4)}-${code.substring(4, 8)}-${code.substring(8)}';

  String get link => 'aniview://party/$display';

  /// The room's key and relay tag, derived once (off the main isolate, as scrypt takes a moment).
  late final Future<PartyKeys> keys = Isolate.run(() => PartyKeys.derive(code));

  @override
  bool operator ==(Object other) => other is PartyRoom && other.code == code;

  @override
  int get hashCode => code.hashCode;

  /// Never the code itself, so a room can't end up in a log by accident.
  @override
  String toString() => 'PartyRoom(…)';
}

/// What a room's code gives its members: the AES-256 [key] messages are sealed with, and the [tag] relays route
/// by. Both come from one scrypt of the code through separately labelled SHA-256s, so the tag says nothing about
/// the key.
class PartyKeys {
  PartyKeys._(this.key, this.tag);
  final Uint8List key;

  /// 64 hex characters.
  final String tag;

  /// scrypt N = 2^14, r = 8, p = 1 (16 MiB): about 0.1 s on a desktop, a few tenths of a second on a phone.
  static const scryptN = 1 << 14, scryptR = 8, scryptP = 1;

  /// Slow on purpose: call it through [PartyRoom.keys].
  static PartyKeys derive(String code) {
    final scrypt = Scrypt()
      ..init(
        ScryptParameters(
          scryptN,
          scryptR,
          scryptP,
          32,
          Uint8List.fromList(utf8.encode('aniview-party-v1')),
        ),
      );
    final seed = scrypt.process(Uint8List.fromList(utf8.encode(code)));
    return PartyKeys._(
      _sha256('party-key', seed),
      _hex(_sha256('party-tag', seed)),
    );
  }

  @override
  String toString() => 'PartyKeys(…)';
}

/// SHA-256 of [label] followed by [data], as `_sha256` in pairing.dart does.
Uint8List _sha256(String label, List<int> data) => SHA256Digest().process(
  Uint8List.fromList([...utf8.encode(label), ...data]),
);

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

// ───────────────────────────── nostr ─────────────────────────────

/// The ephemeral event kind a room's messages travel as.
const partyEventKind = 21000;

final _curveOrder = ECDomainParameters('secp256k1').n;

/// A secp256k1 key signing NIP-01 events with BIP-340 Schnorr signatures.
class NostrKey {
  NostrKey(this._private) : pubkey = bip340.getPublicKey(_private);

  /// A fresh key, made for one join and never tied to the install.
  factory NostrKey.random() {
    while (true) {
      final d = _hex(_randomBytes(32));
      final n = BigInt.parse(d, radix: 16);
      if (n > BigInt.zero && n < _curveOrder) return NostrKey(d);
    }
  }

  final String _private;

  /// The x-only public key, 64 hex characters.
  final String pubkey;

  /// The BIP-340 signature of the 32-byte hex [hash], 128 hex characters; [aux] is random unless given.
  String signHash(String hash, {String? aux}) =>
      bip340.sign(_private, hash, aux ?? _hex(_randomBytes(32)));

  /// A signed NIP-01 event.
  Map<String, Object> event({
    required int createdAt,
    required int kind,
    required List<List<String>> tags,
    required String content,
  }) {
    final id = eventId(pubkey, createdAt, kind, tags, content);
    return {
      'id': id,
      'pubkey': pubkey,
      'created_at': createdAt,
      'kind': kind,
      'tags': tags,
      'content': content,
      'sig': signHash(id),
    };
  }

  /// SHA-256 of the NIP-01 serialisation, in hex.
  static String eventId(
    String pubkey,
    int createdAt,
    int kind,
    List<Object?> tags,
    String content,
  ) => _hex(
    SHA256Digest().process(
      utf8.encode(jsonEncode([0, pubkey, createdAt, kind, tags, content])),
    ),
  );

  /// Whether [signature] is [pubkey]'s BIP-340 signature of [hash]; false for anything malformed.
  static bool verify(String pubkey, String hash, String signature) {
    final hex = RegExp(r'^[0-9a-f]+$');
    if (pubkey.length != 64 || hash.length != 64 || signature.length != 128) {
      return false;
    }
    if (![pubkey, hash, signature].every(hex.hasMatch)) return false;
    try {
      return bip340.verify(pubkey, hash, signature);
    } catch (_) {
      return false;
    }
  }
}

// ───────────────────────────── transport ─────────────────────────────

typedef WebSocketConnector = Future<WebSocket> Function(String url);

/// A [PartyTransport] over Nostr relays. It starts connecting when made; [usable] counts the relays that have
/// delivered an event, so 0 means "connecting" at first and "no relay reachable" if it stays there.
class NostrTransport implements PartyTransport {
  NostrTransport(
    this.room, {
    List<String> relays = defaultRelays,
    WebSocketConnector? connect,
    int Function()? clock,
  }) : _connect = connect ?? WebSocket.connect,
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _relays = [for (final url in relays) _Relay(this, url)];
    room.keys.then((keys) {
      if (_closed) return;
      _keys = keys;
      for (final relay in _relays) {
        relay.connect();
      }
    });
  }

  /// Relays seen accepting and delivering ephemeral events at 4 a second.
  static const defaultRelays = [
    'wss://relay.primal.net',
    'wss://relay.snort.social',
    'wss://offchain.pub',
  ];

  final PartyRoom room;
  final WebSocketConnector _connect;
  final int Function() _clock;
  final _key = NostrKey.random();
  late final List<_Relay> _relays;
  PartyKeys? _keys;
  bool _closed = false;

  final _incoming = StreamController<String>.broadcast();
  final _usable = ValueNotifier<int>(0);

  /// Event ids already handled, with the signature that checked out, so duplicates skip verification.
  final _seen = <String, String>{};

  /// What we sent in the last few seconds, replayed to a relay that (re)connects.
  final _recent = <(int, String)>[];

  /// The id to give [PartySession]: the first [peerIdLength] hex characters of this join's public key. Messages
  /// whose `from` isn't their signer's are dropped.
  String get peerId => _key.pubkey.substring(0, peerIdLength);

  /// 96 bits: too many to search for a key whose id matches someone else's.
  static const peerIdLength = 24;

  /// How far a peer's clock may be from ours, in seconds. Phones are often seconds and sometimes minutes out,
  /// and relays apply `since` to live events too; replays inside the window are dropped by event id.
  static const clockSlack = 900;

  /// How many relays have delivered an event to us since they last connected.
  ValueListenable<int> get usable => _usable;

  @override
  Stream<String> get incoming => _incoming.stream;

  @override
  Future<void> send(String message) async {
    final keys = _keys ?? await room.keys;
    if (_closed) return;
    final now = _clock();
    final frame = jsonEncode([
      'EVENT',
      _key.event(
        createdAt: now ~/ 1000,
        kind: partyEventKind,
        tags: [
          ['d', keys.tag],
        ],
        content: base64.encode(seal(keys.key, message)),
      ),
    ]);
    _recent
      ..removeWhere((e) => now - e.$1 > 5000)
      ..add((now, frame));
    if (_recent.length > 32) _recent.removeAt(0);
    for (final relay in _relays) {
      relay.write(frame);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await Future.wait([for (final relay in _relays) relay.close()]);
    _usable.value = 0;
    await _incoming.close();
  }

  void _countUsable() {
    if (!_closed) _usable.value = _relays.where((r) => r.usable).length;
  }

  /// One event from [relay]'s subscription: [relay] is usable if it checks out, and its message goes to
  /// [incoming] if it's someone else's and new.
  void _onEvent(_Relay relay, Object? event) {
    final keys = _keys;
    if (keys == null) return;
    if (event
        case {
          'id': final String id,
          'pubkey': final String pubkey,
          'created_at': final int createdAt,
          'kind': final int kind,
          'tags': final List tags,
          'content': final String content,
          'sig': final String sig,
        }
        when kind == partyEventKind &&
            tags.any(
              (t) =>
                  t is List && t.length >= 2 && t[0] == 'd' && t[1] == keys.tag,
            )) {
      if ((_clock() ~/ 1000 - createdAt).abs() > clockSlack) return;
      final known = _seen[id];
      if (known != sig &&
          (known != null ||
              id != NostrKey.eventId(pubkey, createdAt, kind, tags, content) ||
              !NostrKey.verify(pubkey, id, sig))) {
        return;
      }
      relay.markUsable();
      if (known != null) return;
      _seen[id] = sig;
      if (_seen.length > 1024) _seen.remove(_seen.keys.first);
      if (pubkey == _key.pubkey) return;
      final String text;
      try {
        text = unseal(keys.key, base64.decode(content));
      } catch (_) {
        return;
      }
      if (_fromOf(text) != pubkey.substring(0, peerIdLength)) return;
      if (!_incoming.isClosed) _incoming.add(text);
    }
  }

  static Object? _fromOf(String text) {
    try {
      return switch (jsonDecode(text)) {
        {'from': final Object? from} => from,
        _ => null,
      };
    } on FormatException {
      return null;
    }
  }
}

/// One relay's connection: reconnects by itself with backoff until the transport closes.
class _Relay {
  _Relay(this._t, this.url);
  final NostrTransport _t;
  final String url;

  WebSocket? _socket;
  Timer? _retry;
  Duration _backoff = const Duration(seconds: 1);
  bool usable = false;
  int _subs = 0;
  String _sub = '';

  Future<void> connect() async {
    if (_t._closed) return;
    final pending = _t._connect(url);
    final WebSocket socket;
    try {
      socket = await pending.timeout(const Duration(seconds: 10));
    } catch (_) {
      pending.then((s) => s.close(), onError: (_) {}).ignore();
      _scheduleRetry();
      return;
    }
    if (_t._closed) {
      socket.close().ignore();
      return;
    }
    _socket = socket..pingInterval = const Duration(seconds: 20);
    _sub = 'p${_subs++}';
    socket.listen(
      _onFrame,
      onDone: () => _lost(socket),
      onError: (_) => _lost(socket),
      cancelOnError: true,
    );
    final keys = _t._keys!;
    write(
      jsonEncode([
        'REQ',
        _sub,
        {
          'kinds': [partyEventKind],
          '#d': [keys.tag],
          'since': _t._clock() ~/ 1000 - NostrTransport.clockSlack,
        },
      ]),
    );
    final now = _t._clock();
    for (final (at, frame) in _t._recent) {
      if (now - at <= 5000) write(frame);
    }
  }

  void write(String frame) {
    try {
      _socket?.add(frame);
    } catch (_) {}
  }

  void markUsable() {
    _backoff = const Duration(seconds: 1);
    if (usable) return;
    usable = true;
    _t._countUsable();
  }

  void _unusable() {
    if (!usable) return;
    usable = false;
    _t._countUsable();
  }

  void _onFrame(Object? data) {
    if (data is! String) return;
    final Object? frame;
    try {
      frame = jsonDecode(data);
    } on FormatException {
      return;
    }
    switch (frame) {
      case ['EVENT', final String sub, final Object? event] when sub == _sub:
        _t._onEvent(this, event);
      case ['OK', _, false, ...] || ['NOTICE', ...] || ['AUTH', ...]:
        _unusable();
      case ['CLOSED', final String sub, ...] when sub == _sub:
        _unusable(); // our subscription is gone: start over
        _socket?.close().ignore();
    }
  }

  void _lost(WebSocket socket) {
    if (_socket != socket) return;
    _socket = null;
    _unusable();
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_t._closed) return;
    _retry?.cancel();
    _retry = Timer(_backoff, connect);
    final doubled = _backoff * 2;
    _backoff = doubled > const Duration(seconds: 30)
        ? const Duration(seconds: 30)
        : doubled;
  }

  Future<void> close() async {
    _retry?.cancel();
    final socket = _socket;
    _socket = null;
    usable = false;
    await socket?.close().catchError((_) {});
  }
}

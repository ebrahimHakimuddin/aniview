import 'dart:convert';

import 'package:aniview/party.dart';
import 'package:flutter_test/flutter_test.dart';

/// A player that does what it's told at once and records it.
class FakeControls implements PartyControls {
  @override
  Duration position = Duration.zero, duration = const Duration(minutes: 24);
  @override
  bool playing = false, buffering = false;
  @override
  double rate = 1;
  @override
  PartyEpisode? episode;
  final calls = <String>[];

  @override
  void applyPlay() {
    calls.add('play');
    playing = true;
  }

  @override
  void applyPause() {
    calls.add('pause');
    playing = false;
  }

  @override
  void applySeek(Duration to) {
    calls.add('seek ${to.inMilliseconds}');
    position = to;
  }

  @override
  void applyRate(double rate) {
    calls.add('rate $rate');
    this.rate = rate;
  }

  @override
  void openEpisode(PartyEpisode episode, Duration at) {
    calls.add('open ${episode.number} ${at.inMilliseconds}');
    this.episode = episode;
    position = at;
  }
}

const ep3 = PartyEpisode(anilist: 21, mal: 21, number: 3);
const ep4 = PartyEpisode(anilist: 21, mal: 21, number: 4);

/// A room on a loopback hub with one fake clock; each peer's clock may be skewed from it.
class Rig {
  int now = 1000000;
  final hub = LoopbackHub();
  final players = <PartySession, FakeControls>{};
  final transports = <PartySession, LoopbackTransport>{};

  PartySession join({bool host = false, int skew = 0, FakeControls? player}) {
    final t = hub.join();
    final session = PartySession(
      transport: t,
      controls: player ?? FakeControls(),
      isHost: host,
      name: host ? 'host' : 'guest${players.length}',
      clock: () => now + skew,
      tickEvery: null,
    );
    players[session] = session.controls as FakeControls;
    transports[session] = t;
    session.start();
    return session;
  }

  /// Moves time on by [ms], playing every player that's playing, ticking everyone and delivering everything.
  void advance(int ms) {
    now += ms;
    for (final p in players.values) {
      if (p.playing && !p.buffering) {
        p.position += Duration(milliseconds: (ms * p.rate).round());
      }
    }
    tick();
  }

  void tick() {
    for (final s in players.keys) {
      s.tick();
    }
    hub.settle();
  }

  /// The types of every message [s] has sent.
  List<String> sentBy(PartySession s) => [
    for (final (from, m) in hub.sent)
      if (from == transports[s]) (jsonDecode(m) as Map)['t'] as String,
  ];
}

/// A host playing episode 3 from 60 s, and one guest that has caught up and settled.
(Rig, PartySession host, PartySession guest) synced() {
  final rig = Rig();
  final host = rig.join(
    host: true,
    player: FakeControls()
      ..episode = ep3
      ..position = const Duration(seconds: 60)
      ..playing = true,
  );
  rig.hub.settle();
  final guest = rig.join();
  rig.hub.settle();
  for (var i = 0; i < 22; i++) {
    rig.advance(250);
  }
  rig.players[guest]!.calls.clear();
  return (rig, host, guest);
}

double driftOf(Rig rig, PartySession host, PartySession guest) =>
    (rig.players[guest]!.position - rig.players[host]!.position)
        .inMilliseconds /
    1000;

String msg(Map<String, Object?> m) => jsonEncode(m);

void main() {
  test('a guest knows the host\'s episode once its state arrives', () {
    final rig = Rig();
    final host = rig.join(
      host: true,
      player: FakeControls()
        ..episode = ep3
        ..playing = true,
    );
    final guest = rig.join();
    expect(guest.hostEpisode, isNull); // nothing heard yet
    rig.hub.settle();
    expect(guest.hostEpisode!.sameAs(ep3), isTrue);
    expect(guest.hostEpisode!.number, ep3.number);
    expect(host.hostEpisode, isNull); // the host follows nobody

    // The host moves on, and the guest hears it.
    const ep4 = PartyEpisode(anilist: 21, number: 4);
    rig.players[host]!.episode = ep4;
    rig.advance(
      1500,
    ); // past the second the joining took, at 5 messages a second
    expect(guest.hostEpisode!.sameAs(ep4), isTrue);
  });

  test('a late joiner opens the host\'s episode where the host is', () {
    final (rig, host, guest) = synced();
    final g = rig.players[guest]!;
    expect(g.episode!.sameAs(ep3), isTrue);
    expect(g.playing, isTrue);
    expect(driftOf(rig, host, guest).abs(), lessThan(0.2));
    expect(host.peers[guest.id]!.name, 'guest1');
    expect(guest.peers[host.id]!.host, isTrue);

    // The open itself went to the host's position at the time.
    final rig2 = Rig();
    rig2.join(
      host: true,
      player: FakeControls()
        ..episode = ep3
        ..position = const Duration(seconds: 60)
        ..playing = true,
    );
    rig2.hub.settle();
    rig2.advance(5000); // host now at 65 s
    final late = rig2.join();
    rig2.hub.settle();
    expect(rig2.players[late]!.calls, ['open 3 65000']);
  });

  test('a guest on another episode is moved to the host\'s', () {
    final (rig, host, guest) = synced();
    rig.players[host]!
      ..episode = ep4
      ..position = Duration.zero;
    rig.advance(250);
    expect(rig.players[guest]!.calls.first, startsWith('open 4 '));
    expect(rig.players[guest]!.episode!.sameAs(ep4), isTrue);
  });

  group('drift', () {
    test('under 0.7 s is left alone', () {
      final (rig, host, guest) = synced();
      rig.players[guest]!.position += const Duration(milliseconds: 600);
      rig.advance(250);
      rig.advance(250);
      expect(rig.players[guest]!.calls, isEmpty);
    });

    test('0.7–2.5 s ahead slows down until within 0.2 s, then restores', () {
      final (rig, host, guest) = synced();
      final g = rig.players[guest]!;
      g.position += const Duration(milliseconds: 1500);
      rig.advance(250);
      expect(g.calls, ['rate 0.95']);
      for (var i = 0; i < 200 && g.rate != 1; i++) {
        rig.advance(250);
      }
      expect(g.calls, ['rate 0.95', 'rate 1.0']);
      expect(driftOf(rig, host, guest).abs(), lessThan(0.2));
    });

    test('0.7–2.5 s behind speeds up', () {
      final (rig, host, guest) = synced();
      final g = rig.players[guest]!;
      g.position -= const Duration(milliseconds: 1000);
      rig.advance(250);
      expect(g.calls, ['rate 1.05']);
      for (var i = 0; i < 200 && g.rate != 1; i++) {
        rig.advance(250);
      }
      expect(g.calls.last, 'rate 1.0');
      expect(driftOf(rig, host, guest).abs(), lessThan(0.2));
    });

    test('over 2.5 s seeks, then holds off for 2 s', () {
      final (rig, host, guest) = synced();
      final g = rig.players[guest]!;
      g.position += const Duration(seconds: 4);
      rig.advance(250);
      expect(g.calls, hasLength(1));
      expect(g.calls.single, startsWith('seek '));
      expect(driftOf(rig, host, guest).abs(), lessThan(0.2));

      g.position += const Duration(seconds: 4);
      rig.advance(1000);
      expect(g.calls, hasLength(1)); // still settling after the seek
      rig.advance(1000);
      expect(g.calls, hasLength(2));
    });

    test('no corrections while buffering', () {
      final (rig, host, guest) = synced();
      final g = rig.players[guest]!
        ..buffering = true
        ..position += const Duration(seconds: 10);
      rig.advance(250);
      rig.advance(250);
      expect(g.calls, isEmpty);
      g.buffering = false;
      rig.advance(250);
      expect(g.calls.single, startsWith('seek '));
    });

    test('a new seq seeks even inside the nudge band', () {
      final (rig, host, guest) = synced();
      // A 1.1 s jump on the host is a seek there; guests follow it exactly.
      rig.players[host]!.position += const Duration(milliseconds: 1100);
      rig.advance(250);
      expect(rig.players[guest]!.calls.single, startsWith('seek '));
    });
  });

  test('host pause and play follow on guests; host buffering pauses them', () {
    final (rig, host, guest) = synced();
    final h = rig.players[host]!, g = rig.players[guest]!;
    h.playing = false;
    rig.advance(250);
    expect(g.playing, isFalse);
    rig.advance(500);
    h.playing = true;
    rig.advance(500);
    expect(g.playing, isTrue);
    h.buffering = true;
    rig.advance(500);
    expect(g.playing, isFalse);
    h.buffering = false;
    rig.advance(500);
    expect(g.playing, isTrue);
  });

  test('duplicated and reordered states end on the newest one', () {
    final (rig, host, guest) = synced();
    final h = rig.players[host]!, g = rig.players[guest]!;
    // Two changes reach the guest out of order and twice each: a seek, then a pause.
    h.position = const Duration(seconds: 300);
    rig.now += 400;
    host.tick();
    h.playing = false;
    rig.now += 400;
    host.tick();
    expect(rig.hub.pending, 2);
    rig.hub.deliver(reverse: true, duplicate: true);
    expect(g.playing, isFalse);
    expect(g.position, const Duration(seconds: 300));
    expect(g.calls, ['pause', 'seek 300000']);
  });

  test('a guest never echoes what the host made it do', () {
    final (rig, host, guest) = synced();
    final h = rig.players[host]!;
    h.position = const Duration(seconds: 200);
    rig.advance(400);
    h.playing = false;
    rig.advance(400);
    h.rate = 1.5;
    h.playing = true;
    rig.advance(400);
    rig.players[guest]!.position += const Duration(milliseconds: 1500);
    rig.advance(400);
    expect(rig.players[guest]!.calls, isNotEmpty);
    expect(rig.sentBy(guest).toSet(), {'hello', 'ping'});
  });

  test('guest presses reach the host, which steers everyone', () {
    final (rig, host, guest) = synced();
    expect(guest.onLocalIntent(PartyOp.pause), isTrue);
    rig.players[guest]!.playing = false; // the guest's player goes ahead
    rig.hub.settle();
    expect(rig.players[host]!.calls, ['pause']);
    rig.advance(250);
    expect(rig.players[guest]!.playing, isFalse);

    expect(
      guest.onLocalIntent(PartyOp.seek, position: const Duration(hours: 9)),
      isTrue,
    );
    rig.hub.settle();
    // Clamped to the episode's length.
    expect(rig.players[host]!.calls.last, 'seek ${24 * 60 * 1000}');

    expect(guest.onLocalIntent(PartyOp.rate, rate: 3), isFalse);
    expect(guest.onLocalIntent(PartyOp.rate, rate: 1.25), isTrue);
    rig.hub.settle();
    expect(rig.players[host]!.calls.last, 'rate 1.25');
  });

  test('host-only control blocks guest presses', () {
    final (rig, host, guest) = synced();
    host.hostOnly = true;
    rig.advance(400);
    expect(guest.hostOnly, isTrue);
    expect(guest.onLocalIntent(PartyOp.pause), isFalse);
    expect(rig.sentBy(guest), isNot(contains('ctl')));

    // A ctl that does arrive is ignored by the host.
    rig.transports[host]!.inject(
      msg({'t': 'ctl', 'op': 'pause', 'from': guest.id, 'n': 999}),
    );
    expect(rig.players[host]!.calls, isEmpty);
    expect(host.onLocalIntent(PartyOp.pause), isTrue);

    host.hostOnly = false;
    rig.advance(400);
    expect(guest.hostOnly, isFalse);
    expect(guest.onLocalIntent(PartyOp.pause), isTrue);
  });

  test(
    'malformed, oversized, unknown, duplicate and flooding input is dropped',
    () {
      final rig = Rig();
      final host = rig.join(host: true, player: FakeControls()..episode = ep3);
      final h = rig.players[host]!, inbox = rig.transports[host]!;
      for (final bad in [
        'not json',
        '[]',
        '"ctl"',
        msg({'t': 'ctl', 'op': 'play'}), // no sender
        msg({'t': 'ctl', 'op': 'play', 'from': 'x'}), // no counter
        msg({'t': 'ctl', 'op': 'play', 'from': 'x' * 33, 'n': 0}),
        msg({'t': 'evil', 'from': 'x', 'n': 0}),
        msg({'t': 'ctl', 'op': 'jump', 'from': 'x', 'n': 0}),
        msg({'t': 'ctl', 'op': 'seek', 'pos': '10', 'from': 'x', 'n': 0}),
        msg({'t': 'ctl', 'op': 'rate', 'rate': 3, 'from': 'x', 'n': 0}),
        msg({'t': 'chat', 'text': 'a' * 301, 'from': 'x', 'n': 0}),
        msg({'t': 'chat', 'text': 'a\u0007b', 'from': 'x', 'n': 0}),
        msg({'t': 'react', 'emoji': '🍕', 'from': 'x', 'n': 0}),
        msg({'t': 'ctl', 'op': 'play', 'from': 'x', 'n': 0, 'pad': 'a' * 2100}),
        msg({'t': 'hello', 'name': 'x', 'dur': -1, 'from': 'x', 'n': 0}),
      ]) {
        inbox.inject(bad);
      }
      expect(h.calls, isEmpty);
      expect(host.peers, isEmpty);

      // A duplicate counter is dropped.
      inbox.inject(msg({'t': 'ctl', 'op': 'play', 'from': 'dup', 'n': 1}));
      inbox.inject(msg({'t': 'ctl', 'op': 'play', 'from': 'dup', 'n': 1}));
      expect(h.calls, ['play']);
      h.calls.clear();

      // A burst a relay held back gets through; a flood loses only what's over 40 in 5 s, and the peer stays.
      for (var n = 0; n < 45; n++) {
        inbox.inject(msg({'t': 'ctl', 'op': 'play', 'from': 'flood', 'n': n}));
      }
      expect(h.calls, hasLength(40));
      expect(host.peers.containsKey('flood'), isTrue);
      rig.now += 5000;
      inbox.inject(msg({'t': 'ctl', 'op': 'pause', 'from': 'flood', 'n': 50}));
      expect(h.calls, contains('pause'));
    },
  );

  test('a guest gone quiet for 90 s gives its place up', () {
    final (rig, host, guest) = synced();
    final gone = rig.join();
    rig.advance(250);
    expect(host.peers.containsKey(gone.id), isTrue);
    // It vanishes without a bye.
    rig.players.remove(gone);
    rig.transports[gone]!.close();
    for (var i = 0; i < 95; i++) {
      rig.advance(1000);
    }
    expect(host.peers.containsKey(gone.id), isFalse);
    expect(guest.peers.containsKey(gone.id), isFalse);
    expect(host.peers.containsKey(guest.id), isTrue);
    expect(guest.ended, isFalse);
  });

  test('a silent host is flagged at 15 s and ends the room at 2 minutes', () {
    final (rig, host, guest) = synced();
    // The host vanishes without a bye.
    rig.players.remove(host);
    rig.transports[host]!.close();
    for (var i = 0; i < 16; i++) {
      rig.advance(1000);
    }
    expect(guest.hostSilent, isTrue);
    expect(guest.ended, isFalse);
    expect(rig.players[guest]!.playing, isTrue);
    for (var i = 0; i < 106; i++) {
      rig.advance(1000);
    }
    expect(guest.ended, isTrue);
  });

  test('a host with nothing open still keeps the room alive', () {
    final rig = Rig();
    final host = rig.join(host: true);
    final guest = rig.join();
    rig.hub.settle();
    for (var i = 0; i < 200; i++) {
      rig.advance(1000);
    }
    expect(guest.ended, isFalse);
    expect(guest.hostSilent, isFalse);
    expect(host.peers.containsKey(guest.id), isTrue);
  });

  test('clock offset keeps the lowest round trip of the samples', () {
    final rig = Rig();
    rig.join(host: true, player: FakeControls()..episode = ep3);
    rig.hub.settle();
    final guest = rig.join(skew: -3000); // the host's clock is 3 s ahead
    expect(guest.clockOffset, 0);
    rig.hub.deliver(); // hello and ping reach the host at once…
    rig.now += 400;
    rig.hub.settle(); // …and the answers take 400 ms back
    expect(guest.clockOffset, 3000 - 200);

    rig.now += 1000;
    guest.tick(); // another ping, 20 ms each way
    rig.now += 20;
    rig.hub.deliver();
    rig.now += 20;
    rig.hub.settle();
    expect(guest.clockOffset, 3000);

    // A slower, lopsided sample later doesn't replace it.
    rig.now += 1000;
    guest.tick();
    rig.hub.deliver();
    rig.now += 900;
    rig.hub.settle();
    expect(guest.clockOffset, 3000);

    // A pong for a ping we never sent is ignored.
    final before = guest.clockOffset;
    rig.transports[guest]!.inject(
      msg({
        't': 'pong',
        'to': guest.id,
        't0': 1,
        't1': 99999999,
        'from': guest.peers.keys.single,
        'n': 9999,
      }),
    );
    expect(guest.clockOffset, before);
  });

  test('the offset puts a skewed guest where the host is', () {
    final rig = Rig();
    final host = rig.join(
      host: true,
      player: FakeControls()
        ..episode = ep3
        ..position = const Duration(seconds: 60)
        ..playing = true,
    );
    rig.hub.settle();
    final guest = rig.join(skew: 7000);
    for (var i = 0; i < 40; i++) {
      rig.advance(250);
    }
    expect(guest.clockOffset, -7000);
    expect(driftOf(rig, host, guest).abs(), lessThan(0.2));
  });

  test(
    'when the host leaves the room ends; a guest leaving just goes',
    () async {
      final (rig, host, guest) = synced();
      final other = rig.join();
      rig.advance(250);
      expect(host.peers.keys, containsAll([guest.id, other.id]));

      await other.leave();
      rig.hub.settle();
      expect(host.peers.containsKey(other.id), isFalse);
      expect(other.ended, isTrue);
      expect(host.ended, isFalse);

      await host.leave();
      rig.hub.settle();
      expect(guest.ended, isTrue);
      final sent = rig.hub.sent.length;
      rig.advance(1000);
      expect(rig.hub.sent.length, sent);
    },
  );

  test('a host that just sent its limit still says goodbye', () async {
    final (rig, host, guest) = synced();
    for (var i = 0; i < 6; i++) {
      host.sendChat('line $i');
    }
    expect(host.sendChat('one too many'), isFalse);
    await host.leave();
    rig.hub.settle();
    expect(guest.ended, isTrue);
  });

  test('a room holds 8 peers', () {
    final rig = Rig();
    final host = rig.join(
      host: true,
      player: FakeControls()
        ..episode = ep3
        ..playing = true,
    );
    final guests = <PartySession>[];
    for (var i = 0; i < 8; i++) {
      guests.add(rig.join());
      rig.hub.settle();
      rig.advance(1100);
    }
    expect(host.peers, hasLength(7));
    expect(host.peers.containsKey(guests.last.id), isFalse);
    for (final g in guests.take(7)) {
      expect(rig.players[g]!.episode?.sameAs(ep3), isTrue);
    }
    expect(rig.players[guests.last]!.episode, isNull);
  });

  test(
    'chat is plain text up to 300 characters; reactions are a short list',
    () async {
      final (rig, host, guest) = synced();
      final heard = <PartyChat>[];
      host.chat.listen(heard.add);

      expect(guest.sendChat('   '), isFalse);
      expect(guest.sendChat('a' * 301), isFalse);
      expect(guest.sendChat(' hi\nthere '), isTrue);
      rig.advance(1000);
      expect(guest.sendChat('b' * 300), isTrue);
      expect(guest.react('🍕'), isFalse);
      expect(guest.react('🔥'), isTrue);
      rig.hub.settle();
      await Future<void>.delayed(Duration.zero);

      expect([for (final c in heard) c.text], ['hi there', 'b' * 300, '🔥']);
      expect(heard.first.name, 'guest1');
      expect(heard.last.reaction, isTrue);
    },
  );

  test('cuts within 2 s match; others surface a mismatch and take a nudge', () {
    final (rig, host, guest) = synced();
    expect(guest.durationMismatch, isNull);
    rig.players[guest]!.duration = const Duration(minutes: 24, seconds: 1);
    rig.advance(250);
    expect(guest.durationMismatch, isNull);

    rig.players[guest]!.duration = const Duration(minutes: 22, seconds: 30);
    rig.advance(250);
    expect(guest.durationMismatch, 90);
    rig.players[guest]!.calls.clear();
    guest.nudge(-1);
    rig.advance(250);
    expect(rig.players[guest]!.calls.single, startsWith('seek '));
    expect(driftOf(rig, host, guest), closeTo(-1, 0.2));
  });
}

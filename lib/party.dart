/// Watch party: friends watching the same episode in step, each streaming it from their own source.
///
/// This file is the transport-agnostic core: a host-authoritative sync state machine ([PartySession]) that talks
/// to the room through a [PartyTransport] and to the player through [PartyControls]. The host broadcasts its
/// playback `state` on every change and every 5 s; guests extrapolate the host's position with an estimated clock
/// offset and steer their own player towards it (nothing under 0.7 s, a ±5 % rate nudge up to 2.5 s, a seek
/// beyond). Guests ask the host for play/pause/seek/rate with `ctl` messages and the host's next `state` carries
/// the result, so a guest never re-broadcasts what it was told to do.
///
/// A room is one episode, keyed by [PartyEpisode] (AniList id, MyAnimeList id, episode number). Nothing about the
/// stream (url, headers, keys, source) is ever in a message. Peer ids are random per join.
///
/// Wire format: one JSON object per message, at most 2 KB, with `t` (type), `from` (peer id) and `n` (the
/// sender's message counter, for dropping duplicates). Types:
/// - `hello {name, dur, host, re}`: announces a peer; peers answer an unknown peer's hello with `re: true`.
/// - `state {seq, anilist, mal, ep, playing, buffering, pos, rate, at, dur, only}`: host to all. `seq` grows on
///   every play/pause/seek/rate/episode change; buffering, duration and heartbeat updates repeat it. `pos`/`dur`
///   are milliseconds, `at` is the host's clock (ms since epoch) when `pos` was read, `only` is host-only control.
/// - `ctl {op, pos?, rate?}`: guest to host, `op` one of play, pause, seek, rate.
/// - `ping {t0}` / `pong {to, t0, t1}`: clock offset estimation.
/// - `chat {text}`, `react {emoji}`, `bye {}`.
///
/// Anything malformed, oversized, unknown, duplicated or from a 9th peer is dropped silently, as is what a peer
/// sends beyond 40 messages in 5 s (peers keep themselves to 5 a second; the slack is for a relay delivering a
/// stalled connection's messages at once). Every peer says something at least every 10 s: a guest silent for 90 s
/// loses its place, and a host silent for 2 minutes, or leaving, ends the room.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

/// One episode of one show: what a room is about. Two keys are the same episode when their episode numbers match
/// and either their AniList or MyAnimeList ids do.
class PartyEpisode {
  const PartyEpisode({this.anilist, this.mal, required this.number})
    : assert(anilist != null || mal != null);
  final int? anilist, mal;
  final num number;

  bool sameAs(PartyEpisode other) =>
      number == other.number &&
      ((anilist != null && anilist == other.anilist) ||
          (mal != null && mal == other.mal));

  @override
  String toString() => 'PartyEpisode($anilist/$mal #$number)';
}

/// Carries a room's messages. The real one (encrypted, over public relays) is separate; [LoopbackHub] is the
/// in-memory one for tests. [incoming] must not echo the peer's own messages back (it's harmless if it does).
abstract class PartyTransport {
  Stream<String> get incoming;
  Future<void> send(String message);
  Future<void> close();
}

/// The player as a party sees it. [PartySession] reads the getters and drives remote changes only through the
/// `apply*` methods and [openEpisode]; the player must not report those back through
/// [PartySession.onLocalIntent], which is for the user's own presses.
abstract class PartyControls {
  Duration get position;
  Duration get duration;
  bool get playing;
  bool get buffering;
  double get rate;

  /// The episode open in the player, or null while none is.
  PartyEpisode? get episode;

  void applyPlay();
  void applyPause();
  void applySeek(Duration to);
  void applyRate(double rate);

  /// Opens [episode] and starts it at [at].
  void openEpisode(PartyEpisode episode, Duration at);
}

/// What the user asked their own player to do.
enum PartyOp { play, pause, seek, rate }

class PartyPeer {
  PartyPeer(this.id);
  final String id;
  String name = '';

  /// The peer's length of the episode, 0 while unknown.
  Duration duration = Duration.zero;
  bool host = false;

  final _seen = <int>{};
  final _recent = <int>[];

  /// When we last heard from them, on our clock.
  int _heard = 0;
}

/// A chat line or reaction, ours included.
class PartyChat {
  const PartyChat(this.peer, this.name, this.text, {this.reaction = false});
  final String peer, name, text;
  final bool reaction;
}

const partyRates = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
const partyReactions = ['👍', '😂', '😮', '😢', '❤️', '🔥'];
const partyMaxPeers = 8, partyMaxChat = 300, partyMaxMessage = 2048;

/// Latest host state as a guest holds it (and as the host last sent it).
class _State {
  _State(
    this.seq,
    this.ep,
    this.playing,
    this.buffering,
    this.pos,
    this.rate,
    this.at,
    this.dur,
    this.only,
  );
  final int seq, pos, at, dur;
  final PartyEpisode ep;
  final bool playing, buffering, only;
  final double rate;

  bool get moving => playing && !buffering;

  /// Where the host is at host time [now], in ms.
  double positionAt(int now) => pos + (moving ? max(0, now - at) * rate : 0);
}

/// One peer's end of a watch party. Create it with the room's transport and the player, then [start] it; it
/// ticks by itself every [tickEvery] (pass null to call [tick] by hand, as tests do). The player hook should also
/// call [tick] on player events so changes go out promptly.
class PartySession {
  PartySession({
    required this.transport,
    required this.controls,
    required this.isHost,
    this.name = '',
    int Function()? clock,
    this._tickEvery = const Duration(milliseconds: 250),
    String? id,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       id = id ?? _randomId();

  final PartyTransport transport;
  final PartyControls controls;
  final bool isHost;
  final String name;

  /// Random per join unless given (a transport that signs messages binds it to its key); never tied to the
  /// install.
  final String id;
  final int Function() _clock;
  final Duration? _tickEvery;

  final peers = <String, PartyPeer>{};
  final _chat = StreamController<PartyChat>.broadcast();
  final _changes = StreamController<void>.broadcast();
  StreamSubscription<String>? _sub;
  Timer? _timer;
  int _n = 0;
  final _sentAt = <int>[];
  int _lastSent = 0;

  /// Chat lines and reactions as they arrive.
  Stream<PartyChat> get chat => _chat.stream;

  /// Fires when [peers], [ended], [hostOnly] or [durationMismatch] change.
  Stream<void> get changes => _changes.stream;

  bool get ended => _ended;
  bool _ended = false;

  /// Whether only the host may play, pause, seek or change speed. The host sets it; guests learn it.
  bool get hostOnly => _hostOnly;
  bool _hostOnly = false;
  set hostOnly(bool value) {
    if (!isHost || value == _hostOnly) return;
    _hostOnly = value;
    _changed();
    tick();
  }

  // ───── host ─────
  _State? _sent;
  int _seq = 0;

  /// A newcomer is waiting for our state, which goes out on the next tick that can send it.
  bool _owed = false;

  // ───── guest ─────
  String? _hostId;
  _State? _host;
  bool _newSeq = false;
  PartyEpisode? _opening;
  int _seekQuietUntil = 0, _localQuietUntil = 0;
  bool _nudging = false;
  final _pings = <int>{};
  final _samples = <({int rtt, int offset})>[];
  int _lastPing = 0;

  /// The host's clock minus ours, from the lowest-round-trip of the last 5 ping samples; 0 until one arrives.
  int get clockOffset => _samples.isEmpty
      ? 0
      : _samples.reduce((a, b) => b.rtt < a.rtt ? b : a).offset;

  /// Whether a guest hasn't heard from the host for 15 s: it plays on, and the room ends at 2 minutes.
  bool get hostSilent => _hostSilent;
  bool _hostSilent = false;

  /// Seconds the host's cut is longer than ours, or null when they're within 2 s (the same cut) or unknown.
  double? get durationMismatch => _mismatch;
  double? _mismatch;

  /// Seconds added to the host's position when the cuts differ, set by [nudge].
  double get cutOffset => _cutOffset;
  double _cutOffset = 0;

  /// Shifts where we sit relative to the host by [seconds] (±1 from the UI) when the cuts differ.
  void nudge(double seconds) {
    _cutOffset += seconds;
    _newSeq = true; // re-seek to the new target
    tick();
  }

  void start() {
    _sub = transport.incoming.listen(_receive);
    _hello(reply: false);
    if (_tickEvery case final every?) {
      _timer = Timer.periodic(every, (_) => tick());
    }
    tick();
  }

  /// Leaves the room; when the host leaves, the room ends for everyone.
  Future<void> leave() async {
    if (_ended) return;
    _send({'t': 'bye'});
    _end();
    await transport.close();
  }

  /// The user pressed something on their own player. Returns whether the player should go ahead: false for a
  /// guest while only the host may control, or when the request can't be sent.
  bool onLocalIntent(PartyOp op, {Duration? position, double? rate}) {
    if (_ended || isHost) return true;
    if (_hostOnly) return false;
    if (op == PartyOp.rate && !partyRates.contains(rate)) return false;
    final sent = _send({
      't': 'ctl',
      'op': op.name,
      if (op == PartyOp.seek) 'pos': (position ?? Duration.zero).inMilliseconds,
      if (op == PartyOp.rate) 'rate': rate,
    });
    // Hold corrections until the host's answer, so we don't pull the player back meanwhile.
    if (sent) _localQuietUntil = _clock() + 2000;
    return sent;
  }

  /// Sends a chat line; false when it's empty, too long or can't be sent.
  bool sendChat(String text) {
    final clean = _cleanChat(text);
    if (clean == null || !_send({'t': 'chat', 'text': clean})) return false;
    if (!_chat.isClosed) _chat.add(PartyChat(id, name, clean));
    return true;
  }

  bool react(String emoji) {
    if (!partyReactions.contains(emoji) ||
        !_send({'t': 'react', 'emoji': emoji})) {
      return false;
    }
    if (!_chat.isClosed) _chat.add(PartyChat(id, name, emoji, reaction: true));
    return true;
  }

  /// Brings the room up to date: the host sends its state when it changed (or every 5 s), a guest pings for the
  /// clock offset and steers its player towards the host.
  void tick() {
    if (_ended) return;
    _expire();
    if (_ended) return;
    if (isHost) {
      _hostTick();
    } else {
      _ping();
      _correct();
    }
  }

  /// Forgets guests gone quiet, ends the room when the host has, and says something if we've been quiet ourselves.
  void _expire() {
    final now = _clock();
    final before = peers.length;
    peers.removeWhere((id, p) => id != _hostId && now - p._heard >= 90000);
    if (peers.length != before) _changed();
    if (peers[_hostId] case final host?) {
      final quiet = now - host._heard;
      if (quiet >= 120000) {
        _end();
        transport.close().ignore();
        return;
      }
      if ((quiet >= 15000) != _hostSilent) {
        _hostSilent = !_hostSilent;
        _changed();
      }
    }
    if (now - _lastSent >= 10000) _hello(reply: true);
  }

  bool _hello({required bool reply}) => _send({
    't': 'hello',
    'name': name,
    'dur': controls.duration.inMilliseconds,
    'host': isHost,
    're': reply,
  });

  // ───────────────────────────── host ─────────────────────────────

  void _hostTick() {
    final force = _owed;
    final ep = controls.episode;
    if (ep == null) return;
    final now = _clock(), last = _sent;
    final pos = controls.position.inMilliseconds,
        playing = controls.playing,
        rate = controls.rate;
    final jump =
        last == null ||
        !ep.sameAs(last.ep) ||
        playing != last.playing ||
        rate != last.rate ||
        (pos - last.positionAt(now)).abs() > 1000;
    final changed =
        jump ||
        controls.buffering != last.buffering ||
        controls.duration.inMilliseconds != last.dur ||
        _hostOnly != last.only;
    final since = now - (last?.at ?? 0);
    if (!force && !changed && since < 5000) return;
    if (!force && since < 300) {
      return; // a burst of changes goes out as one, on a later tick
    }
    final state = _State(
      jump ? ++_seq : _seq,
      ep,
      playing,
      controls.buffering,
      pos,
      rate,
      now,
      controls.duration.inMilliseconds,
      _hostOnly,
    );
    if (_send({
      't': 'state',
      'seq': state.seq,
      'anilist': ep.anilist,
      'mal': ep.mal,
      'ep': ep.number,
      'playing': state.playing,
      'buffering': state.buffering,
      'pos': state.pos,
      'rate': state.rate,
      'at': state.at,
      'dur': state.dur,
      'only': state.only,
    })) {
      _sent = state;
      _owed = false;
    } else if (jump) {
      _seq--;
    }
  }

  void _onCtl(String op, int? pos, double? rate) {
    if (!isHost || _hostOnly) return;
    switch (op) {
      case 'play':
        controls.applyPlay();
      case 'pause':
        controls.applyPause();
      case 'seek' when pos != null:
        controls.applySeek(_clamp(pos.toDouble()));
      case 'rate' when rate != null:
        controls.applyRate(rate);
      default:
        return;
    }
    tick();
  }

  // ───────────────────────────── guest ─────────────────────────────

  void _onState(String from, _State s) {
    if (isHost) return;
    if (_hostId != null && from != _hostId) return;
    final last = _host;
    if (last != null &&
        (s.seq < last.seq || (s.seq == last.seq && s.at <= last.at))) {
      return;
    }
    _hostId = from;
    peers[from]?.host = true;
    if (last == null || s.seq > last.seq) {
      _newSeq = true;
      _localQuietUntil = 0;
    }
    _host = s;
    if (s.only != _hostOnly) {
      _hostOnly = s.only;
      _changed();
    }
    _correct();
  }

  void _ping() {
    final now = _clock();
    if (now - _lastPing < (_samples.length < 5 ? 1000 : 30000)) return;
    if (_send({'t': 'ping', 't0': now})) {
      _lastPing = now;
      _pings.add(now);
      if (_pings.length > 10) _pings.remove(_pings.first);
    }
  }

  void _onPong(int t0, int t1) {
    if (!_pings.remove(t0)) return;
    final now = _clock(), rtt = now - t0;
    if (rtt < 0 || rtt > 10000) return;
    _samples.add((rtt: rtt, offset: t1 - (t0 + now) ~/ 2));
    if (_samples.length > 5) _samples.removeAt(0);
  }

  /// Steers our player towards the host's state.
  void _correct() {
    final s = _host;
    if (s == null || _ended) return;
    final now = _clock();
    final mine = controls.episode;
    if (mine == null || !mine.sameAs(s.ep)) {
      if (_opening == null || !_opening!.sameAs(s.ep)) {
        _opening = s.ep;
        _seekQuietUntil = now + 2000;
        controls.openEpisode(s.ep, _clamp(_target(s, now)));
      }
      return;
    }
    _opening = null;

    final myDur = controls.duration.inMilliseconds;
    final mismatch = s.dur > 0 && myDur > 0 && (s.dur - myDur).abs() > 2000
        ? (s.dur - myDur) / 1000
        : null;
    if (mismatch != _mismatch) {
      _mismatch = mismatch;
      _changed();
    }

    if (now < _localQuietUntil) return;
    if (controls.playing != s.moving) {
      s.moving ? controls.applyPlay() : controls.applyPause();
    }
    if (controls.buffering || now < _seekQuietUntil) return;

    final target = _clamp(_target(s, now));
    final drift = (controls.position - target).inMilliseconds / 1000;
    if ((_newSeq && drift.abs() >= 0.2) ||
        drift.abs() > 2.5 ||
        (!s.moving && drift.abs() >= 0.7)) {
      controls.applySeek(target);
      _seekQuietUntil = now + 2000;
      _newSeq = false;
      _nudging = false;
      if (controls.rate != s.rate) controls.applyRate(s.rate);
      return;
    }
    _newSeq = false;
    if (_nudging && drift.abs() < 0.2) _nudging = false;
    if (!_nudging && s.moving && drift.abs() >= 0.7) _nudging = true;
    final want = _nudging ? s.rate * (drift > 0 ? 0.95 : 1.05) : s.rate;
    if (controls.rate != want) controls.applyRate(want);
  }

  double _target(_State s, int now) =>
      s.positionAt(now + clockOffset) +
      (_mismatch == null ? 0 : _cutOffset * 1000);

  Duration _clamp(double ms) {
    final dur = controls.duration.inMilliseconds;
    return Duration(
      milliseconds: (dur > 0 ? ms.clamp(0, dur) : max(0, ms)).round(),
    );
  }

  // ───────────────────────────── wire ─────────────────────────────

  void _receive(String raw) {
    if (_ended ||
        raw.length > partyMaxMessage ||
        utf8.encode(raw).length > partyMaxMessage) {
      return;
    }
    final Object? m;
    try {
      m = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (m case {'from': final String from, 'n': final int n}
        when from.isNotEmpty && from.length <= 32) {
      if (from == id) return;
      final act = _parse(m as Map);
      if (act == null) return;
      final peer = peers[from] ?? (m['t'] == 'bye' ? null : _admit(from));
      if (peer == null || !peer._seen.add(n)) return;
      if (peer._seen.length > 256) peer._seen.remove(peer._seen.first);
      final now = _clock();
      peer._heard = now;
      // Counted on arrival, so a relay's burst after a stall mustn't cost an honest peer more than the excess.
      peer._recent
        ..removeWhere((t) => now - t >= 5000)
        ..add(now);
      if (peer._recent.length > 40) return;
      act(peer);
    }
  }

  PartyPeer? _admit(String from) {
    if (peers.length + 1 >= partyMaxPeers) return null;
    _changed();
    return peers[from] = PartyPeer(from);
  }

  /// What a valid message does, or null for anything malformed or unknown.
  void Function(PartyPeer)? _parse(Map m) => switch (m) {
    {'t': 'hello', 'name': final String name, 'dur': final int dur}
        when name.length <= 40 && dur >= 0 =>
      (p) => _onHello(p, name, dur, m['host'] == true, m['re'] == true),
    {
      't': 'state',
      'seq': final int seq,
      'ep': final num ep,
      'playing': final bool playing,
      'buffering': final bool buffering,
      'pos': final int pos,
      'rate': final num rate,
      'at': final int at,
      'dur': final int dur,
      'only': final bool only,
    }
        when _id(m['anilist']) &&
            _id(m['mal']) &&
            (m['anilist'] ?? m['mal']) != null &&
            pos >= 0 &&
            dur >= 0 &&
            partyRates.contains(rate) =>
      (p) => _onState(
        p.id,
        _State(
          seq,
          PartyEpisode(anilist: m['anilist'], mal: m['mal'], number: ep),
          playing,
          buffering,
          pos,
          rate.toDouble(),
          at,
          dur,
          only,
        ),
      ),
    {'t': 'ctl', 'op': 'play' || 'pause'} => (p) => _onCtl(m['op'], null, null),
    {'t': 'ctl', 'op': 'seek', 'pos': final int pos} => (p) => _onCtl(
      'seek',
      pos,
      null,
    ),
    {'t': 'ctl', 'op': 'rate', 'rate': final num rate}
        when partyRates.contains(rate) =>
      (p) => _onCtl('rate', null, rate.toDouble()),
    {'t': 'ping', 't0': final int t0} => (p) {
      if (isHost) _send({'t': 'pong', 'to': p.id, 't0': t0, 't1': _clock()});
    },
    {
      't': 'pong',
      'to': final String to,
      't0': final int t0,
      't1': final int t1,
    } =>
      (p) {
        if (!isHost && to == id && p.id == _hostId) _onPong(t0, t1);
      },
    {'t': 'chat', 'text': final String text} when _cleanChat(text) == text =>
      (p) {
        if (!_chat.isClosed) _chat.add(PartyChat(p.id, p.name, text));
      },
    {'t': 'react', 'emoji': final String emoji}
        when partyReactions.contains(emoji) =>
      (p) {
        if (!_chat.isClosed) {
          _chat.add(PartyChat(p.id, p.name, emoji, reaction: true));
        }
      },
    {'t': 'bye'} => _onBye,
    _ => null,
  };

  static bool _id(Object? v) => v == null || (v is int && v > 0);

  void _onHello(PartyPeer p, String theirName, int dur, bool host, bool re) {
    p
      ..name = theirName
      ..duration = Duration(milliseconds: dur);
    if (host && !isHost) {
      _hostId ??= p.id;
      p.host = p.id == _hostId;
    }
    _changed();
    if (re) return;
    _hello(reply: true);
    if (isHost) {
      _owed = true; // late join: the newcomer needs the state now
      _hostTick();
    }
  }

  void _onBye(PartyPeer p) {
    if (p.id == _hostId) {
      _end();
      transport.close().ignore();
      return;
    }
    peers.remove(p.id);
    _changed();
  }

  /// Sends [body], keeping ourselves to 5 messages a second, the most peers accept.
  bool _send(Map<String, Object?> body) {
    final now = _clock();
    _sentAt.removeWhere((t) => now - t >= 1000);
    if (_ended || _sentAt.length >= 5) return false;
    _sentAt.add(now);
    _lastSent = now;
    transport.send(jsonEncode({...body, 'from': id, 'n': _n++})).ignore();
    return true;
  }

  void _end() {
    _ended = true;
    _timer?.cancel();
    _sub?.cancel();
    _changed();
    _changes.close();
    _chat.close();
  }

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  static String _randomId() {
    final r = Random.secure();
    return List.generate(12, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  /// [text] trimmed and without control characters, or null when that's empty or over [partyMaxChat] characters.
  static String? _cleanChat(String text) {
    final clean = text.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
    return clean.isEmpty || clean.runes.length > partyMaxChat ? null : clean;
  }
}

// ───────────────────────────── loopback ─────────────────────────────

/// An in-memory room for tests: every message a peer sends reaches every other peer when [deliver] or [settle]
/// is called, so a test controls latency (advance the clock between send and deliver), order and duplicates.
class LoopbackHub {
  final _peers = <LoopbackTransport>[];
  final _queue = <(LoopbackTransport, String)>[];

  /// Every message sent so far, by sender.
  final sent = <(LoopbackTransport, String)>[];

  LoopbackTransport join() {
    final t = LoopbackTransport._(this);
    _peers.add(t);
    return t;
  }

  int get pending => _queue.length;

  /// Delivers what's queued now (not what that causes), [reverse]d or [duplicate]d if asked.
  void deliver({bool reverse = false, bool duplicate = false}) {
    final batch = [..._queue];
    _queue.clear();
    for (final (from, message) in reverse ? batch.reversed : batch) {
      for (final to in [..._peers]) {
        if (to == from || to._in.isClosed) continue;
        to._in.add(message);
        if (duplicate) to._in.add(message);
      }
    }
  }

  /// Delivers until nothing is left in flight.
  void settle() {
    for (var i = 0; i < 100 && _queue.isNotEmpty; i++) {
      deliver();
    }
  }
}

class LoopbackTransport implements PartyTransport {
  LoopbackTransport._(this._hub);
  final LoopbackHub _hub;
  final _in = StreamController<String>.broadcast(sync: true);

  /// Puts [message] straight into this peer's inbox, as if a peer sent it; for feeding tests raw input.
  void inject(String message) => _in.add(message);

  @override
  Stream<String> get incoming => _in.stream;

  @override
  Future<void> send(String message) async {
    if (_in.isClosed) return;
    _hub._queue.add((this, message));
    _hub.sent.add((this, message));
  }

  @override
  Future<void> close() async {
    _hub._peers.remove(this);
    await _in.close();
  }
}

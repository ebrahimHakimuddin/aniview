import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'exo.dart';
import 'party.dart';

/// The player as a watch party sees it: the [PartyControls] a [PartySession] is created with, before the player
/// exists, which `PlayerScreen` then attaches its player to. Start a party player with
///
/// ```dart
/// final party = PartySession(transport: t, controls: PartyPlayer(), isHost: host, name: name);
/// PlayerScreen(media: …, source: …, episodes: …, index: …, dub: …, party: party);
/// ```
///
/// and leave the session unstarted: the player starts it once attached, so the host's first state finds a player
/// to open its episode in, and leaves it when it closes.
///
/// Until attached it reads as an empty player and ignores what the session asks of it. While attached, the
/// person's own presses go through [PartySession.onLocalIntent] (see [ExoPlayer.intent]) and the session's
/// changes through the player's `apply*` methods, so they never come back as presses. When the session ends it
/// lets go of the player, which plays on as it was, at the room's speed.
class PartyPlayer implements PartyControls {
  PartySession? _session;
  ExoPlayer? _player;
  PartyEpisode? Function()? _episode;
  void Function(PartyEpisode episode, Duration at)? _open;
  void Function()? _refused, _ended;
  void Function(double rate)? _roomRateChanged;
  final _subs = <StreamSubscription>[];
  Duration _lastPosition = Duration.zero;

  /// The room's speed: the host's, set when the session applies one of [partyRates]. A guest catching up plays a
  /// little off it (×0.95 or ×1.05), which the speed shown shouldn't follow.
  double get roomRate => _roomRate;
  double _roomRate = 1;

  /// Whether a player is attached to a session still going.
  bool get active => _player != null && !(_session?.ended ?? true);

  bool get isHost => _session?.isHost ?? false;

  /// The player attached, for tests to press its buttons as the person would.
  @visibleForTesting
  ExoPlayer? get player => _player;

  /// Hooks [player] up to [session], whose controls this must be, and starts the session. [episode] says what's open, [open] opens an
  /// episode the host moved to, [refused] tells the person a press was refused, [rate] is the speed the player
  /// starts at, [roomRateChanged] reports the room's speed and [ended] that the session is over (after the player
  /// is let go).
  void attach(
    PartySession session,
    ExoPlayer player, {
    required PartyEpisode? Function() episode,
    required void Function(PartyEpisode episode, Duration at) open,
    required void Function() refused,
    double rate = 1,
    void Function(double rate)? roomRateChanged,
    void Function()? ended,
  }) {
    assert(
      identical(session.controls, this),
      'the session must be created with this PartyPlayer as its controls',
    );
    detach();
    if (session.ended) return;
    _session = session;
    _player = player;
    _episode = episode;
    _open = open;
    _refused = refused;
    _roomRateChanged = roomRateChanged;
    _ended = ended;
    _roomRate = rate;
    _lastPosition = player.state.position;
    player.intent = _intent;
    _subs.addAll([
      player.stream.playing.listen((_) => tick()),
      player.stream.buffering.listen((_) => tick()),
      player.stream.duration.listen((_) => tick()),
      player.stream.position.listen(_onPosition),
      session.changes.listen((_) {
        if (session.ended) _end();
      }),
    ]);
    session.start();
  }

  /// Lets go of the player: its presses act on it alone again, and the session's changes go nowhere.
  void detach() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    if (_player case final player? when player.intent == _intent) {
      player.intent = null;
    }
    _session = null;
    _player = null;
    _episode = null;
    _open = null;
    _refused = null;
    _roomRateChanged = null;
    _ended = null;
  }

  /// Sends what changed now rather than on the session's next tick: on an episode opening, say.
  void tick() {
    if (active) _session!.tick();
  }

  bool _intent(PartyOp op, {Duration? position, double? rate}) {
    final session = _session;
    if (session == null || session.ended) return true;
    final allowed = session.onLocalIntent(op, position: position, rate: rate);
    if (!allowed) {
      _refused?.call();
    } else {
      if (op == PartyOp.rate && rate != null) _setRoomRate(rate);
      // The player acts once this returns; the host's state goes out after that.
      scheduleMicrotask(tick);
    }
    return allowed;
  }

  /// Position events come steadily while playing; one that jumps is a seek or a stall worth telling the room.
  void _onPosition(Duration position) {
    final moved = position - _lastPosition;
    _lastPosition = position;
    if (moved < const Duration(milliseconds: -500) ||
        moved > const Duration(seconds: 2)) {
      tick();
    }
  }

  void _setRoomRate(double rate) {
    if (rate == _roomRate) return;
    _roomRate = rate;
    _roomRateChanged?.call(rate);
  }

  void _end() {
    final player = _player, ended = _ended;
    // A guest caught mid-nudge goes back to the room's speed.
    if (player != null && player.state.rate != _roomRate) {
      player.applyRate(_roomRate).ignore();
    }
    detach();
    ended?.call();
  }

  // ───── PartyControls ─────

  @override
  Duration get position => _player?.state.position ?? Duration.zero;

  @override
  Duration get duration => _player?.state.duration ?? Duration.zero;

  @override
  bool get playing => _player?.state.playing ?? false;

  @override
  bool get buffering => _player?.state.buffering ?? true;

  @override
  double get rate => _player?.state.rate ?? 1;

  @override
  PartyEpisode? get episode => _episode?.call();

  @override
  void applyPlay() => _player?.applyPlay().ignore();

  @override
  void applyPause() => _player?.applyPause().ignore();

  @override
  void applySeek(Duration to) {
    _lastPosition = to;
    _player?.applySeek(to).ignore();
  }

  @override
  void applyRate(double rate) {
    if (_player == null) return;
    // The host's speeds are [partyRates]; a catching-up nudge (×0.95, ×1.05) never lands on one.
    if (partyRates.contains(rate)) _setRoomRate(rate);
    _player!.applyRate(rate).ignore();
  }

  @override
  void openEpisode(PartyEpisode episode, Duration at) =>
      _open?.call(episode, at);
}

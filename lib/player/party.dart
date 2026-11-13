part of '../player.dart';

/// The player's side of a watch party: "Watch together" starts one here mid-episode, or opens the party panel
/// while in one; a host is asked before leaving ends the room; a guest is told when the room ends and plays on.
extension _PlayerParty on _PlayerScreenState {
  /// Whether this player hosts a room still going: leaving it ends the room for everyone.
  bool get _hosting => _inParty && _party!.isHost;

  /// Everyone in the room, this player included; 0 outside one.
  int get _partyPeople => _inParty ? _partySession!.peers.length + 1 : 0;

  String get _partyLabel => _inParty
      ? 'Watch party · $_partyPeople ${_partyPeople == 1 ? 'person' : 'people'}'
      : 'Watch together';

  /// "Watch together" (phones and desktop): the people count on its icon while in a party. A show on neither
  /// AniList nor MyAnimeList can't be found by the others, so there it's off and says why.
  Widget _partyButton() {
    final open = _partyKey(episode.number) != null;
    return Badge(
      isLabelVisible: _inParty,
      label: Text('$_partyPeople'),
      offset: const Offset(-2, 2),
      child: IconButton(
        tooltip: open
            ? _partyLabel
            : 'Watch together needs a show on AniList or MyAnimeList',
        icon: Icon(_inParty ? Icons.groups_rounded : Icons.groups_outlined),
        onPressed: open ? _watchTogether : null,
      ),
    );
  }

  /// Shown over the video while the controls are hidden: still in a party, and with how many.
  Widget _partyIndicator() => Positioned(
    top: isTv ? 24 : 8,
    right: isTv ? tvMargin : 12,
    child: IgnorePointer(
      child: SafeArea(
        child: Semantics(
          label: _partyLabel,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .45),
              borderRadius: BorderRadius.circular(radiusLarge),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.groups_rounded,
                    size: 18,
                    color: Colors.white70,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$_partyPeople',
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  /// Opens the party panel, or outside a party starts one with this player as its host.
  Future<void> _watchTogether() async {
    if (_inParty) return _openPartyPanel();
    if (_partyKey(episode.number) == null || _partyStarting) return;
    _partyStarting = true;
    try {
      final name = await partyNickname();
      if (!mounted || _inParty) return;
      final link = PartyLink.open(PartyRoom.create(), host: true, name: name);
      _partyChanges?.cancel();
      _set(() {
        _partySession = link.session;
        _party = link.player;
        _partyLeaving = false;
      });
      _joinParty();
      Analytics.event('party_start');
    } finally {
      _partyStarting = false;
    }
    await _openPartyPanel();
  }

  Future<void> _openPartyPanel() async {
    final link = PartyLink.of(_partySession);
    if (link == null || !_inParty) return;
    _hideTimer?.cancel();
    await showPartyPanel(
      context,
      link,
      title: titleOf(widget.media),
      onLeave: () => _partyLeaving = true,
    );
    if (mounted) _scheduleHide();
  }

  /// The host's Back: ends the room for everyone once confirmed, then leaves the player.
  Future<void> _leaveHosting() async {
    if (!await confirmEndParty(context) || !mounted) return;
    _partyLeaving = true;
    await _partySession?.leave();
    if (mounted) Navigator.pop(context);
  }

  /// The room is over (the player is let go and plays on as it was): a guest whose host left is told so.
  void _partyEnded() {
    _partyChanges?.cancel();
    _partyChanges = null;
    _chatOpen = false;
    if (!mounted) return;
    _refresh();
    _hint(
      !_partyLeaving
          ? 'The party ended'
          : _partySession?.isHost ?? false
          ? 'You ended the party'
          : 'You left the party',
      icon: Icons.groups_outlined,
    );
  }
}

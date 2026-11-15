part of '../player.dart';

/// The party's chat in the player (see party_chat.dart), only while in a party: lines as bubbles and reactions
/// rising over the video, whether or not the controls show; on phones a chat button opening a bar that sits
/// just above the keyboard; on desktop a side panel beside the video; on TV a row of reactions the D-pad reaches
/// from the controls, and no text input.
extension _PlayerChat on _PlayerScreenState {
  /// Whether the chat bar (phones) or side panel (desktop) is open.
  bool get _chatShown => _chatOpen && _inParty && !isTv;

  /// Whether a text field has the keyboard, which the player's own keys then leave alone.
  bool get _typing {
    final context = FocusManager.instance.primaryFocus?.context;
    return context != null &&
        (context.widget is EditableText ||
            context.findAncestorStateOfType<EditableTextState>() != null);
  }

  /// Phones' Back closes the chat bar before it leaves the player.
  bool get _chatTakesBack => _chatShown && !isDesktop;

  Widget _chatButton() => IconButton(
    tooltip: _chatShown ? 'Close chat' : 'Chat',
    icon: Icon(
      _chatShown
          ? Icons.chat_bubble_rounded
          : Icons.chat_bubble_outline_rounded,
    ),
    onPressed: _toggleChat,
  );

  void _toggleChat() {
    final open = !_chatShown;
    _chatOpen = open;
    // The phone's bar is over the video: the controls make way for it.
    if (open && !isDesktop) controls = false;
    _refresh();
    // The keyboard is the player's again.
    if (!open && isDesktop) _keys.requestFocus();
  }

  /// Bubbles and reactions over the video, kept off the controls and the subtitles; null outside a party.
  Widget? _chatOverlay(Size size) {
    if (!_inParty) return null;
    final shown = controls && !locked;
    final pad = MediaQuery.paddingOf(context);
    final scale = isTv ? 1.4 : 1.0;
    // The subtitles' baseline, and two lines of them above it.
    final subtitleScale = isDesktop ? (size.height / 720).clamp(.8, 2.2) : 1.0;
    final subtitles =
        (_videoSubtitleBottom ?? Settings.subtitleAppearance.bottom) +
        Settings.subtitleAppearance.size * subtitleScale * 3;
    final controlsBottom = isTv
        ? 190.0
        : isDesktop
        ? _PlayerScreenState._deskBarHeight
        : 120.0;
    final clear = EdgeInsets.fromLTRB(
      (isTv ? tvMargin : 16) + pad.left,
      // Under the title bar (or TV's title card and reactions), or the party indicator.
      (shown ? (isTv ? 150.0 : 72.0) : (isTv ? 80.0 : 52.0)) + pad.top,
      (isTv ? tvMargin : 16) + pad.right,
      (shown && controlsBottom > subtitles ? controlsBottom : subtitles) +
          pad.bottom,
    );
    // A phone's play controls sit mid-screen, about 400 wide: bubbles keep to the side of them.
    final width = !isTv && !isDesktop && shown
        ? (size.width / 2 - 200 - clear.left - 8).clamp(120.0, 320.0)
        : (size.width * .4).clamp(0.0, 360 * scale);
    return Positioned.fill(
      key: const ValueKey('party-chat-overlay'), // ahead of the controls, which joining mustn't remount
      child: PartyChatOverlay(
        log: PartyChatLog.of(_partySession!),
        clear: clear,
        bubbleWidth: width,
        // Desktop's open panel already shows each line.
        bubbles: !(_chatShown && isDesktop),
        scale: scale,
      ),
    );
  }

  /// TV's reactions, top right with the controls, which the D-pad reaches from them; null outside a party.
  Widget? _tvReactions() {
    if (!isTv || !_inParty || locked) return null;
    return Positioned(
      key: const ValueKey('party-reactions'),
      top: 24,
      right: tvMargin,
      child: IgnorePointer(
        ignoring: !controls,
        child: ExcludeFocus(
          excluding: !controls,
          child: AnimatedOpacity(
            opacity: controls ? 1 : 0,
            duration: motionMs(context, 200),
            child: PartyReactions(size: 26, onReact: _react),
          ),
        ),
      ),
    );
  }

  void _react(String emoji) {
    _scheduleHide();
    if (sendPartyReaction(_partySession!, emoji) case final why?) {
      _hint(why, icon: Icons.hourglass_bottom_rounded);
    }
  }

  /// The phone's chat bar, just above the keyboard, and behind it a catch for taps on the video that put it away.
  List<Widget> _chatBar() {
    if (!_chatShown || isDesktop) return const [];
    // The Scaffold doesn't make room for the keyboard, so the video stays as it is behind it.
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return [
      Positioned.fill(
        key: const ValueKey('party-chat-catch'),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleChat,
        ),
      ),
      Positioned(
        key: const ValueKey('party-chat-bar'),
        left: 0,
        right: 0,
        bottom: keyboard,
        child: PartyChatBar(session: _partySession!, onClose: _toggleChat),
      ),
    ];
  }

  /// Desktop: [video] with the chat panel beside it while open. The video keeps its place in the tree either way,
  /// so opening the panel doesn't restart it.
  Widget _besideChat(Widget video) => Row(
    children: [
      Expanded(child: video),
      if (_chatShown)
        PartyChatPanel(
          session: _partySession!,
          onClose: _toggleChat,
          onEscape: () => _keys.requestFocus(),
        ),
    ],
  );
}

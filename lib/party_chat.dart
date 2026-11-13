/// A watch party's chat as people see it: the scrollback a session keeps, people muted on this device, the
/// bubbles and reactions over the video, and the ways to say something (a compact bar on phones, a side panel on
/// desktop, a row of reactions on TV, which has no text input).
///
/// Messages are plain text: they're shown with [Text] and never linkified or read as markup. Muting is local:
/// it hides a person's lines and reactions here and tells no one.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'party.dart';
import 'tv.dart';
import 'ui.dart';

// ───────────────────────────── the log ─────────────────────────────

/// A session's chat on this device: its last [keep] lines and who's muted. One per session, for the session's
/// life ([of]); it starts listening when first asked for, so ask as the session opens.
class PartyChatLog extends ChangeNotifier {
  PartyChatLog._(this.session) {
    session.chat.listen(_add); // until the session ends and closes it
  }

  static final _logs = Expando<PartyChatLog>('party chat');

  /// The log of [session], started on first use.
  static PartyChatLog of(PartySession session) =>
      _logs[session] ??= PartyChatLog._(session);

  /// Lines kept for the scrollback.
  static const keep = 200;

  final PartySession session;
  final _lines = <PartyChat>[];
  final _muted = <String>{};
  final _arrived = StreamController<PartyChat>.broadcast(sync: true);

  /// The scrollback, oldest first: lines (not reactions), without muted people's.
  List<PartyChat> get lines => [
    for (final line in _lines)
      if (!_muted.contains(line.peer)) line,
  ];

  /// Lines and reactions as they arrive, ours included, muted people's left out.
  Stream<PartyChat> get arrived => _arrived.stream;

  bool isMuted(String peer) => _muted.contains(peer);

  /// Hides (or shows again) [peer]'s lines and reactions on this device.
  void mute(String peer, bool muted) {
    if (peer == session.id) return;
    if (muted ? _muted.add(peer) : _muted.remove(peer)) notifyListeners();
  }

  /// Who said [line], as it's shown: "You" for ours, "Someone" for a peer without a name.
  String nameOf(PartyChat line) {
    if (line.peer == session.id) return 'You';
    final name = line.name.isNotEmpty
        ? line.name
        : session.peers[line.peer]?.name ?? '';
    return name.isEmpty ? 'Someone' : name;
  }

  void _add(PartyChat line) {
    if (!line.reaction) {
      _lines.add(line);
      if (_lines.length > keep) _lines.removeRange(0, _lines.length - keep);
    }
    if (_muted.contains(line.peer)) return;
    _arrived.add(line);
    if (!line.reaction) notifyListeners();
  }
}

/// Sends [text] to the room: null once it's gone, else why not, to show by the field ('' for nothing to send).
String? sendPartyChat(PartySession session, String text) {
  if (session.sendChat(text)) return null;
  final clean = text.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
  if (clean.isEmpty) return '';
  if (clean.runes.length > partyMaxChat) {
    return 'Messages can be up to $partyMaxChat characters';
  }
  if (session.ended) return 'The party has ended';
  return 'Slow down a little';
}

/// Sends a reaction: null once it's gone, else why not.
String? sendPartyReaction(PartySession session, String emoji) {
  if (session.react(emoji)) return null;
  return session.ended ? 'The party has ended' : 'Slow down a little';
}

/// What each reaction is called, for screen readers and tooltips.
const partyReactionNames = {
  '👍': 'Thumbs up',
  '😂': 'Laughing',
  '😮': 'Surprised',
  '😢': 'Sad',
  '❤️': 'Love',
  '🔥': 'Fire',
};

// ───────────────────────────── over the video ─────────────────────────────

/// Lines as short-lived bubbles (name and text, [bubbleFor] each, at most [maxBubbles], newest at the bottom) and
/// reactions rising and fading, over the video. Lays itself out inside [clear], which keeps it off the controls
/// and the subtitles; it never takes a touch or focus.
class PartyChatOverlay extends StatefulWidget {
  const PartyChatOverlay({
    super.key,
    required this.log,
    this.clear = EdgeInsets.zero,
    this.bubbleWidth = 320,
    this.bubbles = true,
    this.scale = 1,
  });

  final PartyChatLog log;

  /// Margins the bubbles and reactions stay inside.
  final EdgeInsets clear;

  /// The widest a bubble gets.
  final double bubbleWidth;

  /// Whether lines show as bubbles (reactions always float).
  final bool bubbles;

  /// Bigger on TV, read from across a room.
  final double scale;

  static const maxBubbles = 3, maxReactions = 12;
  static const bubbleFor = Duration(seconds: 6);

  @override
  State<PartyChatOverlay> createState() => _PartyChatOverlayState();
}

class _Bubble {
  _Bubble(this.line, this.name);
  final PartyChat line;
  final String name;
  bool leaving = false;
  Timer? fade, gone;
}

class _Floating {
  _Floating(this.emoji, this.controller, this.drift);
  final String emoji;
  final AnimationController controller;

  /// Sideways sway, -1 to 1.
  final double drift;
}

class _PartyChatOverlayState extends State<PartyChatOverlay>
    with TickerProviderStateMixin {
  StreamSubscription<PartyChat>? _sub;
  final _bubbles = <_Bubble>[];
  final _floating = <_Floating>[];
  final _random = Random();

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(PartyChatOverlay old) {
    super.didUpdateWidget(old);
    if (!identical(old.log, widget.log)) {
      old.log.removeListener(_muteChanged);
      _sub?.cancel();
      _listen();
    }
    if (!widget.bubbles && _bubbles.isNotEmpty) _clearBubbles();
  }

  void _listen() {
    _sub = widget.log.arrived.listen(_arrive);
    widget.log.addListener(_muteChanged);
  }

  void _arrive(PartyChat line) {
    if (!mounted) return;
    if (line.reaction) return _float(line.text);
    if (!widget.bubbles) return;
    final bubble = _Bubble(line, widget.log.nameOf(line));
    bubble.fade = Timer(PartyChatOverlay.bubbleFor - _fadeTime, () {
      if (mounted) setState(() => bubble.leaving = true);
    });
    bubble.gone = Timer(PartyChatOverlay.bubbleFor, () => _drop(bubble));
    setState(() {
      _bubbles.add(bubble);
      while (_bubbles.length > PartyChatOverlay.maxBubbles) {
        _cancel(_bubbles.removeAt(0));
      }
    });
  }

  static const _fadeTime = Duration(milliseconds: 300);

  void _float(String emoji) {
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    final floating = _Floating(emoji, controller, _random.nextDouble() * 2 - 1);
    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() => _floating.remove(floating));
        controller.dispose();
      }
    });
    setState(() {
      _floating.add(floating);
      while (_floating.length > PartyChatOverlay.maxReactions) {
        _floating.removeAt(0).controller.dispose();
      }
    });
    controller.forward();
  }

  /// A person muted: their bubbles go at once.
  void _muteChanged() {
    final muted = _bubbles
        .where((b) => widget.log.isMuted(b.line.peer))
        .toList();
    if (muted.isEmpty || !mounted) return;
    setState(() {
      for (final b in muted) {
        _cancel(b);
        _bubbles.remove(b);
      }
    });
  }

  void _drop(_Bubble bubble) {
    if (!mounted) return;
    setState(() => _bubbles.remove(bubble));
  }

  void _cancel(_Bubble bubble) {
    bubble.fade?.cancel();
    bubble.gone?.cancel();
  }

  void _clearBubbles() {
    for (final b in _bubbles) {
      _cancel(b);
    }
    _bubbles.clear();
  }

  @override
  void dispose() {
    _sub?.cancel();
    widget.log.removeListener(_muteChanged);
    _clearBubbles();
    for (final f in _floating) {
      f.controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = widget.scale;
    final clear = widget.clear;
    return IgnorePointer(
      child: ExcludeFocus(
        child: Stack(
          children: [
            Positioned(
              left: clear.left,
              top: clear.top,
              bottom: clear.bottom,
              width: widget.bubbleWidth,
              child: ClipRect(
                // Newest at the bottom; when they don't all fit, the oldest is cut off the top.
                child: SingleChildScrollView(
                  reverse: true,
                  physics: const NeverScrollableScrollPhysics(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final b in _bubbles)
                        AnimatedOpacity(
                          key: ObjectKey(b),
                          opacity: b.leaving ? 0 : 1,
                          duration: motionMs(context, _fadeTime.inMilliseconds),
                          child: _bubble(b, scale),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              right: clear.right,
              top: clear.top,
              bottom: clear.bottom,
              width: 96 * scale,
              child: LayoutBuilder(
                builder: (context, box) => Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (final f in _floating)
                      AnimatedBuilder(
                        key: ObjectKey(f),
                        animation: f.controller,
                        builder: (context, child) {
                          final t = Curves.easeOut.transform(
                            f.controller.value,
                          );
                          return Positioned(
                            bottom: t * box.maxHeight * .8,
                            left:
                                box.maxWidth / 2 -
                                24 * scale +
                                sin(f.controller.value * pi * 2) *
                                    12 *
                                    f.drift *
                                    scale,
                            child: Opacity(
                              opacity:
                                  (1 - f.controller.value * f.controller.value)
                                      .clamp(0.0, 1.0),
                              child: child,
                            ),
                          );
                        },
                        child: Semantics(
                          label: partyReactionNames[f.emoji],
                          child: Text(
                            f.emoji,
                            style: TextStyle(fontSize: 40 * scale, height: 1.2),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bubble(_Bubble b, double scale) => Padding(
    padding: EdgeInsets.only(top: 6 * scale),
    child: DecoratedBox(
      // Dark in every theme: it sits on the video, and its text is white.
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .62),
        borderRadius: BorderRadius.circular(radiusLarge),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 12 * scale,
          vertical: 6 * scale,
        ),
        child: Semantics(
          liveRegion: true,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${b.name}  ',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: scheme.primaryFixedDim,
                  ),
                ),
                TextSpan(text: b.line.text),
              ],
            ),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white,
              fontSize: 14 * scale,
              height: 1.3,
            ),
          ),
        ),
      ),
    ),
  );
}

// ───────────────────────────── saying something ─────────────────────────────

/// The reactions, as a row of buttons; [onReact] sends one. On TV each is a focusable circle the D-pad reaches.
class PartyReactions extends StatelessWidget {
  const PartyReactions({super.key, required this.onReact, this.size = 24});

  final void Function(String emoji) onReact;
  final double size;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final emoji in partyReactions)
        isTv
            ? _TvReaction(
                emoji: emoji,
                size: size,
                onPressed: () => onReact(emoji),
              )
            : IconButton(
                tooltip: partyReactionNames[emoji],
                visualDensity: VisualDensity.compact,
                onPressed: () => onReact(emoji),
                icon: Text(emoji, style: TextStyle(fontSize: size, height: 1)),
              ),
    ],
  );
}

class _TvReaction extends StatefulWidget {
  const _TvReaction({
    required this.emoji,
    required this.size,
    required this.onPressed,
  });

  final String emoji;
  final double size;
  final VoidCallback onPressed;

  @override
  State<_TvReaction> createState() => _TvReactionState();
}

class _TvReactionState extends State<_TvReaction> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Semantics(
      button: true,
      label: 'React ${partyReactionNames[widget.emoji]}',
      child: InkWell(
        customBorder: const CircleBorder(),
        focusColor: Colors.transparent,
        onTap: widget.onPressed,
        onFocusChange: (v) => setState(() => _focused = v),
        child: AnimatedScale(
          scale: _focused ? 1.15 : 1,
          duration: motionMs(context, 150),
          child: AnimatedContainer(
            duration: motionMs(context, 150),
            width: widget.size * 1.9,
            height: widget.size * 1.9,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _focused
                  ? scheme.surfaceContainerHigh
                  : Colors.black.withValues(alpha: .35),
              border: Border.all(
                color: _focused ? scheme.primary : Colors.transparent,
                width: 3,
              ),
            ),
            child: ExcludeSemantics(
              child: Text(
                widget.emoji,
                style: TextStyle(fontSize: widget.size, height: 1),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The reactions and a text field with send, sharing one line for what went wrong. Enter sends and keeps the
/// field focused; Esc calls [onEscape]. [stacked] puts the reactions above the field rather than beside it.
class PartyChatComposer extends StatefulWidget {
  const PartyChatComposer({
    super.key,
    required this.session,
    this.focusNode,
    this.autofocus = false,
    this.stacked = false,
    this.onEscape,
    this.trailing,
  });

  final PartySession session;
  final FocusNode? focusNode;
  final bool autofocus, stacked;
  final VoidCallback? onEscape;

  /// After the reactions in the top row when [stacked], else after the field (a close button, say).
  final Widget? trailing;

  @override
  State<PartyChatComposer> createState() => _PartyChatComposerState();
}

class _PartyChatComposerState extends State<PartyChatComposer> {
  final _text = TextEditingController();
  FocusNode? _ownFocus;
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());
  String? _problem;

  @override
  void initState() {
    super.initState();
    // Asked for rather than autofocus, which gives way to whatever already has focus (the player's keys).
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _ownFocus?.dispose();
    super.dispose();
  }

  void _send() {
    final why = sendPartyChat(widget.session, _text.text);
    setState(() {
      if (why == null) _text.clear();
      _problem = why == null || why.isEmpty ? null : why;
    });
    _focus.requestFocus();
  }

  void _react(String emoji) =>
      setState(() => _problem = sendPartyReaction(widget.session, emoji));

  @override
  Widget build(BuildContext context) {
    final field = Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape &&
            widget.onEscape != null) {
          widget.onEscape!();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: TextField(
        key: const ValueKey('party chat field'),
        controller: _text,
        focusNode: _focus,
        textInputAction: TextInputAction.send,
        textCapitalization: TextCapitalization.sentences,
        minLines: 1,
        maxLines: 1,
        // Typing stops at the limit; an emoji counts once here but may be two characters to the room.
        maxLength: partyMaxChat,
        decoration: InputDecoration(
          hintText: 'Say something',
          counterText: '',
          isDense: true,
          filled: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radiusLarge),
            borderSide: BorderSide.none,
          ),
          suffixIcon: IconButton(
            tooltip: 'Send',
            icon: const Icon(Icons.send_rounded),
            onPressed: _send,
          ),
        ),
        onChanged: (_) {
          if (_problem != null) setState(() => _problem = null);
        },
        onSubmitted: (_) => _send(),
        onEditingComplete: () {}, // keeps the keyboard up for the next line
      ),
    );
    final reactions = PartyReactions(onReact: _react);
    final problem = _problem == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 4, left: 12),
            child: Text(
              _problem!,
              key: const ValueKey('party chat problem'),
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.error),
            ),
          );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: widget.stacked
          ? [
              Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: reactions,
                    ),
                  ),
                  ?widget.trailing,
                ],
              ),
              const SizedBox(height: 4),
              field,
              ?problem,
            ]
          : [
              Row(
                children: [
                  reactions,
                  const SizedBox(width: 8),
                  Expanded(child: field),
                  ?widget.trailing,
                ],
              ),
              ?problem,
            ],
    );
  }
}

/// The phone's compact chat: reactions and a field in a bar, for the player to keep just above the keyboard.
class PartyChatBar extends StatelessWidget {
  const PartyChatBar({super.key, required this.session, required this.onClose});

  final PartySession session;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Material(
    color: scheme.surfaceContainerHigh,
    borderRadius: const BorderRadius.vertical(
      top: Radius.circular(radiusLarge),
    ),
    child: SafeArea(
      top: false,
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
        child: LayoutBuilder(
          builder: (context, box) => PartyChatComposer(
            session: session,
            autofocus: true,
            stacked: box.maxWidth < 640,
            trailing: IconButton(
              tooltip: 'Close chat',
              icon: const Icon(Icons.close_rounded),
              onPressed: onClose,
            ),
          ),
        ),
      ),
    ),
  );
}

/// The lines kept, newest at the bottom; plain text, the sender's name first.
class PartyChatScrollback extends StatelessWidget {
  const PartyChatScrollback({
    super.key,
    required this.log,
    this.shrinkWrap = false,
  });

  final PartyChatLog log;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: log,
    builder: (context, _) {
      final lines = log.lines;
      final text = Theme.of(context).textTheme;
      if (lines.isEmpty) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            'No messages yet',
            textAlign: shrinkWrap ? TextAlign.start : TextAlign.center,
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        );
      }
      return ListView.builder(
        key: const ValueKey('party chat scrollback'),
        reverse: true, // sticks to the newest
        shrinkWrap: shrinkWrap,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: lines.length,
        itemBuilder: (context, i) {
          final line = lines[lines.length - 1 - i];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${log.nameOf(line)}  ',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                  TextSpan(text: line.text),
                ],
              ),
              style: text.bodyMedium,
            ),
          );
        },
      );
    },
  );
}

/// Desktop's chat beside the video: the scrollback, the reactions and the field.
class PartyChatPanel extends StatelessWidget {
  const PartyChatPanel({
    super.key,
    required this.session,
    required this.onClose,
    this.focusNode,
    this.onEscape,
  });

  final PartySession session;
  final VoidCallback onClose;
  final FocusNode? focusNode;
  final VoidCallback? onEscape;

  static const width = 340.0;

  @override
  Widget build(BuildContext context) => Material(
    color: scheme.surfaceContainerLow,
    child: SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Chat',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Close chat',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: PartyChatScrollback(log: PartyChatLog.of(session)),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
            child: PartyChatComposer(
              session: session,
              focusNode: focusNode,
              autofocus: true,
              stacked: true,
              onEscape: onEscape,
            ),
          ),
        ],
      ),
    ),
  );
}

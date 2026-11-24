/// The watch party as people see it: starting a room's session, the party panel the player opens, the join
/// dialog, and `aniview://party/<code>` links.
///
/// Nothing here logs, reports or sends a room's code, the stream or the install's id: the code only goes to the
/// clipboard when the person copies an invite.
library;

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pairing.dart' show TvRemote;
import 'party.dart';
import 'party_chat.dart';
import 'party_player.dart';
import 'party_qr.dart';
import 'party_transport.dart';
import 'settings.dart';
import 'states.dart';
import 'tracker.dart';
import 'tv.dart';
import 'ui.dart';

// ───────────────────────────── a room ─────────────────────────────

/// What a room's session talks through: its [transport], how many relays [usable]ly carry it (0 while
/// connecting), and the peer id the transport binds messages to (null to let the session pick one).
typedef PartyLine = ({
  PartyTransport transport,
  ValueListenable<int> usable,
  String? peerId,
});

/// Connects to [room] through [relays]; replaced in tests, which never reach the network.
@visibleForTesting
PartyLine Function(PartyRoom room, List<String> relays) partyConnect =
    (room, relays) {
      final transport = NostrTransport(room, relays: relays);
      return (
        transport: transport,
        usable: transport.usable,
        peerId: transport.peerId,
      );
    };

/// The clock rooms' sessions keep time by (ms since the epoch); null for the system's. Replaced in tests, whose
/// time is fake.
@visibleForTesting
int Function()? partyClock;

/// The relays parties go through: the ones set in Settings, else the defaults.
List<String> partyRelays() => Settings.partyRelays.isEmpty
    ? NostrTransport.defaultRelays
    : Settings.partyRelays;

/// Why [url] can't be added to [relays] as a relay, or null when it can.
String? relayProblem(String url, List<String> relays) {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.scheme != 'wss' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      url.contains(RegExp(r'\s'))) {
    return 'Enter a relay address starting wss://';
  }
  if (relays.contains(url)) return 'That relay is already on the list';
  return null;
}

/// The name to join as: the one set in Settings, else the signed-in AniList or MyAnimeList name; empty without
/// either.
Future<String> partyNickname() async {
  if (Settings.partyName.isNotEmpty) return clampPartyName(Settings.partyName);
  try {
    final name = (await Tracker.viewer())?['name'];
    if (name is String) return clampPartyName(name);
  } catch (_) {} // offline: no name rather than no party
  return '';
}

/// A room this app is in: its [room] code, its [session] and its connection's [usable] relays.
class PartyLink {
  PartyLink._(this.room, this.session, this.usable);

  final PartyRoom room;
  final PartySession session;
  final ValueListenable<int> usable;

  static final _links = Expando<PartyLink>('party link');

  /// The room [session] was opened for here, if it was.
  static PartyLink? of(PartySession? session) =>
      session == null ? null : _links[session];

  /// Opens [room] (a new one to host, or one to join) as [name], with the player still to attach: see
  /// [PartyPlayer].
  factory PartyLink.open(
    PartyRoom room, {
    required bool host,
    required String name,
  }) {
    final line = partyConnect(room, partyRelays());
    final session = PartySession(
      transport: line.transport,
      controls: PartyPlayer(),
      isHost: host,
      name: name,
      id: line.peerId,
      clock: partyClock,
    );
    PartyChatLog.of(session); // the scrollback starts with the room
    return _links[session] = PartyLink._(room, session, line.usable);
  }

  PartyPlayer get player => session.controls as PartyPlayer;
}

/// A room joined from Home on its way to a player: the room and the host's episode number.
typedef PartyJoin = ({PartyLink link, num episode});

/// What a friend is sent: the show, the code, and the link that opens AniView on it.
String partyInvite(PartyRoom room, String title) =>
    'Watch $title with me on AniView. Party code ${room.display} · ${room.link}';

// ───────────────────────────── links ─────────────────────────────

/// The room an `aniview://party/<code>` link names, or null for any other link (a sign-in's way back, say).
PartyRoom? partyRoomOf(Uri uri) =>
    uri.scheme.toLowerCase() == 'aniview' && uri.host.toLowerCase() == 'party'
    ? PartyRoom.parse('aniview://party${uri.path}')
    : null;

/// Where `aniview://` links arrive; replaced in tests.
@visibleForTesting
Stream<Uri> Function() appLinks = () => AppLinks().uriLinkStream;

/// The room of the latest `aniview://party/<code>` link the app was opened with, until Home takes it (and sets
/// it back to null) to open the join dialog.
final partyLinkArrived = ValueNotifier<PartyRoom?>(null);

/// Feeds [partyLinkArrived] from the links the app is opened with, the one it was launched with included. Other
/// `aniview://` links (sign-in redirects) are left to whoever waits for them. Started once, at launch.
StreamSubscription<Uri>? listenForPartyLinks() {
  try {
    return appLinks().listen((uri) {
      if (partyRoomOf(uri) case final room?) {
        partyLinkArrived.value = null; // the same link again still opens it
        partyLinkArrived.value = room;
      }
    }, onError: (Object _) {});
  } catch (_) {
    return null; // no link handling on this platform
  }
}

// ───────────────────────────── status ─────────────────────────────

/// "Connecting…", "Connected", or after [patience] with no relay carrying the room, "Can't reach the party
/// servers".
class PartyStatus extends StatefulWidget {
  const PartyStatus(
    this.usable, {
    super.key,
    this.patience = const Duration(seconds: 10),
  });

  final ValueListenable<int> usable;
  final Duration patience;

  @override
  State<PartyStatus> createState() => _PartyStatusState();
}

class _PartyStatusState extends State<PartyStatus> {
  Timer? _wait;
  bool _stuck = false;

  @override
  void initState() {
    super.initState();
    widget.usable.addListener(_changed);
    _changed();
  }

  void _changed() {
    if (widget.usable.value > 0) {
      _wait?.cancel();
      _wait = null;
      if (_stuck) setState(() => _stuck = false);
    } else if (_wait == null && !_stuck) {
      _wait = Timer(widget.patience, () {
        if (mounted) setState(() => _stuck = true);
      });
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.usable.removeListener(_changed);
    _wait?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = widget.usable.value > 0;
    final (icon, text, color) = connected
        ? (Icons.wifi_rounded, 'Connected', scheme.primary)
        : _stuck
        ? (
            Icons.wifi_off_rounded,
            'Can\'t reach the party servers',
            scheme.error,
          )
        : (Icons.wifi_find_rounded, 'Connecting…', scheme.onSurfaceVariant);
    return Semantics(
      liveRegion: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────── the panel ─────────────────────────────

/// Asks the host before ending the room for everyone; true to end it.
Future<bool> confirmEndParty(BuildContext context) => confirmDestructive(
  context,
  title: 'End the party?',
  message: 'Everyone in it stops watching together.',
  action: 'End party',
);

/// The party panel: a sheet on phones, a dialog on TV and desktop. Closes by itself when the room ends.
Future<void> showPartyPanel(
  BuildContext context,
  PartyLink link, {
  required String title,
  VoidCallback? onLeave,
}) => showSheet<void>(
  context,
  scrollControlled: true,
  (context) => PartyPanel(link: link, title: title, onLeave: onLeave),
);

/// The room's code to share, whether it's connected, who's in it, the host's control switch, the length
/// mismatch nudge and the way out.
class PartyPanel extends StatefulWidget {
  const PartyPanel({
    super.key,
    required this.link,
    required this.title,
    this.onLeave,
  });

  final PartyLink link;

  /// Called as the person leaves (or, hosting, ends) the room from here.
  final VoidCallback? onLeave;

  /// The show's title, for the invite.
  final String title;

  @override
  State<PartyPanel> createState() => _PartyPanelState();
}

class _PartyPanelState extends State<PartyPanel> {
  StreamSubscription<void>? _changes;
  bool _copied = false;
  Timer? _copiedTimer;

  /// "Bring the TV in": sending, and what came of it.
  bool _bringing = false;
  String? _tvNote;

  PartySession get session => widget.link.session;
  PartyChatLog get chat => PartyChatLog.of(session);

  @override
  void initState() {
    super.initState();
    _changes = session.changes.listen((_) => _update(), onDone: _update);
  }

  void _update() {
    if (!mounted) return;
    if (session.ended) {
      Navigator.maybePop(context);
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _changes?.cancel();
    _copiedTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(
      ClipboardData(text: partyInvite(widget.link.room, widget.title)),
    );
    if (!mounted) return;
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  /// Has the paired TV open the join dialog with this room's code.
  Future<void> _bringTv() async {
    setState(() {
      _bringing = true;
      _tvNote = null;
    });
    String note;
    try {
      await TvRemote.joinParty(widget.link.room);
      note = 'Sent. Press Join on ${TvRemote.name ?? 'the TV'}';
    } catch (e) {
      note = friendlyError(e);
    }
    if (!mounted) return;
    setState(() {
      _bringing = false;
      _tvNote = note;
    });
  }

  Future<void> _leave() async {
    if (session.isHost && !await confirmEndParty(context)) return;
    widget.onLeave?.call();
    session.leave().ignore(); // ends at once; the goodbye goes out behind the screen closing
    if (mounted) Navigator.maybePop(context);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final mismatch = session.durationMismatch;
    final people = [
      (id: session.id, name: session.name, host: session.isHost, you: true),
      for (final p in session.peers.values)
        (id: p.id, name: p.name, host: p.host, you: false),
    ];
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Watch party', style: text.titleLarge),
            const SizedBox(height: 4),
            Text(
              session.isHost
                  ? 'Friends join with this code, from Join a party in AniView'
                  : 'Invite others with this code',
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                // Big enough on TV for a phone's camera across the room.
                PartyQr(
                  widget.link.room.link,
                  key: const ValueKey('party qr'),
                  size: isTv ? 200 : 136,
                  label: 'QR code of the party link',
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SelectableText(
                        widget.link.room.display,
                        key: const ValueKey('party code'),
                        textAlign: TextAlign.center,
                        style: text.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          letterSpacing: 2,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Or scan it with a phone\'s camera',
                        textAlign: TextAlign.center,
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.tonalIcon(
                        autofocus: isTv,
                        onPressed: _copy,
                        icon: Icon(
                          _copied ? Icons.check_rounded : Icons.copy_rounded,
                        ),
                        label: Text(_copied ? 'Copied' : 'Copy invite'),
                      ),
                      // A phone paired with a TV can have the TV join too.
                      if (!isTv && TvRemote.name != null) ...[
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _bringing ? null : _bringTv,
                          icon: const Icon(Icons.tv_rounded),
                          label: const Text('Bring the TV in'),
                        ),
                        if (_tvNote case final note?)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              note,
                              textAlign: TextAlign.center,
                              style: text.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Center(child: PartyStatus(widget.link.usable)),
            if (!session.isHost && session.hostSilent) ...[
              const SizedBox(height: 8),
              Center(
                child: Text(
                  'Waiting for the host…',
                  style: text.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              people.length == 1 ? 'Just you so far' : '${people.length} here',
              style: text.titleSmall?.copyWith(color: scheme.primary),
            ),
            for (final p in people)
              Builder(
                builder: (context) {
                  final muted = !p.you && chat.isMuted(p.id);
                  final name = p.name.isNotEmpty ? p.name : 'Someone';
                  final notes = [if (p.host) 'Host', if (muted) 'Muted here'];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    // Read out on TV as focus moves down the panel.
                    focusColor: scheme.onSurface.withValues(alpha: .08),
                    onTap: isTv ? () {} : null,
                    leading: Icon(
                      p.host
                          ? Icons.star_rounded
                          : Icons.person_outline_rounded,
                      color: p.host ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                    title: Text([name, if (p.you) '(you)'].join(' ')),
                    subtitle: notes.isEmpty ? null : Text(notes.join(' · ')),
                    // Hides their lines and reactions on this device only.
                    trailing: p.you
                        ? null
                        : IconButton(
                            tooltip: muted
                                ? 'Show $name\'s messages'
                                : 'Mute $name\'s messages',
                            icon: Icon(
                              muted
                                  ? Icons.comments_disabled_outlined
                                  : Icons.chat_bubble_outline_rounded,
                            ),
                            onPressed: () =>
                                setState(() => chat.mute(p.id, !muted)),
                          ),
                  );
                },
              ),
            if (session.isHost)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Only I can control'),
                subtitle: const Text('Others can\'t play, pause or seek'),
                value: session.hostOnly,
                onChanged: (v) => setState(() => session.hostOnly = v),
              )
            else if (session.hostOnly)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Only the host can control playback',
                  style: text.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (mismatch != null) ...[
              const SizedBox(height: 8),
              Text(
                'Your version is ${mismatch.abs().round()} s '
                '${mismatch > 0 ? 'shorter' : 'longer'} than the host\'s. '
                'Nudge it until you\'re in step.',
                style: text.bodyMedium,
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton(
                    onPressed: () => setState(() => session.nudge(-1)),
                    child: const Text('−1 s'),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      '${session.cutOffset >= 0 ? '+' : '−'}'
                      '${session.cutOffset.abs().round()} s',
                      style: text.titleMedium,
                    ),
                  ),
                  OutlinedButton(
                    onPressed: () => setState(() => session.nudge(1)),
                    child: const Text('+1 s'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Text(
              'Chat',
              style: text.titleSmall?.copyWith(color: scheme.primary),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: isTv ? 160 : 200),
              child: PartyChatScrollback(log: chat, shrinkWrap: true),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                style: destructiveButton,
                onPressed: _leave,
                icon: const Icon(Icons.logout_rounded),
                label: Text(session.isHost ? 'End party' : 'Leave party'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────────── joining ─────────────────────────────

/// Joins a room: asks for its code (with [code] filled in, from a link) and a name, connects, and once the
/// host's state says what's playing hands the room and the host's show and episode to [land], which opens the
/// player there as a guest. [land] gets the show's AniList id; it must leave the room when it can't open it.
Future<void> joinParty(
  BuildContext context, {
  String? code,
  required Future<void> Function(PartyLink link, int anilistId, num episode)
  land,
}) async {
  final name = await partyNickname();
  if (!context.mounted) return;
  final joined = await showDialog<(PartyLink, int, num)>(
    context: context,
    barrierDismissible: false,
    builder: (_) => JoinPartyDialog(code: code, name: name),
  );
  if (joined == null) return;
  final (link, id, episode) = joined;
  await land(link, id, episode);
}

/// How long a guest waits to hear from the host before giving up.
const partyJoinPatience = Duration(seconds: 20);

/// The join dialog: the code and a name, then progress until the host's episode is known. Pops with the room,
/// the show's AniList id and the episode, or null when cancelled.
class JoinPartyDialog extends StatefulWidget {
  const JoinPartyDialog({super.key, this.code, this.name = ''});

  final String? code;
  final String name;

  @override
  State<JoinPartyDialog> createState() => _JoinPartyDialogState();
}

class _JoinPartyDialogState extends State<JoinPartyDialog> {
  late final _code = TextEditingController(text: widget.code ?? '');
  late final _name = TextEditingController(text: widget.name);
  final _join = FocusNode();
  String? _codeError, _failed;

  /// The room being joined, while waiting for its host.
  PartyLink? _link;
  Timer? _poll, _giveUp;
  bool _finding = false;

  @override
  void initState() {
    super.initState();
    // A link filled the code in: OK joins.
    if (widget.code != null && isTv) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _join.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _stopWaiting();
    _code.dispose();
    _name.dispose();
    _join.dispose();
    super.dispose();
  }

  void _stopWaiting() {
    _poll?.cancel();
    _giveUp?.cancel();
    _poll = _giveUp = null;
  }

  void _start() {
    final room = PartyRoom.parse(_code.text);
    if (room == null) {
      setState(
        () => _codeError =
            'That isn\'t a party code. It looks like K7QM-2XVD-9RTA',
      );
      return;
    }
    final name = clampPartyName(_name.text);
    if (name != clampPartyName(widget.name)) Settings.partyName = name;
    final link = PartyLink.open(room, host: false, name: name);
    link.player.startEarly(link.session);
    setState(() {
      _codeError = _failed = null;
      _link = link;
    });
    _poll = Timer.periodic(const Duration(milliseconds: 200), (_) => _check());
    _giveUp = Timer(partyJoinPatience, () {
      _fail(
        'Couldn\'t find that party. Check the code, and that the host is '
        'still watching.',
      );
    });
  }

  Future<void> _check() async {
    final link = _link;
    if (link == null || _finding) return;
    if (link.session.ended) {
      return _fail('That party has ended.');
    }
    final episode = link.session.hostEpisode;
    if (episode == null) return;
    _stopWaiting();
    setState(() => _finding = true);
    final id = await _anilistId(episode);
    if (!mounted) return;
    if (id == null) {
      return _fail(
        'Couldn\'t find the show the party is watching, so you can\'t join.',
      );
    }
    _link = null; // handed on
    Navigator.pop(context, (link, id, episode.number));
  }

  /// The show's AniList id: the host's, else the one its MyAnimeList id maps to.
  static Future<int?> _anilistId(PartyEpisode episode) async {
    if (episode.anilist case final id?) return id;
    final show = <String, Object?>{'idMal': episode.mal};
    await Tracker.resolveIds(show);
    return show['id'] is int ? show['id'] as int : null;
  }

  void _fail(String why) {
    _stopWaiting();
    _link?.session.leave().ignore();
    if (!mounted) return;
    setState(() {
      _link = null;
      _finding = false;
      _failed = why;
    });
  }

  void _cancel() {
    _stopWaiting();
    _link?.session.leave().ignore();
    _link = null;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final link = _link;
    final text = Theme.of(context).textTheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: PanelDialog(
        title: const Text('Join a party'),
        content: link == null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const ValueKey('party code field'),
                    controller: _code,
                    autofocus: widget.code == null,
                    textCapitalization: TextCapitalization.characters,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: 'Party code or link',
                      hintText: 'K7QM-2XVD-9RTA',
                      errorText: _codeError,
                      errorMaxLines: 2,
                    ),
                    onChanged: (_) {
                      if (_codeError != null) {
                        setState(() => _codeError = null);
                      }
                    },
                    onSubmitted: (_) => _start(),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const ValueKey('party name field'),
                    controller: _name,
                    maxLength: partyNameLength,
                    decoration: const InputDecoration(
                      labelText: 'Your name',
                      helperText: 'What the others in the party see',
                    ),
                    onSubmitted: (_) => _start(),
                  ),
                  if (_failed != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _failed!,
                      style: text.bodyMedium?.copyWith(color: scheme.error),
                    ),
                  ],
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const LinearProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    _finding
                        ? 'Opening what the party is watching…'
                        : 'Waiting for the host…',
                    style: text.bodyLarge,
                  ),
                  const SizedBox(height: 8),
                  PartyStatus(link.usable),
                ],
              ),
        actions: [
          TextButton(onPressed: _cancel, child: const Text('Cancel')),
          if (link == null)
            FilledButton(
              focusNode: _join,
              onPressed: _start,
              child: const Text('Join'),
            ),
        ],
      ),
    );
  }
}

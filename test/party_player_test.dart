import 'dart:convert';

import 'package:aniview/exo.dart';
import 'package:aniview/metadata.dart';
import 'package:aniview/party.dart';
import 'package:aniview/party_player.dart';
import 'package:aniview/player.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A player that plays as told: it opens playing, moves on while playing when [advance]d, and records what it was
/// asked to do.
class Backend extends PlayerBackend {
  late void Function(Map) emit;
  final calls = <String>[];
  int position = 0;
  bool playing = false;
  double rate = 1;
  static const duration = 1440000;

  void _position() =>
      emit({'position': position, 'buffer': position, 'duration': duration});

  void advance(int ms) {
    if (!playing) return;
    position = (position + ms * rate).round().clamp(0, duration);
    _position();
  }

  @override
  Future<void> start(void Function(Map) on) async => emit = on;

  @override
  Future<void> call(String method, Map<String, Object?> args) async {
    switch (method) {
      case 'open':
        calls.add('open ${args['url']} ${args['start']}');
        position = args['start']! as int;
        playing = true;
        _position();
        emit({'playing': true, 'buffering': false});
      case 'play':
        calls.add('play');
        playing = true;
        emit({'playing': true});
      case 'pause':
        calls.add('pause');
        playing = false;
        emit({'playing': false});
      case 'seek':
        calls.add('seek ${args['ms']}');
        position = args['ms']! as int;
        _position();
      case 'rate':
        calls.add('rate ${args['rate']}');
        rate = args['rate']! as double;
    }
  }

  @override
  Future<void> setVolume(double level) async {}
  @override
  Future<void> dispose() async {}
}

/// Serves every episode as one file, with [skips] for its intro.
class Site extends Source {
  Site(String name, {this.skips = const []})
    : super(name, 'https://$name.test');
  final List<SkipTime> skips;
  final requested = <num>[];
  @override
  Future<String?> match(Map media) async => 'show';
  @override
  Future<List<Episode>> episodesOf(String id) async => episodes;
  @override
  Future<List<SearchResult>> search(String query) async => [];
  @override
  Future<List<VideoStream>> streams(
    Map media,
    Episode episode, {
    required bool dub,
  }) async {
    requested.add(episode.number);
    return [
      VideoStream(
        'Server',
        'https://$name.test/${episode.number}.mp4',
        {},
        skips: skips,
      ),
    ];
  }
}

final episodes = [Episode(1, ref: '1'), Episode(2, ref: '2')];

/// AniList id only: a MyAnimeList id would send the player to AniSkip.
final media = {
  'id': 4242,
  'title': {'romaji': 'Party'},
};

/// A host and a guest, each a [PlayerScreen] on its own fake player, in one room on a loopback hub with one clock.
class Room {
  Room(this.tester);
  final WidgetTester tester;
  int now = 1000000;
  final hub = LoopbackHub();
  late final PartySession host = _session(true), guest = _session(false);
  final hostBackend = Backend(), guestBackend = Backend();
  final hostSite = Site('host');

  /// The guest's site marks 10–100 s as the intro, which the guest mustn't skip by itself.
  final guestSite = Site(
    'guest',
    skips: const [
      SkipTime(SkipType.intro, Duration(seconds: 10), Duration(seconds: 100)),
    ],
  );

  PartySession _session(bool isHost) => PartySession(
    transport: hub.join(),
    controls: PartyPlayer(),
    isHost: isHost,
    name: isHost ? 'host' : 'guest',
    clock: () => now,
    tickEvery: null,
  );

  ExoPlayer get hostPlayer => (host.controls as PartyPlayer).player!;
  ExoPlayer get guestPlayer => (guest.controls as PartyPlayer).player!;

  Finder get guestScreen => find.byKey(const ValueKey('guest'));

  /// The message types the guest has sent.
  List<String> get guestSent => [
    for (final (from, m) in hub.sent)
      if (identical(from, guest.transport))
        (jsonDecode(m) as Map)['t'] as String,
  ];

  Future<void> open() async {
    SharedPreferences.setMockInitialValues({
      'resume': false,
      'auto_next': true,
      'skip_mode': 'auto',
    });
    await Settings.load();
    final previous = configureQuality;
    configureQuality = (_, _) async => const [];
    addTearDown(() => configureQuality = previous);
    tester.view.physicalSize = const Size(2400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget screen(String key, PartySession party, Site site, Backend b) =>
        Expanded(
          child: PlayerScreen(
            key: ValueKey(key),
            media: media,
            source: site,
            episodes: episodes,
            index: 0,
            dub: false,
            backend: b,
            party: party,
          ),
        );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Row(
          children: [
            screen('host', host, hostSite, hostBackend),
            screen('guest', guest, guestSite, guestBackend),
          ],
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Moves time on by [ms]: the players play on, the sessions tick and every message is delivered.
  Future<void> step([int ms = 250]) async {
    now += ms;
    hostBackend.advance(ms);
    guestBackend.advance(ms);
    await tester.pump(Duration(milliseconds: ms));
    host.tick();
    guest.tick();
    for (var i = 0; i < 3; i++) {
      hub.settle();
      await tester.pump();
    }
  }

  Future<void> steps(int n, [int ms = 250]) async {
    for (var i = 0; i < n; i++) {
      await step(ms);
    }
  }

  Future<void> close() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  }
}

void main() {
  testWidgets(
    'a guest plays in step with the host, and its presses go to the host',
    (tester) async {
      final room = Room(tester);
      await room.open();
      expect(room.hostSite.requested, [1]);
      expect(room.guestSite.requested, [1]);

      // Twelve seconds in: the guest is inside its site's intro, which it leaves to the host.
      await room.steps(48);
      expect(room.guestBackend.position, greaterThan(10000));
      expect(room.guestBackend.calls, isNot(contains('seek 100000')));
      expect(
        find.descendant(
          of: room.guestScreen,
          matching: find.text('Skipped Intro'),
        ),
        findsNothing,
      );

      // The host pauses, seeks and changes speed; the guest's player follows.
      room.guestBackend.calls.clear();
      room.hostPlayer.pause();
      await room.steps(2);
      expect(room.guestBackend.calls, contains('pause'));
      expect(room.guestBackend.playing, isFalse);

      room.hostPlayer.seek(const Duration(minutes: 10));
      await room.steps(2);
      expect(room.guestBackend.calls, contains('seek 600000'));

      // A guest holds corrections other than play/pause for 2 s after a seek.
      room.hostPlayer.setRate(1.5);
      await room.steps(10);
      expect(room.guestBackend.calls, contains('rate 1.5'));

      room.hostPlayer.play();
      await room.steps(4);
      expect(room.guestBackend.playing, isTrue);

      // Nothing the guest was told to do went back out as a request.
      expect(room.guestSent, isNot(contains('ctl')));

      // A guest a little behind is nudged faster, but shows the room's speed.
      room.guestBackend.position -= 1000;
      await room.step();
      expect(room.guestBackend.rate, closeTo(1.575, 1e-9));
      expect(room.guestPlayer.state.rate, closeTo(1.575, 1e-9));
      expect(
        find.descendant(of: room.guestScreen, matching: find.text('1.5×')),
        findsWidgets,
      );

      // The guest's own pause goes to the host, once.
      room.hostBackend.calls.clear();
      room.guestPlayer.pause();
      await room.steps(2);
      expect(room.guestSent.where((t) => t == 'ctl'), hasLength(1));
      expect(room.hostBackend.calls, contains('pause'));
      expect(room.guestBackend.playing, isFalse);
      await room.steps(12);
      expect(room.guestSent.where((t) => t == 'ctl'), hasLength(1));

      // Host-only control: the guest's press is refused, said so, and goes nowhere.
      room.host.hostOnly = true;
      await room.steps(2);
      expect(room.guest.hostOnly, isTrue);
      room.guestBackend.calls.clear();
      room.hostBackend.calls.clear();
      room.guestPlayer.seek(const Duration(minutes: 2));
      room.guestPlayer.play();
      await room.steps(2);
      expect(room.guestBackend.calls, isEmpty);
      expect(room.hostBackend.calls, isEmpty);
      expect(room.guestSent.where((t) => t == 'ctl'), hasLength(1));
      expect(
        find.descendant(
          of: room.guestScreen,
          matching: find.text('Only the host can control playback'),
        ),
        findsOneWidget,
      );

      // The same from the screen, where the seek's own "+10s" mustn't cover the refusal.
      await tester.pump(const Duration(seconds: 2)); // the hint goes
      await tester.tapAt(
        tester.getTopLeft(room.guestScreen) + const Offset(100, 300),
      );
      await tester.pump(const Duration(milliseconds: 400)); // controls up
      await tester.tap(
        find.descendant(
          of: room.guestScreen,
          matching: find.byTooltip('Forward ${Settings.seekSeconds}s'),
        ),
      );
      await tester.pump();
      expect(
        find.descendant(
          of: room.guestScreen,
          matching: find.text('Only the host can control playback'),
        ),
        findsOneWidget,
      );
      expect(find.text('+${Settings.seekSeconds}s'), findsNothing);
      expect(room.guestBackend.calls, isEmpty);

      // The guest's episode ending doesn't move it on; the host's does, and the guest follows.
      room.guestBackend.emit({'completed': true});
      await room.steps(2);
      expect(room.guestSite.requested, [1]);
      expect(find.text('The host picks the episode'), findsNothing);
      room.hostBackend.emit({'completed': true});
      await room.steps(8);
      expect(room.hostSite.requested, [1, 2]);
      expect(room.guestSite.requested, [1, 2]);
      expect(room.guestBackend.calls.where((c) => c.startsWith('open ')), [
        'open https://guest.test/2.mp4 0',
      ]);
      expect(room.guestSent.where((t) => t == 'ctl'), hasLength(1));

      await room.close();
    },
  );

  testWidgets(
    'a menu open doesn\'t pause the room, and the speed picked there reaches the guest',
    (tester) async {
      final room = Room(tester);
      await room.open();
      // Past the guest's settling seek, which holds its speed corrections for 2 s.
      await room.steps(16);
      room.hostBackend.calls.clear();
      room.guestBackend.calls.clear();
      final hostScreen = find.byKey(const ValueKey('host'));
      // The controls hid while it played. Holding the picture doesn't play at 2× in a party: it's a tap, which
      // brings them up.
      await tester.longPressAt(
        tester.getTopLeft(hostScreen) + const Offset(100, 300),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(room.hostBackend.calls, isEmpty);
      await tester.tap(
        find.descendant(of: hostScreen, matching: find.text('1.0×')),
      );
      await tester.pumpAndSettle();
      expect(
        room.hostBackend.calls,
        isEmpty,
      ); // not paused while the sheet is up
      await tester.tap(find.text('1.5×').last);
      await tester.pumpAndSettle();
      expect(room.hostBackend.calls, ['rate 1.5']);
      await room.steps(4);
      expect(room.guestBackend.calls, contains('rate 1.5'));
      expect(room.guestBackend.calls, isNot(contains('pause')));
      expect(
        find.descendant(of: room.guestScreen, matching: find.text('1.5×')),
        findsWidgets,
      );
      await room.close();
    },
  );

  testWidgets(
    'when the host leaves, the guest plays on by itself at the room speed',
    (tester) async {
      final room = Room(tester);
      await room.open();
      await room.steps(24);
      room.guestBackend.position -= 1500; // behind: nudged to ×1.05
      await room.step();
      expect(room.guestBackend.rate, 1.05);
      final player = room.guestPlayer; // let go of once the room ends
      await room.host.leave();
      await room.steps(2);
      expect(room.guest.ended, isTrue);
      expect(room.guestBackend.rate, 1);
      expect(room.guestBackend.playing, isTrue);

      // Its presses are its own again.
      expect(player.intent, isNull);
      room.guestBackend.calls.clear();
      player.pause();
      player.seek(const Duration(minutes: 3));
      await room.steps(1);
      expect(room.guestBackend.calls, ['pause', 'seek 180000']);
      expect(room.guestSent.where((t) => t == 'ctl'), isEmpty);
      await room.close();
    },
  );

  testWidgets('without a party, play, pause and seek act as before', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'resume': false});
    await Settings.load();
    final previous = configureQuality;
    configureQuality = (_, _) async => const [];
    addTearDown(() => configureQuality = previous);
    final backend = Backend();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: PlayerScreen(
          media: media,
          source: Site('solo'),
          episodes: episodes,
          index: 0,
          dub: false,
          backend: backend,
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(backend.calls, ['open https://solo.test/1.mp4 0', 'rate 1.0']);
    backend.calls.clear();
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    expect(backend.calls, ['pause']);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    await tester.tap(find.byTooltip('Forward ${Settings.seekSeconds}s'));
    await tester.pump();
    expect(backend.calls, [
      'pause',
      'play',
      'seek ${Settings.seekSeconds * 1000}',
    ]);
    expect(find.text('+${Settings.seekSeconds}s'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });
}

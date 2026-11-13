import 'dart:async';

import 'package:aniview/anilist.dart';
import 'package:aniview/changelog.dart';
import 'package:aniview/details.dart';
import 'package:aniview/home.dart';
import 'package:aniview/party.dart';
import 'package:aniview/party_transport.dart';
import 'package:aniview/party_ui.dart';
import 'package:aniview/platform.dart';
import 'package:aniview/player.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:aniview/tracker.dart';
import 'package:aniview/tv.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'party_player_test.dart' show Backend, Site, episodes;

/// A peer's player as its session sees it, with no screen: on [episode], playing.
class FakeControls implements PartyControls {
  FakeControls([this.episode]);
  @override
  PartyEpisode? episode;
  @override
  Duration position = const Duration(seconds: 30);
  @override
  Duration duration = const Duration(minutes: 24);
  @override
  bool playing = true;
  @override
  bool buffering = false;
  @override
  double rate = 1;
  @override
  void applyPlay() => playing = true;
  @override
  void applyPause() => playing = false;
  @override
  void applySeek(Duration to) => position = to;
  @override
  void applyRate(double rate) => this.rate = rate;
  @override
  void openEpisode(PartyEpisode episode, Duration at) {}
}

/// Every room a test opens is on [hub], never the network; [rooms] are the codes asked for, in order.
class Rooms {
  Rooms() {
    final previous = partyConnect;
    partyConnect = (room, relays) {
      rooms.add(room);
      return (transport: hub.join(), usable: usable, peerId: null);
    };
    addTearDown(() => partyConnect = previous);
    // The test's fake time, which pumps move on.
    final binding = TestWidgetsFlutterBinding.instance;
    partyClock = () => binding.clock.now().millisecondsSinceEpoch;
    addTearDown(() => partyClock = null);
  }

  final hub = LoopbackHub();
  final rooms = <PartyRoom>[];
  final usable = ValueNotifier(1);

  /// Another peer in the room, ticked by hand.
  PartySession peer(String name, {bool host = false, PartyEpisode? on}) =>
      PartySession(
        transport: hub.join(),
        controls: FakeControls(on),
        isHost: host,
        name: name,
        clock: partyClock,
        tickEvery: null,
      )..start();
}

const show = {
  'id': 4242,
  'title': {'romaji': 'Party'},
};

void layout(String name) {
  isTv = name == 'tv';
  isDesktop = name == 'desktop';
  addTearDown(() {
    isTv = false;
    isDesktop = false;
  });
}

/// The player on [media], pushed over a page so it can be left.
Future<(Backend, GlobalKey<NavigatorState>)> openPlayer(
  WidgetTester tester,
  Map media,
) async {
  SharedPreferences.setMockInitialValues({'resume': false});
  await Settings.load();
  final previous = configureQuality;
  configureQuality = (_, _) async => const [];
  addTearDown(() => configureQuality = previous);
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final backend = Backend();
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      theme: buildTheme(),
      builder: isTv ? (context, child) => TvInput(child: child!) : null,
      home: const Scaffold(body: Text('the page underneath')),
    ),
  );
  navigator.currentState!.push(
    MaterialPageRoute<void>(
      builder: (_) => PlayerScreen(
        media: media,
        source: Site('site'),
        episodes: episodes,
        index: 0,
        dub: false,
        backend: backend,
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return (backend, navigator);
}

/// "Watch together" in the player's controls, however this layout draws it.
Finder get watchTogether => isTv
    ? find.byIcon(Icons.groups_outlined)
    : find.byTooltip('Watch together');

/// Time passes and the room's messages arrive.
Future<void> run(WidgetTester tester, Rooms rooms, [int steps = 4]) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    rooms.hub.settle();
    await tester.pump();
  }
}

Future<void> close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 5));
}

PartySession panelSession(WidgetTester tester) =>
    tester.widget<PartyPanel>(find.byType(PartyPanel)).link.session;

bool focused(WidgetTester tester, String text) =>
    Focus.of(tester.element(find.text(text))).hasPrimaryFocus;

/// Presses [key] until [text]'s control has focus; false if it never does.
Future<bool> dpadTo(
  WidgetTester tester,
  String text, {
  LogicalKeyboardKey key = LogicalKeyboardKey.arrowDown,
}) async {
  for (var i = 0; i < 12 && !focused(tester, text); i++) {
    await tester.sendKeyEvent(key);
    await tester.pump(const Duration(milliseconds: 100));
  }
  return focused(tester, text);
}

void main() {
  group('party links', () {
    test('name a room by its code, in any case, with or without dashes', () {
      final room = PartyRoom.parse('K7QM-2XVD-9RTA')!;
      for (final link in [
        'aniview://party/K7QM-2XVD-9RTA',
        'aniview://party/k7qm-2xvd-9rta',
        'aniview://party/K7QM2XVD9RTA',
        'ANIVIEW://PARTY/K7QM-2XVD-9RTA',
      ]) {
        expect(partyRoomOf(Uri.parse(link)), room, reason: link);
      }
      for (final other in [
        'aniview://auth#access_token=abc',
        'aniview://mal?code=K7QM-2XVD-9RTA',
        'aniview://party/',
        'aniview://party/K7QM-2XVD-9RT0', // 0 isn't in a code
        'https://party/K7QM-2XVD-9RTA',
      ]) {
        expect(partyRoomOf(Uri.parse(other)), isNull, reason: other);
      }
    });

    test('a party link reaches Home; a sign-in redirect doesn\'t', () async {
      final links = StreamController<Uri>();
      final previous = appLinks;
      appLinks = () => links.stream;
      addTearDown(() {
        appLinks = previous;
        partyLinkArrived.value = null;
      });
      final sub = listenForPartyLinks()!;
      links.add(Uri.parse('aniview://auth#access_token=abc'));
      await pumpEventQueue();
      expect(partyLinkArrived.value, isNull);
      links.add(Uri.parse('aniview://party/K7QM-2XVD-9RTA'));
      await pumpEventQueue();
      expect(partyLinkArrived.value, PartyRoom.parse('K7QM2XVD9RTA'));
      await sub.cancel();
    });

    test('an invite has the show, the code and the link', () {
      final room = PartyRoom.parse('K7QM-2XVD-9RTA')!;
      final invite = partyInvite(room, 'Frieren');
      expect(invite, contains('Frieren'));
      expect(invite, contains('K7QM-2XVD-9RTA'));
      expect(invite, contains('aniview://party/K7QM-2XVD-9RTA'));
      expect(PartyRoom.parse(invite), room);
    });
  });

  for (final name in ['phone', 'tv', 'desktop']) {
    testWidgets('$name: Watch together is offered only for a show with an id', (
      tester,
    ) async {
      layout(name);
      Rooms();
      await openPlayer(tester, const {
        'title': {'romaji': 'Home video'},
      });
      if (isTv) {
        expect(watchTogether, findsNothing);
      } else {
        // There, but off, saying why.
        expect(
          find.byTooltip(
            'Watch together needs a show on AniList or MyAnimeList',
          ),
          findsOneWidget,
        );
        expect(watchTogether, findsNothing);
      }
      await close(tester);

      await openPlayer(tester, show);
      expect(watchTogether, findsOneWidget);
      await close(tester);
    });

    testWidgets(
      '$name: Watch together starts a party, whose panel shows the code, who\'s in and the status',
      (tester) async {
        layout(name);
        final rooms = Rooms();
        await openPlayer(tester, show);
        Settings.partyName = 'Ann';
        await tester.tap(watchTogether);
        await run(tester, rooms);

        expect(rooms.rooms, hasLength(1));
        final room = rooms.rooms.single;
        expect(find.text(room.display), findsOneWidget);
        expect(find.text('Copy invite'), findsOneWidget);
        expect(find.text('Connected'), findsOneWidget);
        expect(find.text('Ann (you)'), findsOneWidget);
        expect(find.text('Just you so far'), findsOneWidget);
        final session = panelSession(tester);
        expect(session.isHost, isTrue);

        // Someone joins: listed by name, and counted.
        final mika = rooms.peer('Mika');
        await run(tester, rooms);
        expect(find.text('Mika'), findsOneWidget);
        expect(find.text('2 here'), findsOneWidget);
        expect(find.text('Host'), findsOneWidget); // the host, marked

        // The host's switch.
        expect(session.hostOnly, isFalse);
        if (isTv) {
          // From Copy invite, which has focus, down to the switch, by remote.
          expect(focused(tester, 'Copy invite'), isTrue);
          expect(await dpadTo(tester, 'Only I can control'), isTrue);
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
          await tester.pump();
        } else {
          await tester.tap(find.text('Only I can control'));
          await tester.pump();
        }
        expect(session.hostOnly, isTrue);
        await run(tester, rooms);
        expect(mika.hostOnly, isTrue);

        mika.leave();
        await close(tester);
      },
    );

    testWidgets(
      '$name: the join field turns down a bad code and takes a code, a dashed code or a link',
      (tester) async {
        layout(name);
        final rooms = Rooms();
        SharedPreferences.setMockInitialValues({});
        await Settings.load();
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            builder: isTv ? (context, child) => TvInput(child: child!) : null,
            home: const Scaffold(body: Text('home')),
          ),
        );
        final context = tester.element(find.text('home'));
        final room = PartyRoom.parse('K7QM-2XVD-9RTA')!;
        for (final (i, typed) in [
          'K7QM2XVD9RTA',
          'k7qm-2xvd-9rta',
          'Join me! aniview://party/K7QM-2XVD-9RTA',
        ].indexed) {
          showDialog<void>(
            context: context,
            builder: (_) => const JoinPartyDialog(),
          );
          await tester.pump(const Duration(milliseconds: 300));
          final field = find.byKey(const ValueKey('party code field'));
          await tester.enterText(field, 'not a code');
          await tester.tap(find.text('Join'));
          await tester.pump();
          expect(
            find.textContaining('That isn\'t a party code'),
            findsOneWidget,
          );
          expect(rooms.rooms, hasLength(i));

          await tester.enterText(field, typed);
          if (isTv) {
            // Off the text fields and onto Join by remote.
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            await tester.pump(const Duration(milliseconds: 100));
            final found =
                await dpadTo(tester, 'Join') ||
                await dpadTo(
                  tester,
                  'Join',
                  key: LogicalKeyboardKey.arrowRight,
                );
            expect(found, isTrue);
            await tester.sendKeyEvent(LogicalKeyboardKey.select);
          } else {
            await tester.tap(find.text('Join'));
          }
          await tester.pump();
          expect(
            find.text('Waiting for the host…'),
            findsOneWidget,
            reason: typed,
          );
          expect(rooms.rooms.last, room, reason: typed);
          if (isTv) {
            expect(await dpadTo(tester, 'Cancel'), isTrue);
            await tester.sendKeyEvent(LogicalKeyboardKey.select);
          } else {
            await tester.tap(find.text('Cancel'));
          }
          await tester.pump();
          await tester.pump(
            const Duration(seconds: 1),
          ); // TV's dialogs take longer to go
          expect(find.byType(JoinPartyDialog), findsNothing);
        }
        await close(tester);
      },
    );
  }

  testWidgets(
    'phone: the status says when the party servers can\'t be reached',
    (tester) async {
      final usable = ValueNotifier(0);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(body: PartyStatus(usable)),
        ),
      );
      expect(find.text('Connecting…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 9));
      expect(find.text('Connecting…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Can\'t reach the party servers'), findsOneWidget);
      usable.value = 2;
      await tester.pump();
      expect(find.text('Connected'), findsOneWidget);
    },
  );

  testWidgets('phone: the host is asked before Back ends the party', (
    tester,
  ) async {
    final rooms = Rooms();
    final (_, navigator) = await openPlayer(tester, show);
    await tester.tap(watchTogether);
    await run(tester, rooms);
    final session = panelSession(tester);
    final mika = rooms.peer('Mika');
    await run(tester, rooms);
    navigator.currentState!.pop(); // the panel
    await tester.pump(const Duration(milliseconds: 500));

    // Back, then think better of it.
    await navigator.currentState!.maybePop();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('End the party?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(session.ended, isFalse);

    // Back, and end it: the guests' room ends too.
    await navigator.currentState!.maybePop();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('End party'));
    await tester.pump(const Duration(milliseconds: 500));
    await run(tester, rooms);
    expect(session.ended, isTrue);
    expect(find.byType(PlayerScreen), findsNothing);
    expect(mika.ended, isTrue);
    await close(tester);
  });

  group('joining from Home', () {
    /// Home on a phone, browsing answering with nothing and AniList with [show]; the sites are [site].
    Future<void> openHome(WidgetTester tester, Source site) async {
      Tracker.primary = _Empty();
      addTearDown(() => Tracker.primary = const AniListCatalog());
      AniList.transport = (_, _) async => {
        'Page': {
          'pageInfo': {'hasNextPage': false},
          'media': [],
          'airingSchedules': [],
          'mediaList': [],
        },
        'Media': {...show},
      };
      addTearDown(() => AniList.transport = null);
      Sites.load = () async => [site];
      Sites.reload();
      addTearDown(() {
        Sites.load = topSources;
        Sites.reload();
      });
      final previous = configureQuality;
      configureQuality = (_, _) async => const [];
      addTearDown(() => configureQuality = previous);
      tester.view.physicalSize = const Size(
        915,
        412,
      ); // the player turns a phone sideways
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({
        'changelog_seen': changelogVersion,
        'resume': false,
        'party_name': 'Mika',
      });
      await Settings.load();
      await tester.pumpWidget(
        MaterialApp(theme: buildTheme(), home: const HomeScreen()),
      );
      await tester.pump(const Duration(milliseconds: 500));
    }

    Future<void> openJoin(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.person_outline_rounded).first);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byTooltip('Join a party'));
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets(
      'a guest lands on the host\'s show and episode, and plays on when the party ends',
      (tester) async {
        final rooms = Rooms();
        final guestBackend = Backend();
        showPlayerBackend = () => guestBackend;
        addTearDown(() => showPlayerBackend = () => null);
        const ep = PartyEpisode(anilist: 4242, number: 2);
        final host = rooms.peer('Ann', host: true, on: ep);
        await openHome(tester, Site('guest'));
        await openJoin(tester);

        await tester.enterText(
          find.byKey(const ValueKey('party code field')),
          'K7QM-2XVD-9RTA',
        );
        await tester.tap(find.text('Join'));
        await tester.pump();
        expect(find.text('Waiting for the host…'), findsOneWidget);
        // The host hears the guest and answers with its state: the show opens, and the player on episode 2.
        for (
          var i = 0;
          i < 40 && find.byType(PlayerScreen).evaluate().isEmpty;
          i++
        ) {
          host.tick();
          await run(tester, rooms, 1);
        }
        expect(find.byType(JoinPartyDialog), findsNothing);
        expect(find.byType(PlayerScreen), findsOneWidget);
        await run(tester, rooms, 8);
        expect(
          guestBackend.calls.where((c) => c.startsWith('open ')).first,
          startsWith('open https://guest.test/2.mp4'),
        );
        expect(host.peers.values.single.name, 'Mika');

        // The host leaves: the guest is told, and its player plays on.
        guestBackend.calls.clear();
        host.leave();
        await run(tester, rooms, 2);
        expect(find.text('The party ended'), findsOneWidget);
        expect(guestBackend.calls, isNot(contains('pause')));
        expect(guestBackend.playing, isTrue);
        await close(tester);
      },
    );

    testWidgets(
      'gives up after 20 s with no host, or at once when the party has ended',
      (tester) async {
        final rooms = Rooms();
        await openHome(tester, Site('guest'));
        await openJoin(tester);
        final field = find.byKey(const ValueKey('party code field'));

        // Nobody there.
        await tester.enterText(field, 'K7QM-2XVD-9RTA');
        await tester.tap(find.text('Join'));
        await run(tester, rooms, 76); // 19 s, the room's messages going nowhere
        expect(find.text('Waiting for the host…'), findsOneWidget);
        await run(tester, rooms, 8);
        expect(
          find.textContaining('Couldn\'t find that party'),
          findsOneWidget,
        );
        expect(find.text('Join'), findsOneWidget); // ready to try again

        // A host that's there, and leaves.
        final host = rooms.peer('Ann', host: true);
        await tester.tap(find.text('Join'));
        await tester.pump();
        await run(tester, rooms, 2);
        expect(find.text('Waiting for the host…'), findsOneWidget);
        host.leave();
        await run(tester, rooms, 2);
        expect(find.text('That party has ended.'), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await close(tester);
      },
    );

    testWidgets('a party link opens the join dialog with its code', (
      tester,
    ) async {
      Rooms();
      await openHome(tester, Site('guest'));
      partyLinkArrived.value = PartyRoom.parse('K7QM2XVD9RTA');
      addTearDown(() => partyLinkArrived.value = null);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(JoinPartyDialog), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('party code field')),
      );
      expect(field.controller!.text, 'K7QM-2XVD-9RTA');
      expect(partyLinkArrived.value, isNull); // taken
      await tester.tap(find.text('Cancel'));
      await close(tester);
    });
  });
}

/// Browsing answers with nothing.
class _Empty implements Catalog {
  @override
  bool get usable => true;
  @override
  Future<List> trending() async => [];
  @override
  Future<List> season() async => [];
  @override
  Future<(List, bool)> search(
    String text,
    SearchFilters filters,
    int page,
  ) async => (<dynamic>[], false);
  @override
  Future<List<(String, Map)>> relations(Map media) async => [];
}

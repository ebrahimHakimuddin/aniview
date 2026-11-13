import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aniview/pairing.dart';
import 'package:aniview/party.dart';
import 'package:aniview/party_chat.dart';
import 'package:aniview/party_qr.dart';
import 'package:aniview/party_transport.dart';
import 'package:aniview/party_ui.dart';
import 'package:aniview/player.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:qr/qr.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'party_ui_test.dart'
    show
        FakeControls,
        Rooms,
        close,
        layout,
        openPlayer,
        run,
        show,
        watchTogether;

/// Two people in a room on a hub, ticked by hand, on a clock the test moves.
class Pair {
  Pair() {
    me = _session('Ann');
    mika = _session('Mika');
    hub.settle();
  }

  final hub = LoopbackHub();
  int now = 1000000;
  late final PartySession me, mika;

  PartySession _session(String name) => PartySession(
    transport: hub.join(),
    controls: FakeControls(),
    isHost: name == 'Ann',
    name: name,
    clock: () => now,
    tickEvery: null,
  )..start();

  /// [who] says [text], a second after whatever came before, so the send limit never gets in the way. Lines
  /// reach the logs a microtask later.
  void say(PartySession who, String text) {
    now += 1000;
    expect(who.sendChat(text), isTrue);
    hub.settle();
  }
}

/// Bubbles over the video, as the overlay draws them.
Finder bubble(String text) => find.descendant(
  of: find.byType(PartyChatOverlay),
  matching: find.textContaining(text),
);

/// A reaction button in the row (not one floating over the video).
Finder reactionButton(String emoji) => find.descendant(
  of: find.byType(PartyReactions),
  matching: find.text(emoji),
);

/// The player's chat button, which opens the bar (phones) or the panel (desktop).
Finder get chatButton => find.byTooltip('Chat');

/// Out of the party panel the player opened when the party started, and into the room with [name] joined.
Future<PartySession> startParty(
  WidgetTester tester,
  Rooms rooms, {
  String name = 'Mika',
}) async {
  Settings.partyName = 'Ann';
  await tester.tap(watchTogether);
  await run(tester, rooms);
  final peer = rooms.peer(name);
  await run(tester, rooms);
  Navigator.of(tester.element(find.byType(PartyPanel))).pop();
  await tester.pump(const Duration(seconds: 1));
  return peer;
}

/// The controls up (once they've faded), then the chat button.
Future<void> openChat(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 4));
  await tester.tapAt(const Offset(640, 360));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(chatButton);
  await tester.pump(const Duration(milliseconds: 300));
}

/// Lines [peer] has heard in the room, from now on.
List<PartyChat> heard(PartySession peer) {
  final lines = <PartyChat>[];
  peer.chat.listen(lines.add);
  return lines;
}

void main() {
  group('bubbles over the video', () {
    Future<PartyChatLog> pumpOverlay(WidgetTester tester, Pair pair) async {
      final log = PartyChatLog.of(pair.me);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              children: [Positioned.fill(child: PartyChatOverlay(log: log))],
            ),
          ),
        ),
      );
      return log;
    }

    testWidgets('appear, go after a few seconds, and stack at most three', (
      tester,
    ) async {
      final pair = Pair();
      await pumpOverlay(tester, pair);

      pair.say(pair.mika, 'first');
      await tester.pump();
      expect(bubble('Mika  first'), findsOneWidget);
      expect(find.byType(IgnorePointer), findsWidgets); // never takes a touch

      for (final text in ['second', 'third', 'fourth']) {
        pair.say(pair.mika, text);
        await tester.pump(const Duration(milliseconds: 100));
      }
      // The fourth pushes the first out.
      expect(bubble('first'), findsNothing);
      for (final text in ['second', 'third', 'fourth']) {
        expect(bubble(text), findsOneWidget, reason: text);
      }

      // Ours show too, as "You".
      pair.say(pair.me, 'mine');
      await tester.pump();
      await tester.pump();
      expect(bubble('You  mine'), findsOneWidget);

      await tester.pump(const Duration(seconds: 7));
      expect(find.byType(AnimatedOpacity), findsNothing);
      expect(bubble('mine'), findsNothing);
      expect(bubble('fourth'), findsNothing);

      // A reaction rises and fades.
      pair.now += 1000;
      expect(pair.mika.react('🔥'), isTrue);
      pair.hub.settle();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('🔥'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('🔥'), findsNothing);
    });

    testWidgets('a muted person\'s lines and reactions are hidden here only', (
      tester,
    ) async {
      final pair = Pair();
      final kai = pair._session('Kai');
      pair.hub.settle();
      PartyChatLog.of(kai);
      final log = await pumpOverlay(tester, pair);

      pair.say(pair.mika, 'before muting');
      await tester.pump();
      expect(bubble('before muting'), findsOneWidget);

      final sentBefore = pair.hub.sent.length;
      log.mute(pair.mika.id, true);
      await tester.pump();
      expect(bubble('before muting'), findsNothing); // gone at once
      expect(pair.hub.sent.length, sentBefore); // nothing told to anyone

      pair.say(pair.mika, 'while muted');
      pair.say(kai, 'from Kai');
      pair.now += 1000;
      pair.mika.react('😂');
      pair.hub.settle();
      await tester.pump(const Duration(milliseconds: 300));
      expect(bubble('while muted'), findsNothing);
      expect(find.text('😂'), findsNothing);
      expect(bubble('from Kai'), findsOneWidget);
      expect(log.lines.map((l) => l.text), ['from Kai']);

      // Others still see Mika, and unmuting brings the scrollback back.
      expect(
        PartyChatLog.of(kai).lines.map((l) => l.text),
        containsAll(['before muting', 'while muted']),
      );
      log.mute(pair.mika.id, false);
      expect(log.lines.map((l) => l.text), [
        'before muting',
        'while muted',
        'from Kai',
      ]);
      await tester.pump(const Duration(seconds: 7));
    });

    test('the scrollback keeps the last 200 lines', () async {
      final pair = Pair();
      final log = PartyChatLog.of(pair.me);
      for (var i = 0; i < 230; i++) {
        pair.say(pair.mika, 'line $i');
      }
      await pumpEventQueue();
      expect(log.lines, hasLength(200));
      expect(log.lines.first.text, 'line 30');
      expect(log.lines.last.text, 'line 229');
    });

    testWidgets('lines are shown as typed: no links, no markup', (
      tester,
    ) async {
      final pair = Pair();
      final log = await pumpOverlay(tester, pair);
      const line = '<b>bold</b> **star** https://example.com';
      pair.say(pair.mika, line);
      await tester.pump();
      expect(bubble(line), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(body: PartyChatScrollback(log: log)),
        ),
      );
      expect(find.text('Mika  $line'), findsOneWidget);
      await tester.pump(const Duration(seconds: 7));
    });
  });

  group('phone', () {
    testWidgets(
      'the chat button opens a bar that sends, and says why when it can\'t',
      (tester) async {
        layout('phone');
        final rooms = Rooms();
        await openPlayer(tester, show);
        final mika = await startParty(tester, rooms);
        final lines = heard(mika);

        // Bubbles show with the controls hidden as well as up.
        expect(find.byType(PartyChatOverlay), findsOneWidget);

        await openChat(tester);
        final field = find.byKey(const ValueKey('party chat field'));
        expect(field, findsOneWidget);
        expect(reactionButton('👍'), findsOneWidget);

        await tester.enterText(field, 'hello there');
        await tester.tap(find.byTooltip('Send'));
        await run(tester, rooms);
        expect(lines.map((l) => l.text), ['hello there']);
        expect(bubble('You  hello there'), findsOneWidget);

        // Typing stops at 300, and that much goes out.
        await tester.pump(const Duration(seconds: 2));
        await tester.enterText(field, 'a' * 301);
        expect(tester.widget<TextField>(field).controller!.text, 'a' * 300);
        await tester.tap(find.byTooltip('Send'));
        await run(tester, rooms);
        expect(lines.last.text, 'a' * 300);

        // Emoji that fit the field but not the room: the limit is said, the text kept.
        final hearts = '❤️' * 151;
        await tester.pump(const Duration(seconds: 2));
        await tester.enterText(field, hearts);
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        expect(
          find.text('Messages can be up to 300 characters'),
          findsOneWidget,
        );
        expect(tester.widget<TextField>(field).controller!.text, hearts);

        // Too fast.
        for (var i = 0; i < 6; i++) {
          await tester.enterText(field, 'spam $i');
          await tester.tap(find.byTooltip('Send'));
        }
        await tester.pump();
        expect(find.text('Slow down a little'), findsOneWidget);

        // A reaction goes from the bar.
        await tester.pump(const Duration(seconds: 2));
        await tester.tap(reactionButton('🔥'));
        await run(tester, rooms);
        expect(lines.where((l) => l.reaction).map((l) => l.text), ['🔥']);

        // Back closes the bar, not the player.
        await tester.binding.handlePopRoute();
        await tester.pump(const Duration(milliseconds: 300));
        expect(field, findsNothing);
        expect(find.byType(PlayerScreen), findsOneWidget);

        mika.leave();
        await close(tester);
      },
    );

    testWidgets(
      'with the keyboard up in landscape the bar sits on it and the video stays its size',
      (tester) async {
        layout('phone');
        final rooms = Rooms();
        await openPlayer(tester, show);
        final mika = await startParty(tester, rooms);
        await openChat(tester);
        final video = tester.getRect(find.byType(PartyChatOverlay));

        tester.view.viewInsets = const FakeViewPadding(bottom: 320);
        addTearDown(tester.view.resetViewInsets);
        await tester.pump(const Duration(milliseconds: 300));
        final bar = tester.getRect(find.byType(PartyChatBar));
        expect(bar.bottom, 720 - 320);
        expect(bar.height, lessThan(120)); // compact: most of the picture shows
        expect(tester.getRect(find.byType(PartyChatOverlay)), video);
        expect(tester.takeException(), isNull);

        mika.leave();
        await close(tester);
      },
    );
  });

  group('desktop', () {
    testWidgets(
      'a side panel shows the scrollback, Enter sends, and typing never reaches the player',
      (tester) async {
        layout('desktop');
        final rooms = Rooms();
        final (backend, _) = await openPlayer(tester, show);
        final mika = await startParty(tester, rooms);
        final lines = heard(mika);

        // Said before the panel opened: it's in the scrollback.
        mika.sendChat('are you there?');
        await run(tester, rooms);

        await openChat(tester);
        expect(find.byType(PartyChatPanel), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(PartyChatPanel),
            matching: find.text('Mika  are you there?'),
          ),
          findsOneWidget,
        );
        // Beside the video, not over it.
        expect(
          tester.getRect(find.byType(PartyChatOverlay)).right,
          1280 - PartyChatPanel.width,
        );

        final field = find.byKey(const ValueKey('party chat field'));
        final editable = tester.widget<TextField>(field).focusNode!;
        expect(editable.hasPrimaryFocus, isTrue);
        final calls = backend.calls.length;

        // The player's keys, typed into the field.
        for (final key in [
          LogicalKeyboardKey.space,
          LogicalKeyboardKey.keyK,
          LogicalKeyboardKey.keyM,
          LogicalKeyboardKey.keyF,
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.bracketRight,
        ]) {
          await tester.sendKeyEvent(key);
        }
        await tester.pump();
        expect(backend.calls.skip(calls), isEmpty);
        expect(find.text('0%'), findsNothing); // M didn't mute

        await tester.enterText(field, 'yes!');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await run(tester, rooms);
        expect(lines.last.text, 'yes!');
        expect(lines.last.peer, isNot(mika.id));
        expect(tester.widget<TextField>(field).controller!.text, isEmpty);
        expect(
          find.descendant(
            of: find.byType(PartyChatPanel),
            matching: find.text('You  yes!'),
          ),
          findsOneWidget,
        );

        // The controls fading out don't take the keyboard from the field.
        await tester.pump(const Duration(seconds: 4));
        expect(editable.hasPrimaryFocus, isTrue);

        // Esc hands the keyboard back to the player: space plays and pauses again.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(editable.hasFocus, isFalse);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump();
        expect(backend.calls.skip(calls), contains('pause'));

        mika.leave();
        await close(tester);
      },
    );
  });

  group('TV', () {
    testWidgets(
      'reactions are reached and sent by D-pad from the controls, and there\'s nothing to type in',
      (tester) async {
        layout('tv');
        final rooms = Rooms();
        await openPlayer(tester, show);
        final mika = await startParty(tester, rooms);
        final lines = heard(mika);

        // Up brings the controls, on play.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(PartyReactions), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        expect(chatButton, findsNothing);

        int focusedReaction() => partyReactions.indexWhere(
          (e) => Focus.of(tester.element(reactionButton(e))).hasPrimaryFocus,
        );
        bool onReaction() => focusedReaction() >= 0;
        for (var i = 0; i < 6 && !onReaction(); i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(onReaction(), isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await run(tester, rooms);
        expect(lines.where((l) => l.reaction), hasLength(1));

        // Along the row, and another.
        final first = focusedReaction();
        await tester.sendKeyEvent(
          first < partyReactions.length - 1
              ? LogicalKeyboardKey.arrowRight
              : LogicalKeyboardKey.arrowLeft,
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(focusedReaction(), allOf(isNonNegative, isNot(first)));
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await run(tester, rooms);
        expect(lines.where((l) => l.reaction), hasLength(2));

        // Lines from others show, read-only.
        mika.sendChat('hi TV');
        await run(tester, rooms);
        expect(bubble('Mika  hi TV'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);

        mika.leave();
        await close(tester);
      },
    );
  });

  group('the party panel', () {
    testWidgets(
      'shows a QR of the link, the scrollback, and mutes a person here only',
      (tester) async {
        layout('phone');
        final rooms = Rooms();
        await openPlayer(tester, show);
        Settings.partyName = 'Ann';
        await tester.tap(watchTogether);
        await run(tester, rooms);
        final mika = rooms.peer('Mika');
        await run(tester, rooms);
        final room = rooms.rooms.single;
        expect(
          tester.widget<PartyQr>(find.byKey(const ValueKey('party qr'))).data,
          room.link,
        );
        expect(find.text('No messages yet'), findsOneWidget);

        mika.sendChat('hello Ann');
        await run(tester, rooms);
        final inPanel = find.descendant(
          of: find.byType(PartyPanel),
          matching: find.text('Mika  hello Ann'),
        );
        expect(inPanel, findsOneWidget);

        final sent = rooms.hub.sent.length;
        await tester.tap(find.byTooltip('Mute Mika\'s messages'));
        await tester.pump();
        expect(find.text('Muted here'), findsOneWidget);
        expect(inPanel, findsNothing);
        expect(find.byTooltip('Show Mika\'s messages'), findsOneWidget);
        // Only our own ticks went out: no message about the mute.
        for (final (_, m) in rooms.hub.sent.skip(sent)) {
          expect(jsonDecode(m)['t'], isNot(anyOf('chat', 'mute')));
        }
        mika.leave();
        await close(tester);
      },
    );

    testWidgets('offers Bring the TV in only on a phone paired with a TV', (
      tester,
    ) async {
      layout('phone');
      final rooms = Rooms();
      await openPlayer(tester, show);
      Settings.partyName = 'Ann';
      await tester.tap(watchTogether);
      await run(tester, rooms);
      expect(find.text('Bring the TV in'), findsNothing); // none paired
      await close(tester);

      await openPlayer(tester, show);
      Settings.tvRemotes = {
        'tv': {
          'key': base64.encode(Uint8List(32)),
          'name': 'Living room',
          'address': '127.0.0.1:9',
        },
      };
      await tester.tap(watchTogether);
      await run(tester, rooms);
      expect(find.text('Bring the TV in'), findsOneWidget);
      await close(tester);
    });
  });

  testWidgets(
    'the QR painted is the qr package\'s matrix for the room\'s link',
    (tester) async {
      final room = PartyRoom.parse('K7QM-2XVD-9RTA')!;
      final image = partyQrImage(room.link);
      // The package's own reading of the same data, built the plain way.
      final reference = QrImage(
        QrCode(
          payload: QrPayload.fromString('aniview://party/K7QM-2XVD-9RTA'),
          errorCorrectLevel: QrErrorCorrectLevel.medium,
        ),
      );
      expect(image.moduleCount, reference.moduleCount);

      const px = 6;
      final count = image.moduleCount, quiet = partyQrQuietZone;
      final side = (count + 2 * quiet) * px;
      final recorder = ui.PictureRecorder();
      PartyQrPainter(image)
          .paint(Canvas(recorder), Size.square(side.toDouble()));
      final bytes = (await tester.runAsync(() async {
        final picture = recorder.endRecording();
        final drawn = await picture.toImage(side, side);
        return drawn.toByteData();
      }))!;
      bool darkAt(int x, int y) => bytes.getUint8((y * side + x) * 4) < 128;

      for (var row = 0; row < count + 2 * quiet; row++) {
        for (var col = 0; col < count + 2 * quiet; col++) {
          final inside =
              row >= quiet &&
              col >= quiet &&
              row < count + quiet &&
              col < count + quiet;
          final dark = inside && reference.isDark(row - quiet, col - quiet);
          // The middle of the module, and its corners, so modules are whole squares.
          for (final (dx, dy) in [(3, 3), (0, 0), (px - 1, px - 1)]) {
            expect(
              darkAt(col * px + dx, row * px + dy),
              dark,
              reason: 'module $row,$col',
            );
          }
        }
      }
    },
  );

  test('a paired phone brings its TV into a party; the TV takes only a well-formed code', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null; // localhost only: the TV's end runs here
    SharedPreferences.setMockInitialValues({});
    await Settings.load();
    await TvLink.start();
    final port = TvLink.address!.split(':').last;
    final base = 'http://127.0.0.1:$port';
    Future<http.Response> post(String path, Map body) =>
        http.post(Uri.parse('$base$path'), body: jsonEncode(body));

    // Pair the way the phone does.
    final phone = PairKeys();
    final paired = TvLink.pair();
    final tv = jsonDecode(
      (await post('/pair', {'pub': base64.encode(phone.publicKey)})).body,
    );
    final key = phone.agree(base64.decode(tv['pub'])).key;
    TvLink.confirm(true);
    await post('/remote', {'data': base64.encode(seal(key, jsonEncode({})))});
    await paired;
    Settings.tvRemotes = {
      'tv': {
        'key': base64.encode(key),
        'name': 'Living room',
        'address': '127.0.0.1:$port',
      },
    };
    addTearDown(() => partyLinkArrived.value = null);

    final room = PartyRoom.parse('K7QM-2XVD-9RTA')!;
    await TvRemote.joinParty(room);
    expect(partyLinkArrived.value, room); // Home opens the join dialog on it

    // Anything but a bare code is refused, and opens nothing.
    partyLinkArrived.value = null;
    var sent = DateTime.now().millisecondsSinceEpoch + 1000;
    Future<int> press(Map body) async => (await post('/key', {
      'id': remoteKeyId(key),
      'data': base64.encode(seal(key, jsonEncode({...body, 't': ++sent}))),
    })).statusCode;
    for (final bad in [
      'not a code',
      'K7QM-2XVD-9RT0',
      'join aniview://party/K7QM-2XVD-9RTA',
      'k7qm-2xvd-9rta ',
      42,
      null,
    ]) {
      expect(
        await press({'party': bad}),
        HttpStatus.badRequest,
        reason: '$bad',
      );
    }
    expect(partyLinkArrived.value, isNull);

    // A stranger's key can't send one.
    final stranger = PairKeys().agree(PairKeys().publicKey).key;
    final refused = await post('/key', {
      'id': remoteKeyId(stranger),
      'data': base64.encode(
        seal(stranger, jsonEncode({'party': room.display, 't': ++sent})),
      ),
    });
    expect(refused.statusCode, HttpStatus.forbidden);
    expect(partyLinkArrived.value, isNull);

    // Nothing paired: the phone says so.
    Settings.tvRemotes = {};
    await expectLater(TvRemote.joinParty(room), throwsException);
  });
}

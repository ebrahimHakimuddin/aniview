import 'package:aniview/history.dart';
import 'package:aniview/metadata.dart';
import 'package:aniview/playback.dart';
import 'package:aniview/settings.dart';
import 'package:aniview/sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _sec = Duration(seconds: 1);
const _length = Duration(minutes: 24);
const _outro = SkipTime(SkipType.outro, Duration(minutes: 22), _length);
const _intro = SkipTime(
  SkipType.intro,
  Duration(minutes: 1),
  Duration(minutes: 2),
);

PlaybackSession _session() {
  final session = PlaybackSession([
    for (var i = 1; i <= 2; i++) Episode(i, ref: '$i'),
  ], 0);
  session
    ..streams = const [
      VideoStream('HD-1', 'a', {}, skips: [_intro, _outro]),
      VideoStream('HD-2', 'b', {}),
    ]
    ..playing(session.streams.first);
  return session;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(
      {},
    ); // auto-next on, skip button, 85%
    await Settings.load();
  });

  test('falls back through the servers, then gives up', () {
    final session = _session();
    expect(session.fallback()?.label, 'HD-2');
    session.playing(session.fallback()!);
    expect(session.fallback(), isNull);
  });

  test('quick seek presses the same way add up from where the last landed', () {
    final session = _session();
    final t0 = DateTime(2026);
    final at = Duration(minutes: 5);
    DateTime after(int ms) => t0.add(Duration(milliseconds: ms));

    expect(session.step(at, _length, 10, now: t0), (
      to: at + _sec * 10,
      total: 10,
    ));
    // mpv still reports the old position; the second press builds on the first.
    expect(session.step(at, _length, 10, now: after(500)), (
      to: at + _sec * 20,
      total: 20,
    ));
    expect(session.step(at, _length, 10, now: after(1000)), (
      to: at + _sec * 30,
      total: 30,
    ));
    // Changing direction starts over from the real position.
    expect(session.step(at + _sec * 30, _length, -10, now: after(1500)), (
      to: at + _sec * 20,
      total: -10,
    ));
    // So does a pause between presses.
    expect(session.step(at, _length, 10, now: after(5000)), (
      to: at + _sec * 10,
      total: 10,
    ));
  });

  test('counts an episode watched once, and again after moving on', () {
    final session = _session();
    expect(session.reachedWatched(_sec * 60, _length), isFalse);
    expect(session.reachedWatched(_length * .9, _length), isTrue);
    expect(session.reachedWatched(_length * .95, _length), isFalse);
    session
      ..start(1)
      ..playing(const VideoStream('HD-1', 'c', {}));
    expect(session.reachedWatched(_length * .9, _length), isTrue);
  });

  test('offers the next episode in the outro or the last 20 seconds', () {
    final session = _session();
    expect(session.upNext(_sec * 60, _length), isNull);
    final outro = session.upNext(_outro.start, _length)!;
    expect(outro.next.number, 2);
    expect(outro.countdown, isFalse); // two minutes left
    expect(session.upNext(_length - _sec * 10, _length)!.countdown, isTrue);
    expect(session.ok(_outro.start, _length), isA<PlayNext>());

    session.upNextDismissed = true;
    expect(session.upNext(_length - _sec * 10, _length), isNull);
    expect(session.advancesOnFinish, isFalse);

    session.start(1); // the last episode offers nothing
    expect(session.upNext(_length - _sec, _length), isNull);
  });

  test('OK skips the intro on screen, else plays or pauses', () {
    final session = _session();
    final skip = session.ok(_intro.start, _length);
    expect(skip, isA<SkipTo>());
    expect((skip as SkipTo).position, _intro.end);
    expect(session.ok(_sec * 30, _length), isA<PlayPause>());
  });

  test('auto-skips each skip once', () {
    Settings.skipMode = SkipMode.auto;
    final session = _session();
    expect(session.skipButton(_intro.start), isNull);
    expect(session.autoSkip(_intro.start), _intro);
    expect(session.autoSkip(_intro.start + _sec), isNull);
  });

  test('a held seek moves the target and lands once on release', () {
    final session = _session();
    expect(session.press(_sec * 30, _length, 10), _sec * 40);
    expect(session.release(), isNull); // a tap already seeked

    session.press(_sec * 30, _length, -10);
    expect(session.hold(_length, -10), _sec * 10);
    expect(session.hold(_length, -10), Duration.zero); // clamped
    expect(session.release(), Duration.zero);
    expect(session.hold(_length, 10), isNull); // nothing held any more
  });

  group('opening an episode', () {
    const site = VideoStream('HD-1', 'https://site/1.m3u8', {});
    const local = VideoStream('Downloaded', '/files/1.mp4', {});
    List<Episode> episodes() => [
      for (var i = 1; i <= 2; i++) Episode(i, ref: '$i'),
    ];

    test('a download plays instead of the site, from the saved spot', () async {
      await WatchHistory.played(
        const {
          'id': 7,
          'title': {'userPreferred': 'Show'},
        },
        source: 'Site',
        episodes: episodes(),
        index: 0,
        position: _sec * 90,
        duration: _length,
        dub: false,
      );
      var fetched = 0;
      final session = PlaybackSession(
        episodes(),
        0,
        media: const {'id': 7},
        fetch: (_) async {
          fetched++;
          return [site];
        },
        downloaded: (e) => e.number == 1 ? local : null,
      );
      expect(await session.open(0), (at: _sec * 90));
      expect(session.streams.single, local);
      expect((session.fromDownload, fetched), (true, 0));

      expect(await session.open(1), (at: null)); // not the one left part-way
      expect(session.streams.single, site);
      expect(session.fromDownload, isFalse);
    });

    test(
      "fails clearly offline without a download, or with no servers",
      () async {
        final offline = PlaybackSession(
          episodes(),
          0,
          site: 'Anikoto',
          downloaded: (_) => null,
        );
        await expectLater(
          offline.open(0),
          throwsA(
            predicate(
              (e) => '$e'.contains(
                "isn't downloaded and Anikoto can't be reached",
              ),
            ),
          ),
        );
        final empty = PlaybackSession(
          episodes(),
          0,
          dub: true,
          site: 'Anikoto',
          fetch: (_) async => [],
          downloaded: (_) => null,
        );
        await expectLater(
          empty.open(0),
          throwsA(predicate((e) => '$e'.contains('No dub servers'))),
        );
      },
    );

    test('a newer episode started meanwhile wins', () async {
      final session = PlaybackSession(
        episodes(),
        0,
        fetch: (e) async => [
          VideoStream('ep ${e.number}', 'https://s', const {}),
        ],
        downloaded: (_) => null,
      );
      final first = session.open(0);
      final second = session.open(1);
      expect(await first, isNull);
      expect(await second, isNotNull);
      expect(session.streams.single.label, 'ep 2');
    });
  });

  test(
    'picks subtitles by language, then English, then any; Off turns them off',
    () {
      final session = _session();
      const stream = VideoStream(
        'HD',
        'u',
        {},
        subtitles: [Subtitle('Spanish', 's'), Subtitle('English', 'e')],
      );
      expect(
        session.subtitleFor(stream).track?.label,
        'English',
      ); // the default
      Settings.subtitleLanguage = 'Spanish';
      expect(session.subtitleFor(stream).track?.label, 'Spanish');
      Settings.subtitleLanguage = 'German';
      expect(session.subtitleFor(stream).track?.label, 'English');
      expect(
        session.subtitleFor(const VideoStream('HD', 'u', {})).track,
        isNull,
      );
      Settings.subtitleLanguage = 'Off';
      expect(session.subtitleFor(stream).off, isTrue);
    },
  );

  test('an error only moves servers before the video loads', () {
    final session = _session();
    expect(session.stalled(Duration.zero), isTrue);
    expect(session.stalled(_length), isFalse);
  });

  test("reads where another app stopped, or its end when it finished", () {
    expect(
      PlaybackSession.externalStop({'position': 5000, 'duration': 60000}),
      (position: _sec * 5, duration: _sec * 60),
    );
    expect(
      PlaybackSession.externalStop({'completed': true, 'duration': 60000})
          .position,
      _sec * 60,
    );
    expect(PlaybackSession.externalStop(null).position, Duration.zero);
  });

  test('resumes on the site when it has the episode, else from downloads', () {
    Episode ep(num n) => Episode(n, ref: '$n');
    final site = [ep(1), ep(2)], downloaded = [ep(3)];
    (List<Episode>, int) resume(num n, {bool listed = true}) =>
        PlaybackSession.resumeIn(
          n,
          site: site,
          downloaded: downloaded,
          source: 'Anikoto',
          listed: listed,
        );

    expect(resume(2), (site, 1));
    expect(resume(3), (downloaded, 0)); // not on the site (yet)
    expect(
      () => resume(4),
      throwsA(predicate((e) => '$e'.contains('Episode 4 is not on Anikoto'))),
    );
    expect(
      () => resume(4, listed: false),
      throwsA(
        predicate((e) => '$e'.contains('no longer one of the top sites')),
      ),
    );
  });
}

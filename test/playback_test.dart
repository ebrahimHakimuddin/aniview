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
}

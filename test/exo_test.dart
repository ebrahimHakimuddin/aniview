import 'package:aniview/exo.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers commands like the Android side would: [opened] says what the stream reports once it loads.
class _Backend extends PlayerBackend {
  _Backend(this.opened);
  final Map Function(Map<String, Object?> args) opened;
  late void Function(Map event) emit;
  final calls = <String>[];

  @override
  Future<void> start(void Function(Map event) on) async => emit = on;

  @override
  Future<void> call(String method, Map<String, Object?> args) async {
    calls.add(switch (method) {
      'seek' => 'seek ${args['ms']}',
      'subtitle' || 'audio' => '$method ${args['track']}',
      _ => method,
    });
    // Loads a moment after open() returns, as a real stream does.
    if (method == 'open') Future(() => emit(opened(args)));
  }

  @override
  Future<void> setVolume(double level) async {}
  @override
  Future<void> dispose() async {}
}

Map _track(String id, String title) => {'id': id, 'title': title};

void main() {
  test('lands on the resume point when the stream ignored it, then picks the subtitle file and the audio', () async {
    final backend = _Backend(
      (_) => {
        'position': 0, // started from the beginning anyway
        'buffer': 0,
        'duration': 1440000,
        'audios': [_track('a1', 'Japanese'), _track('a2', 'English')],
        'tracks': [_track('s1', 'English')],
      },
    );
    final player = ExoPlayer(backend);
    final shown = await player.load(
      'https://video.test/index.m3u8',
      start: const Duration(minutes: 5),
      subtitles: [(url: 'https://video.test/en.vtt', label: 'English')],
      subtitleFile: 'English',
      audio: 'English',
    );
    expect(shown, 'English');
    expect(backend.calls, [
      'open',
      'seek 300000',
      'subtitle s1',
      'audio a2',
      'rate',
    ]);
  });

  test('a load overtaken by the next one stops settling', () async {
    final backend = _Backend(
      (args) => {'position': 0, 'buffer': 0, 'duration': 1000},
    );
    final player = ExoPlayer(backend);
    final first = player.load('first', subtitlesOff: true);
    final second = player.load('second', subtitlesOff: true);
    expect(await first, isNull);
    expect(await second, 'Off');
    expect(backend.calls.where((c) => c == 'subtitle off'), hasLength(1));
  });

  group('the intent callback', () {
    ExoPlayer playerWith(
      _Backend backend,
      List<String> asked,
      bool allow,
    ) => ExoPlayer(backend)
      ..intent = (op, {position, rate}) {
        asked.add(
          '${op.name}${position == null ? '' : ' ${position.inMilliseconds}'}'
          '${rate == null ? '' : ' $rate'}',
        );
        return allow;
      };

    test('is asked before play, pause, seek and speed changes', () async {
      final backend = _Backend((_) => {});
      final asked = <String>[];
      final player = playerWith(backend, asked, true);
      await player.play();
      await player.pause();
      await player.seek(const Duration(seconds: 5));
      await player.setRate(1.5);
      expect(asked, ['play', 'pause', 'seek 5000', 'rate 1.5']);
      expect(backend.calls, ['play', 'pause', 'seek 5000', 'rate']);
      expect(player.state.rate, 1.5);
    });

    test('stops them when it says no', () async {
      final backend = _Backend((_) => {});
      final asked = <String>[];
      final player = playerWith(backend, asked, false);
      await player.play();
      await player.pause();
      await player.playOrPause();
      await player.seek(const Duration(seconds: 5));
      await player.setRate(2);
      expect(asked, hasLength(5));
      expect(backend.calls, isEmpty);
      expect(player.state.position, Duration.zero);
      expect(player.state.rate, 1);
    });

    test('is never asked by apply*, nor by load settling', () async {
      final backend = _Backend(
        (_) => {'position': 0, 'buffer': 0, 'duration': 1440000},
      );
      final asked = <String>[];
      final player = playerWith(backend, asked, false);
      await player.applyPlay();
      await player.applyPause();
      await player.applySeek(const Duration(seconds: 5));
      await player.applyRate(1.25);
      await player.load(
        'https://video.test/index.m3u8',
        start: const Duration(minutes: 5),
        subtitlesOff: true,
        rate: 1.25,
      );
      expect(asked, isEmpty);
      expect(backend.calls, [
        'play',
        'pause',
        'seek 5000',
        'rate',
        'open',
        'seek 300000',
        'subtitle off',
        'rate',
      ]);
    });
  });

  test('the shared mpv stays with the newest player', () {
    final a = Object(), b = Object();
    MpvOwner.claim(a);
    MpvOwner.claim(b);
    // a's route closing after b opened leaves b's video, channel and audio focus alone.
    expect(MpvOwner.release(a), isFalse);
    expect(MpvOwner.release(b), isTrue);
    expect(MpvOwner.release(b), isFalse);
  });
}

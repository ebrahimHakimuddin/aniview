import 'package:aniview/exo.dart';
import 'package:aniview/platform.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS initializes and selects its native media_kit backend', () {
    expect(videoBackendFor('ios'), VideoBackend.mediaKit);
  });

  test('Android continues to use ExoPlayer without loading libmpv', () {
    expect(videoBackendFor('android'), VideoBackend.exoPlayer);
  });

  test('desktop keeps media_kit and unsupported platforms fail explicitly', () {
    for (final os in ['macos', 'linux', 'windows']) {
      expect(videoBackendFor(os), VideoBackend.mediaKit);
    }
    expect(() => videoBackendFor('other'), throwsUnsupportedError);
  });

  test('upscaling picks mpv on Android only; elsewhere mpv plays anyway', () {
    for (final (os, upscale, backend) in [
      ('android', false, VideoBackend.exoPlayer),
      ('android', true, VideoBackend.mediaKit),
      ('ios', false, VideoBackend.mediaKit),
      ('ios', true, VideoBackend.mediaKit),
      ('macos', false, VideoBackend.mediaKit),
      ('macos', true, VideoBackend.mediaKit),
      ('linux', false, VideoBackend.mediaKit),
      ('linux', true, VideoBackend.mediaKit),
      ('windows', false, VideoBackend.mediaKit),
      ('windows', true, VideoBackend.mediaKit),
    ]) {
      expect(
        videoBackendFor(os, upscale: upscale),
        backend,
        reason: '$os, upscale $upscale',
      );
    }
    expect(
      () => videoBackendFor('other', upscale: true),
      throwsUnsupportedError,
    );
  });

  group('a new player\'s backend', () {
    late String os;
    setUp(() => os = playbackOs);
    tearDown(() => playbackOs = os);

    test('Android: Media3 with upscaling off, and nothing to fall back to', () {
      playbackOs = 'android';
      expect(usesMediaKit, isFalse);
      final backend = PlayerBackend.forSession();
      expect(backend.kind, VideoBackend.exoPlayer);
      expect(backend.supportsShaders, isFalse);
      expect(backend.fallback, isNull);
      expect(
        PlayerBackend.forSession(upscale: false).kind,
        VideoBackend.exoPlayer,
      );
    });

    test('Android: mpv with upscaling on, falling back to Media3', () {
      playbackOs = 'android';
      final backend = PlayerBackend.forSession(upscale: true);
      expect(backend.kind, VideoBackend.mediaKit);
      expect(backend.supportsShaders, isTrue);
      final fallback = backend.fallback!();
      expect(fallback.kind, VideoBackend.exoPlayer);
      expect(fallback.fallback, isNull);
    });

    test('iOS and desktop: mpv either way, with no fallback', () {
      for (final os in ['ios', 'macos', 'linux', 'windows']) {
        playbackOs = os;
        for (final upscale in [false, true]) {
          final backend = PlayerBackend.forSession(upscale: upscale);
          expect(backend.kind, VideoBackend.mediaKit, reason: os);
          expect(backend.fallback, isNull, reason: os);
        }
      }
    });
  });
}

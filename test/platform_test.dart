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
}

import 'package:aniview/platform.dart';
import 'package:aniview/tracker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('aniview/ios');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('iOS hands the entire OAuth URL to its native browser bridge', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });
    const url =
        'https://anilist.co/api/v2/oauth/authorize?client_id=123&response_type=token';
    await IosApp.open(url);
    expect(received?.method, 'open');
    expect(received?.arguments, url);
  });

  test('iOS rejects file and executable URLs before crossing the bridge', () {
    for (final url in [
      'file:///etc/passwd',
      'javascript:alert(1)',
      'https:',
      'relative',
    ]) {
      expect(() => IosApp.open(url), throwsArgumentError);
    }
  });

  test('iOS reports browser launch failures to the caller', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'open');
    });
    await expectLater(
      IosApp.open('https://anilist.co'),
      throwsA(isA<PlatformException>()),
    );
  });

  test('public AniList browsing is available without OAuth configuration', () {
    expect(const AniListCatalog().usable, isTrue);
  });
}

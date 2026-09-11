import 'package:aniview/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('compares release tags with the installed version', () {
    expect(isNewerVersion('v1.5.2', '1.5.1'), isTrue);
    expect(isNewerVersion('v1.10.0', '1.9.9'), isTrue);
    expect(isNewerVersion('v2.0', '1.9.9'), isTrue);
    expect(isNewerVersion('v1.5.1', '1.5.1'), isFalse);
    expect(isNewerVersion('v1.5', '1.5.0'), isFalse);
    expect(isNewerVersion('v1.4.9', '1.5.0'), isFalse);
  });
}

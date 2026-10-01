import 'package:aniview/states.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'a platform error reads as its message, never its native stack trace',
    () {
      final error = PlatformException(
        code: 'error',
        message: 'java.lang.ClassNotFoundException: boom',
        stacktrace: 'at eo.d(r8-map-id-1:761)',
      );
      expect(friendlyError(error), 'java.lang.ClassNotFoundException: boom');
      expect(friendlyError(error), isNot(contains('r8-map-id')));
      expect(
        friendlyError(PlatformException(code: 'x')),
        'Something went wrong',
      );
    },
  );
}

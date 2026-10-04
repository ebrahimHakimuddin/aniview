import 'dart:async';

import 'package:aniview/platform.dart';

/// Tests run on the developer's desktop, but most check the phone's screens: a test of the desktop's sets
/// [isDesktop] itself.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  isDesktop = false;
  await testMain();
}

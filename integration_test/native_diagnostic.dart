import 'dart:io';

import 'package:aniview/exo.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;

// Opt-in control for hosted Windows runners without GPU/audio devices.
// Call after pumping the video widget so controller initialization can finish.
Future<void> configureNativeDiagnostic(ExoPlayer player) async {
  if (!const bool.fromEnvironment('WINDOWS_SOFTWARE_CONTROL')) return;
  if (!Platform.isWindows) {
    throw StateError('WINDOWS_SOFTWARE_CONTROL requires Windows');
  }
  await player.video!.platform.future.timeout(const Duration(seconds: 20));
  final native = player.video!.player.platform as NativePlayer;
  await native.setProperty('hwdec', 'no').timeout(const Duration(seconds: 10));
  await native.setProperty('ao', 'null').timeout(const Duration(seconds: 10));
}

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

  test('a release is newer than its betas, and betas go by their number', () {
    expect(isNewerVersion('v2.6.0-beta.2', '2.6.0-beta.1'), isTrue);
    expect(isNewerVersion('v2.6.0-beta.10', '2.6.0-beta.9'), isTrue);
    expect(isNewerVersion('v2.6.0', '2.6.0-beta.3'), isTrue);
    expect(isNewerVersion('v2.6.0-beta.1', '2.5.0'), isTrue);
    expect(isNewerVersion('v2.6.0-beta.3', '2.6.0'), isFalse);
    expect(isNewerVersion('v2.6.0-beta.1', '2.6.0-beta.1+28'), isFalse);
  });

  test("picks this build's download, the beta's under its own names", () {
    const assets = [
      {'name': 'app-armeabi-v7a-release.apk'},
      {'name': 'app-arm64-v8a-release.apk'},
      {'name': 'AniView-Beta-arm64-v8a.apk'},
      {'name': 'AniView-windows-x64-setup.exe'},
      {'name': 'AniView-Beta-windows-x64-setup.exe'},
      {'name': 'AniView-macos.dmg'},
      {'name': 'AniView-Beta-x86_64.AppImage'},
    ];
    Map? pick(String os, {String? abi, bool beta = false}) =>
        updateAsset(assets, os: os, abi: abi, beta: beta);
    expect(pick('android', abi: 'arm64-v8a'), assets[1]);
    expect(pick('android', abi: 'arm64-v8a', beta: true), assets[2]);
    expect(pick('android', abi: 'x86_64'), isNull);
    expect(pick('android'), isNull);
    expect(pick('windows'), assets[3]);
    expect(pick('windows', beta: true), assets[4]);
    expect(pick('macos'), assets[5]);
    expect(pick('macos', beta: true), isNull);
    expect(pick('linux', beta: true), assets[6]);
    expect(pick('ios'), isNull);
  });
}

# iOS build and sideloading

AniView's iPhone target uses bundle identifier `com.kidfury.aniview`, the existing app icon and phone UI,
and **iOS 15.0 or later**. Flutter 3.47.6's engine requires iOS 15.0; the native dependencies fit within
that minimum. Development was performed on Apple Silicon with Flutter 3.47.6, Dart 3.13.5, Xcode 27.0
and CocoaPods 1.17.0. FVM is recommended; the build script uses the installed Flutter SDK if FVM is absent.
Do not upgrade Flutter implicitly while preparing a test build.

## Validation status

The initial port has passed `flutter pub get`, `flutter analyze` (no issues), all 273 unit/widget tests,
and a physical-device Release archive build with generated `TOP_SITES`. The bundle validator confirms
iPhoneOS binaries, embedded media libraries and the iOS 15.0 minimum. FVM was unavailable locally,
so these commands used the installed Flutter 3.47.6 SDK. Android native compilation has not been run
because this Mac has no Android SDK; the shared regression suite passes and Android retains ExoPlayer.

The device owner confirmed successful installation with Sideloadly 0.70.1 on an iPhone XR running
iOS 18.7.9 after removing macOS AppleDouble metadata from the IPA. The packaging script now excludes
that metadata, and the validator rejects archives containing `._*` or `__MACOSX` entries. Earlier
packages failed with `ApplicationVerificationFailed` / `0xe8008001` for `objective_c.framework`;
changing ZIP compression or thinning the binaries did not fix it. Do not use those earlier packages.
An Xcode Personal Team Release archive and development IPA export also succeeded, and Apple's strict
signature validation passed. Neither successful signing nor installation establishes native playback
correctness; the physical-device checklist is still pending.

The native integration test also remains unverified: the installed iOS 18.5 simulator aborts before Dart
starts because its runtime cannot load `libswiftWebKit.dylib`. Do not count compilation of that test as a
pass. The Release archive additionally reports the template's blank launch-image warning; the app icon
itself uses AniView's existing artwork.

## Architecture and platform support

- Android still selects Media3 ExoPlayer. iOS explicitly initializes media_kit and bundles
  `media_kit_libs_ios_video` 1.1.4's **iOS** libmpv/FFmpeg XCFrameworks. `media_kit_video` supplies its
  native iOS texture renderer. Desktop libraries are not loaded on iOS. See the
  [media_kit platform documentation](https://pub.dev/packages/media_kit).
- The existing `PlayerBackend`, `ExoPlayer`, `PlaybackSession`, stream-address relay, episode selection,
  watch history and tracker remain shared. Play/pause/seek, resume, speed, fullscreen landscape,
  subtitles, audio-track selection, server fallback and next-episode decisions use the same interfaces.
- HLS requests and subtitle requests use the existing loopback relay, including required source
  headers and segment processing. Direct media receives its headers through media_kit.
- Native decoding supports formats present in the bundled FFmpeg build; it does **not** promise every
  codec, DRM stream, host or hardware-decoding path. Encrypted commercial DRM is not supported.
  The current subtitle overlay displays plain text; full ASS styling is not preserved by that overlay.
  Stream quality capping is not implemented in the media_kit backend; source/server selection and
  download quality selection remain available. Burned-in subtitles cannot be switched off.
- The iOS audio session uses playback/movie mode. Brightness gestures use the iOS brightness plugin;
  volume gestures control the player's volume, while hardware buttons control system volume.
  Playback pauses when the app is hidden. No background audio, Picture in Picture, AirPlay UI or
  background episode notification job is implemented.
- AniList public GraphQL browsing works without a client ID. OAuth sign-in requires
  `ANILIST_CLIENT_ID`; MyAnimeList browsing/fallback requires `MAL_CLIENT_ID`. These are independent.
- iOS opens OAuth in the system browser and receives `aniview://auth` through `app_links`.
  `FlutterDeepLinkingEnabled` is false so Flutter does not interpret callbacks as page routes.
  MyAnimeList's existing PKCE flow also uses the system browser and `aniview://mal`.
  A callback is consumed only by a waiting sign-in flow with the matching host. If iOS kills the app
  during sign-in, start sign-in again. Credentials are persisted by the project's existing session code.
- Cloudflare checks use the iOS WKWebView implementation of flutter_inappwebview, with its persistent
  cookie store and actual user agent. A source may still reject WebKit or require verification again.
  No global ATS exception, arbitrary WebView loads, TLS bypass, or private networking entitlement is added.
  Plain-HTTP pages blocked by WKWebView's ATS policy are unsupported unless a specific, reviewed exception
  is introduced. The Dart/libmpv loopback relay does not require disabling WebView ATS.
- Downloads live in the app's Documents/downloads sandbox. The index stores relative episode/subtitle
  names, resolving the current container path on each launch. iOS keeps downloaded HLS playlists,
  segments and keys instead of launching an ffmpeg process. Single-file videos remain files. Existing
  queued/partial downloads resume on launch; keep AniView foregrounded while downloading. Uninstalling
  the app removes its downloads. Re-sign updates using the same app identity to retain data.
- As on other platforms, HLS downloads with separate audio renditions are rejected rather than saved
  without sound. Optional subtitle downloads may be unavailable if their source fails.
- Android APK extensions, APK updates, external Android players, gallery export, Android document-tree
  storage, TV layout/remote controls and background notification settings are unavailable on iOS.
  Their controls are hidden or guarded. The built-in Dart streaming-source adapters remain available.
  The in-app recent-episode inbox remains available; it is separate from Android background jobs.

## Build a re-signable IPA

Install Xcode with the iOS SDK, accept its license and complete first-launch setup. Install CocoaPods.
The project uses Swift Package Manager for plugins that support it and CocoaPods for the media plugins.
Both CocoaPods and Swift package lockfiles are tracked; downloaded dependencies are not.

From the repository root:

```sh
fvm flutter pub get
fvm flutter analyze
fvm flutter test
python3 tool/check_ios_bundle.py
bash tool/ios_ipa.sh
```

Without FVM, use `flutter` instead of `fvm flutter` with the version above. The script calls
`flutter build ipa --release --no-codesign`, then packages the archived device app under
`Payload/Runner.app`. It validates the device platform, arm64 libraries, bundled dependencies, minimum
OS, and bundle ID, and prints the IPA's SHA-256. The output is:

```text
build/ios/ipa/AniView-2.5.0-unsigned.ipa
```

This is an **unsigned, re-signable IPA**, not an app that can be installed directly. A successful build
does not establish successful signing, installation, device playback, or provider availability.

The script generates `TOP_SITES` using `tool/top_sites.dart` on every build and stops if generation fails.
When `dart_defines.env` exists it is passed to Flutter. An alternate private file can be selected with:

```sh
DART_DEFINES_FILE=/absolute/path/to/private.env bash tool/ios_ipa.sh
```

For example, the local, gitignored `dart_defines.env` can contain:

```dotenv
ANILIST_CLIENT_ID=your_client_id
MAL_CLIENT_ID=your_client_id
```

Register the AniList redirect as `aniview://auth`. For MAL sign-in, configure `aniview://mal` for that
client. No client secret belongs in this public mobile app. Rybbit defines remain optional as described
in the README. With no defines file, the build deliberately omits sign-in, MAL fallback and analytics.
Do not add real configuration, signing credentials, archives or IPA files to Git.

## Install with Sideloadly on this Mac

1. Open [Sideloadly](https://sideloadly.io/). Connect the iPhone by USB, unlock it and accept **Trust This
   Computer**. Select the iPhone in Sideloadly, not the Mac.
2. Drag `AniView-2.5.0-unsigned.ipa` into Sideloadly. Use its Apple ID sideloading mode, not normal install
   or ad-hoc signing. Enter your own Apple ID and complete password/2FA prompts directly in Sideloadly.
3. Keep the app's identity consistent on future updates. Let Sideloadly manage provisioning and sign the
   app **and every embedded framework**. Do not lower the minimum iOS version or enable tweak injection.
4. Click **Start** and wait for signing and installation to finish.
5. If requested, trust the developer under **Settings → General → VPN & Device Management**. On iOS 16+
   enable **Settings → Privacy & Security → Developer Mode**, restart and confirm. Then launch AniView.
6. Free-account signatures expire after seven days; enable Sideloadly's refresh service or re-sign before
   expiration. Update in place with the same Apple account/app identity to preserve downloads and history.

Sideloadly supports free Apple IDs; a paid Developer Program account is not required for this workflow.
The Apple account, device trust, developer trust and Developer Mode steps must be completed by the device
owner. The IPA contains no personal team ID, certificate or provisioning profile. See
[Sideloadly's installation and account guidance](https://sideloadly.io/) and
[Apple's Developer Mode instructions](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).

AltStore Classic or SideStore can also import the unsigned IPA using their **My Apps → +** flow after
their own initial setup. They must re-sign the bundle and frameworks with your account. Do not use an
unsigned direct-install workflow or assume an AltStore PAL marketplace install can import arbitrary IPAs.

## Optional Xcode signing

For a developer-signed build, create the ignored `ios/Flutter/Signing.xcconfig` locally:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
CODE_SIGN_STYLE = Automatic
```

Open `ios/Runner.xcworkspace`, select your iPhone and confirm that your team can provision the bundle ID.
If a different identifier is required, change it only in your local configuration and inspect Git before
committing. Build with `fvm flutter build ipa --release --export-method development`, passing the same
client-ID and generated TOP_SITES defines as the unsigned script. Xcode needs the appropriate signing
certificate, device registration and provisioning profile. Keep `ios/ExportOptions.plist` private if used.

## Repeatable native playback check

The native integration test uses synthetic H.264/AAC footage with two audio tracks and a WebVTT subtitle.
It exercises header-protected HLS through AniView's relay, playback position, pause, seek, speed commands,
subtitles, local HLS and local MP4 audio selection. It uses actual media_kit libraries, with no fake player.
The simulator does not validate iPhone hardware decoding, battery use or physical audio routes.

Start an iPhone simulator, then run in two terminals:

```sh
# Terminal 1; requires ffmpeg. Keep this process running for the test.
python3 tool/ios_media_fixture.py

# Terminal 2; choose the simulator ID from flutter devices.
fvm flutter test integration_test/ios_playback_test.dart -d SIMULATOR_ID
```

Stop the fixture server with Ctrl-C afterwards. It binds only to localhost; all fixtures are under
`build/ios-media-fixture`. No third-party media is downloaded or committed. This fixture URL is intended
for a simulator on the same Mac, not a physical iPhone.

## Manual iPhone checklist

Record the iPhone model, iOS version, IPA hash and sideloading tool. Do not include tokens in reports.

- [ ] Install the signed IPA and launch without a debugger; verify name/icon and no launch crash.
- [ ] Navigate Home, Search, Schedule, My list and Me; test back/swipe navigation, keyboard dismissal,
      light/dark themes, portrait/landscape and safe areas around the notch/Dynamic Island.
- [ ] Search for an anime, open its details, related shows and episode list.
- [ ] With a client-ID build, sign in to AniList, return through `aniview://auth`, cancel/retry sign-in,
      restart and confirm the session persists. **Not testable in a build without client IDs.**
- [ ] Load episodes from each available built-in source; complete Cloudflare verification if prompted.
- [ ] Stream an HLS episode and a compatible direct file; play/pause, seek, speed, fullscreen, brightness,
      volume, interruption/lock screen, server fallback and next-episode playback. Confirm audio/video sync.
- [ ] Select subtitles, turn them off, and select alternate audio where the source actually supplies it.
- [ ] Leave playback mid-episode, reopen it and confirm the saved position; test progress tracking when signed in.
- [ ] Download while foregrounded, interrupt/relaunch to resume, then use airplane mode to play the saved
      episode and subtitles. Confirm deletion frees storage. Try a source with unsupported separate audio
      downloads and confirm it reports an error rather than saving a silent episode.
- [ ] Force-close/relaunch and confirm history, settings, downloads and (when configured) authentication persist.

Physical iPhone testing and explicit approval are required before publishing this contribution.

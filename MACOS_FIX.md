# macOS playback, sign-in and navigation fixes

## Issues and fixes

- **Release playback reports “No connection” across providers.** `StreamAddress`
  routes HLS streams and subtitles through `HlsProxy`, which listens on loopback.
  Release builds were missing `com.apple.security.network.server`; Debug/Profile
  already had it. Add the entitlement to Release so the sandbox permits the local
  listener. The app stays sandboxed, and the proxy retains its loopback binding
  and random path token. The entitlement itself is not restricted to loopback;
  that restriction is enforced by the existing proxy code.
- **Browser sign-in does not return to the app.** Desktop login listens for
  `aniview://auth` (AniList) or `aniview://mal` (MyAnimeList), but the Mac bundle
  did not register the scheme. Add `aniview` to `CFBundleURLTypes`; the existing
  `app_links` plugin receives the callback.
- **Opening details from the top bar hides the sidebar.** Search suggestions and
  top-bar actions have a context outside the active section Navigator. On macOS,
  route these details pages through the active section Navigator so the sidebar,
  back button and section-specific window title remain available. The player
  still opens above the shell as before.
- **Search uses the wrong requested Mac shortcut.** Use Cmd+K on macOS and update
  the visible hint. Windows/Linux retain Ctrl+F.
- **The Mac Back tooltip advertises Alt+Left.** Show Cmd+[ on macOS, matching the
  existing Mac Back binding.
- **Modified player keys can trigger plain playback controls.** On macOS, let
  Command/Control/Option combinations reach their shortcut handlers, rather than
  interpreting Cmd+[ as a speed change or Cmd+M as mute. Bare playback keys remain
  available.

Runtime changes in shared Dart files are gated to macOS. Windows, Linux and
Android behavior is preserved. CI checks the source entitlements/URL scheme and
checks every architecture's signature and entitlements in the packaged Mac app.

## Build and verify

Use the Flutter and Xcode versions pinned in `.github/workflows/ci.yml`, with
CocoaPods installed. Create an ignored `dart_defines.env` with the release OAuth
client IDs supplied by the maintainer (or your own registered clients):

```text
ANILIST_CLIENT_ID=your_anilist_client_id
MAL_CLIENT_ID=your_myanimelist_client_id
```

Register redirects `aniview://auth` and `aniview://mal` respectively. From the
repository root:

```sh
flutter pub get --enforce-lockfile
flutter analyze
flutter test
python3 tool/check_macos_bundle.py
flutter build macos --release --dart-define-from-file=dart_defines.env \
  --dart-define=TOP_SITES="$(dart tool/top_sites.dart)"
```

`tool/macos_build.sh` runs the checks, builds, validates the signed bundle and
creates a DMG in a timestamped `build/macos-review-*` directory. Its configuration
file must include `TOP_SITES` as well as the OAuth IDs, either in Flutter's env-file
or JSON format. Pass the file as the first argument. It does not install the app.
Build artifacts and local OAuth configuration should not be committed.

## Manual checks on macOS

1. Quit all running AniView copies and eject old installer volumes. Install the
   new app and launch that copy to avoid sending OAuth callbacks to an old build.
2. Play an episode from two different providers, seek, and check subtitles.
3. Start a fresh AniList browser login, approve it, and confirm the waiting dialog
   closes and the profile appears. Test MyAnimeList separately if available.
4. Press Cmd+K and check the field's “Cmd K” hint. Open a search suggestion;
   confirm the sidebar remains visible. Switch sections and return, then use
   Cmd+[ to return to the previous page.
5. During playback, check Cmd+[ does not change speed and Cmd+M does not mute.
   Bare [ and ] should still change speed. Check normal and minimum window sizes.

New widget regression tests cover Mac search and details routing, plus unchanged
Windows/Linux behavior. Configuration checks do not substitute for real playback
or completing OAuth with a real account.

## Configuration-only hotfix

For an existing release, `bash tool/macos_hotfix.sh /Applications/AniView.app
build/macos-fixed-new` copies the app, adds the two bundle configuration fixes,
re-signs the copy ad-hoc and produces a DMG. Choose a new output directory. This
hotfix includes **only playback permission and URL scheme registration**, not the
Dart navigation/keyboard changes. It preserves the original release's build-time
configuration and does not modify the source app or saved user data.

Local ad-hoc builds are not Apple-notarized releases. Official signing and
notarization require the maintainer's credentials.

References: [Flutter macOS entitlements](https://docs.flutter.dev/platform-integration/macos/building)
and [app_links macOS setup](https://github.com/llfbandit/app_links/blob/master/doc/README_macos.md).

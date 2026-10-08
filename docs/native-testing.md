# Native integration testing

Run this suite in a disposable installation. Its first run clears application
preferences and its download checks delete existing downloads. Never run it
against an installation containing your own settings or downloads.

`integration_test/native_test.dart` replaces catalog and source discovery with
local fixtures. It exercises real preferences, filesystem storage, HTTP video
downloads, the Android remuxer, native playback (ExoPlayer or libmpv), and screen
widgets. Screen setup uses the test harness; this is not a complete live-provider
or browser-account end-to-end test.

The suite checks theme and logo changes without restarting; both tracker sign-in
choices; search clearing; TV result names/previews/filter visibility; the source
picker; retrying an unavailable download after selecting another source through
the episode download button; plain HLS, AES-128 HLS and direct MP4 downloads; video
decoding and seeking. Android HLS downloads must contain one `episode.mp4` and no
segment files. Desktop HLS downloads currently retain a local playlist.

A successful run writes a checkpoint only after all downloads have been persisted.
Running it a second time in a new process additionally asserts that the source,
theme preference and all completed downloads were restored. Screenshots are saved
in `native-reports` beside the application's downloads directory.

## Run locally

Generate synthetic four-second H.264/AAC videos and serve them in one terminal:

```sh
bash tool/native-fixtures.sh /tmp/aniview-native-fixtures --serve
```

In another terminal, from the repository root:

```sh
flutter pub get --enforce-lockfile
flutter test integration_test/native_test.dart -d linux
# Repeat in a new process for the persistence check.
flutter test integration_test/native_test.dart -d linux \
  --dart-define=NATIVE_REQUIRE_RESTART=true
```

Linux requires the WPE/mpv dependencies in `tool/linux-deps.sh`, a display, and a
working audio output. A headless environment needs Xvfb and a PulseAudio null sink.
Keep `PULSE_SERVER` and `PULSE_COOKIE` configured if the test uses a different XDG
configuration directory from the audio server.

For a phone or Android TV emulator, replace the device ID as appropriate:

```sh
flutter test integration_test/native_test.dart -d emulator-5554 \
  --no-uninstall \
  --dart-define=NATIVE_FIXTURE_URL=http://10.0.2.2:8765
# Repeat after the first process exits.
flutter test integration_test/native_test.dart -d emulator-5554 \
  --no-uninstall \
  --dart-define=NATIVE_FIXTURE_URL=http://10.0.2.2:8765 \
  --dart-define=NATIVE_REQUIRE_RESTART=true
```

Flutter 3.47.3 uninstalls the app after integration tests by default. Keep
`--no-uninstall` on both runs so preferences, downloads and screenshots remain
available. The second run must require the checkpoint; a fresh installation
cannot count as a persistence pass. When using `flutter drive` with a previously
built test APK, use `--keep-app-running` for the same reason.

If the emulator has no working guest network route, use
`adb -s emulator-5554 reverse tcp:8765 tcp:8765` and build/run with
`--dart-define=NATIVE_FIXTURE_URL=http://127.0.0.1:8765`. Confirm an HTTP response
from the guest before testing downloads. For slow software emulation, the suite
supports `--dart-define=NATIVE_WAIT_SECONDS=180`; this extends waits while keeping
the same assertions.

Both emulators need x86_64 images. API 36 has an Android TV x86_64 image; older
x86-only TV images cannot run Flutter's Android x64 build. Hardware acceleration
is strongly recommended. Check the Android package manager is available before
installing; `sys.boot_completed=1` alone did not establish readiness on the cloud
host's slow software emulator.

The manually dispatched `Native integration tests` workflow uses KVM-enabled
GitHub runners for separate phone and TV runs, including a second process for
persistence. Adding the workflow does not establish that a remote run passed.

## Remaining live-device checks

- Android TV: open the native keyboard in Discover, type a query, and use a real
  D-pad Down to enter the keyboard. Clear the query without closing the app. Check
  result information, sort/filter focus changes, centered episode focus, and
  related-show titles with the remote.
- Android: export an HLS episode to the gallery and a user-selected document
  folder, then play and seek in the exported MP4 using another video app. Restart
  after granting folder access and check the saved episode remains playable.
- Windows: complete MAL sign-in in Edge and another browser; verify the full OAuth
  query reaches the browser and its `aniview://mal/` return reaches the running app.
  Test AniList as well. Repeat on other supported native desktop OSes.
- Real tracker authorization needs registered `ANILIST_CLIENT_ID` and
  `MAL_CLIENT_ID` build definitions plus a test account. Configure build values
  securely; don't put account credentials in test code or logs.
- Live source extraction, long videos, codec variants, cancellation/network loss,
  and physical-device performance remain separate from the synthetic video suite.

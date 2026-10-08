# Validation record — 2026-10-08

These results describe the local cloud host. No GitHub Actions run was dispatched.
The native suite substitutes local catalog/source fixtures and uses synthetic
four-second H.264/AAC videos. It is not full live-provider or account testing.

| Target/check | Observed result |
| --- | --- |
| Dependency installation | Frozen lockfile installation passed without changing the manifests. |
| Static analysis | No issues. |
| Unit/widget tests | 246 passed. |
| Linux release and AppImage | Built in the pinned Debian forky environment; AppImage startup smoke passed. Requires the documented newer glibc/WPE runtime. |
| Linux native fixture suite | Passed, including a fresh-process restart. Theme/logo switching, both sign-in choices, search clearing, source selection/persistence, failed download recovery using the current source, plain/AES-128 HLS and direct MP4 downloads, native decoding and seeking. Desktop HLS remains a local playlist. |
| Android release packaging | Passed for ARMv7, ARM64 and x86_64 using Flutter's normal plugin regeneration. Local builds use the temporary dependency workaround described below, the debug signing fallback, and no tracker client-ID definitions. |
| Android phone | Debug/profile test APKs built and installed on API 30 x86_64. Native tests failed at logo decoding and source recovery. The guest had no usable network route to the fixture server. The first longer run also exposed a foreground-service start timeout; that service was corrected and compiled, with no recurrence during the subsequent failed run. MP4 remuxing/playback and restart persistence have not passed on Android. |
| Android TV | API 36 x86_64 image installed and two software boot attempts made. Framework watchdog restarts, a blank display and unavailable authorized ADB prevented installing/running the app. Native TV checks are unrun. |
| Windows/macOS | Unrun: no native OS runners are available on this host. |
| Artifact CI | Workflow syntax validated; remote packaging jobs unrun. |

One additional Linux run timed out at direct MP4 playback after restoring its
checkpoint and successfully playing both HLS fixtures. A subsequent diagnostic
run passed both cases and all three playback checks. Retain this intermittent
failure in the record; its cause has not been isolated. The logs are
`linux/direct-playback-timeout.log` and `linux/player-diagnostic-pass.log`.
The final new-process run required the previously saved checkpoint and passed
both cases, including all three native playback/seek checks. Its output is
`linux/strict-restart-pass.log`.

The first Android driver printed `All tests passed` despite a timed-out test. The
driver now requires a completion marker written only after the final assertion.
An incomplete run must not be accepted as a pass.
Flutter's test command also uninstalls the app by default. The workflow now uses
`--no-uninstall` and requires the persisted checkpoint on its second run; merely
rerunning on an empty installation cannot count as a restart pass.

The service crash is retained in `android-phone/service-crash.log`. Its service
now starts from the foreground activity without a foreground-start watchdog for
a request that can be cancelled before creation, and promotes in `onCreate`.
The suite now requires a decoded `RawImage` for each theme, rather than merely
finding an asset widget. Removing the resize hint did not fix native decoding,
so that speculative production change was reverted. A separate profile probe
also failed to decode the original PNG and the same PNG without metadata. The
APK's logo bytes match the source, and Linux decodes them. Both Impeller and Skia
probes failed on this software Android emulator. The assets remain unchanged;
the underlying cause has not been established on another device.
UI and download/playback checks are separate cases; one case's failure does not
prevent the other from running, and both must pass before recording completion.

The phone's later boot exposed `IllegalStateException: Lost network stack` in
the Android system process, followed by dead-system errors in System UI and
Bluetooth. Installation of the diagnostic APK then failed repeatedly because
the package-manager service disappeared. These are emulator operating-system
failures, separate from the app's earlier foreground-service crash and logo
failure. See `android-phone/warm-boot-crash.log` and `emulator-install-fail.log`.

Android compilation used a temporary, narrowly scoped local Maven repository for
the exact pinned Injekt source commit because this host's network policy denied
JitPack. The dependency was compiled from its official repository with verified
Maven Central dependencies. This verifies local compilation and packaging with
that substitution, not canonical remote dependency resolution. The temporary
Gradle override has been removed; fresh Android builds require working JitPack
access. No substituted release APK should be treated as a production release.

Logs and screenshots are retained outside the checkout under
`/workspace/native-results`; final Linux output is `linux/strict-restart-pass.log`.
The Android APK uses the production application ID and the suite resets
preferences/downloads. It is for disposable emulator installations only.

See [native-testing.md](native-testing.md) for reproduction and the outstanding
real-device, TV keyboard/D-pad, gallery/document export, browser OAuth and live
stream tests. Completing tracker sign-in requires registered client IDs and a
test account; no account authentication was completed here.

Verified toolchain files were restored from temporary RAM to workspace storage.
Disposable emulator overlays and generated caches were removed after capturing
the evidence. Emulators must create fresh test data on their next boot.

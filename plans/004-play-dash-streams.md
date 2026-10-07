# Plan 004: Play DASH (.mpd) streams by shipping ExoPlayer's DASH module

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 1fd219d..HEAD -- android/app/build.gradle.kts android/app/proguard-rules.pro android/app/src/main/kotlin/com/kidfury/aniview/ExoPlayers.kt lib/states.dart`
> If any changed, compare the "Current state" excerpts against the live code before proceeding; on a mismatch, STOP.
> Note: `android/app/proguard-rules.pro` is *untracked* at `1fd219d` (created with the extension work); it must exist.

## Status

- **Priority**: P0 (playback fails outright for every DASH stream; reported by the maintainer with a screenshot)
- **Effort**: S
- **Risk**: LOW (adds one library, ~100–200 KB)
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `1fd219d`, 2026-10-02

## Why this matters

Playing an episode (seen on "The Apothecary Diaries Season 3, Episode 1") shows "Couldn't play this episode" with a raw
stack trace:
`PlatformException(error, java.lang.ClassNotFoundException: androidx.media3.exoplayer.dash.DashMediaSource$Factory …)`.
The native player builds media with `DefaultMediaSourceFactory`, which picks a media source from the URL: for an
`.mpd` URL it reflectively loads `DashMediaSource.Factory`, and that class is not in the app because only the base
`media3-exoplayer` and `media3-exoplayer-hls` modules are bundled. Any source or extension that returns a DASH stream
therefore cannot play. (Extensions are the likely origin: the built-in sites serve HLS or MP4.) After this plan DASH
streams play, and a playback failure shows a short message instead of a stack trace.

## Current state

- `android/app/build.gradle.kts` (the `dependencies` block, ≈ lines 72–86):

  ```kotlin
  dependencies {
      implementation("androidx.documentfile:documentfile:1.1.0")
      // Playback, as CloudStream does it: ExoPlayer with HLS.
      val media3 = "1.8.0"
      implementation("androidx.media3:media3-exoplayer:$media3")
      implementation("androidx.media3:media3-exoplayer-hls:$media3")
      // What Aniyomi extensions are built against and expect the app to provide, at Aniyomi's versions.
      implementation("com.squareup.okhttp3:okhttp:5.4.0")
      ...
  }
  ```
- `android/app/src/main/kotlin/com/kidfury/aniview/ExoPlayers.kt` ≈ lines 198–213 builds the item and source; only HLS gets an
  explicit MIME type, everything else is inferred from the URL:

  ```kotlin
  val item = MediaItem.Builder()
      ...
      .apply { if (hls) setMimeType(MimeTypes.APPLICATION_M3U8) }
  ...
  player.setMediaSource(DefaultMediaSourceFactory(DefaultDataSource.Factory(context, http)).createMediaSource(item), startMs)
  ```
- `lib/player.dart:340-344,389-390`: only `.m3u8` URLs are treated as HLS (`VideoStream.isHls` in `lib/sources.dart`); every other URL is
  handed to ExoPlayer as is.
- `android/app/proguard-rules.pro` (untracked) keeps libraries with plain `-keep` rules (no `allowoptimization`). It does not
  mention media3 on purpose: the media3 libraries ship their own consumer rules, which already make the reflective HLS
  load work in release builds. The DASH module ships the equivalent rule for `DashMediaSource$Factory`.
- Verified during recon: the current release APK (`build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`) contains **0**
  classes under `androidx/media3/exoplayer/dash/`.
- `lib/states.dart:12-23` — `friendlyError` has no case for `PlatformException`, so it falls through to the default
  `'$error'.replaceFirst('Exception: ', '')`, and a `PlatformException`'s `toString()` includes the native stack trace:

  ```dart
  String friendlyError(Object error) => switch (error) {
    CloudflareChallenge() => 'This site needs a quick verification before it can be reached',
    SocketException() || HandshakeException() || http.ClientException() => 'No connection. Check your internet and try again',
    TimeoutException() => 'The site took too long to respond',
    HttpException(:final message) => 'The site returned an error ($message)',
    FormatException() => 'The site sent something unexpected. It may have changed its layout',
    _ => '$error'.replaceFirst('Exception: ', ''),
  };
  ```
  (`lib/states.dart` already imports `dart:io`, `dart:async` and `package:http`; check its imports for `package:flutter/services.dart`
  before using `PlatformException`.)
- Commit-message style: sentence-case imperative, no prefix, **no trailers** (no `Co-Authored-By`).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Dependency present | `cd android && ./gradlew :app:dependencies --configuration releaseRuntimeClasspath -q \| grep media3-exoplayer-dash` | one line mentioning `androidx.media3:media3-exoplayer-dash:1.8.0` |
| Compile Kotlin | `cd android && ./gradlew :app:compileDebugKotlin -q` | exit 0 |
| Analyze | `fvm flutter analyze` | `No issues found!` |
| Tests | `fvm flutter test` | `All tests passed!` |
| Beta APK (needs `dart_defines.env`, gitignored) | `fvm flutter build apk --release --split-per-abi --dart-define=TOP_SITES="$(fvm dart tool/top_sites.dart)" --dart-define-from-file=dart_defines.env --android-project-arg=aniviewBeta=true --dart-define=ANIVIEW_BETA=true` | `✓ Built …app-arm64-v8a-release.apk` |
| Stop Gradle (always, after any build) | `(cd android && ./gradlew --stop)` | `Daemon stopped` |
| DASH classes in the APK | `~/Android/Sdk/build-tools/37.0.0/dexdump build/app/outputs/flutter-apk/app-arm64-v8a-release.apk \| grep -a -c "Class descriptor.*exoplayer/dash/"` | a number greater than 0 |

## Scope

**In scope** (the only files you should modify):
- `android/app/build.gradle.kts`
- `lib/states.dart`
- `test/states_test.dart` (create, only if no existing test file already covers `friendlyError`; otherwise add to that file)

**Out of scope** (do NOT touch, even though they look related):
- `android/app/src/main/kotlin/com/kidfury/aniview/ExoPlayers.kt` — do not set MIME types or build a `DashMediaSource` by hand;
  `DefaultMediaSourceFactory` picks DASH once the module is on the classpath.
- `android/app/proguard-rules.pro` — do not add media3 keep rules unless Step 3's APK check fails (then STOP and report).
- `lib/player.dart`, `lib/sources.dart` (`isHls`), anything about HLS proxying: DASH is played directly by ExoPlayer.
- Other media3 modules (`-smoothstreaming`, `-rtsp`): not needed; do not add them.

## Git workflow

- Branch: `advisor/004-play-dash`.
- Commit per step is fine; final message e.g. `Play DASH streams and keep stack traces out of playback errors`. No trailers.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Ship the DASH module

In `android/app/build.gradle.kts`, add the line below directly under the `media3-exoplayer-hls` line, and update the
comment above `val media3` to read `// Playback, as CloudStream does it: ExoPlayer with HLS and DASH.`

```kotlin
implementation("androidx.media3:media3-exoplayer-dash:$media3")
```

**Verify**: `cd android && ./gradlew :app:dependencies --configuration releaseRuntimeClasspath -q | grep media3-exoplayer-dash`
→ at least one line containing `androidx.media3:media3-exoplayer-dash:1.8.0`.
**Verify**: `cd android && ./gradlew :app:compileDebugKotlin -q` → exit 0.

### Step 2: Show a short message for platform errors

In `lib/states.dart`, add a `PlatformException` case to `friendlyError` before the default case, so the message — not the
native stack trace in `toString()` — is what the user reads. If `PlatformException` is not already imported there, add
`import 'package:flutter/services.dart';`.

```dart
  PlatformException(:final message) => message ?? 'Something went wrong while playing',
```

Test (see Test plan): `friendlyError(PlatformException(code: 'error', message: 'boom', stacktrace: 'at foo(Bar.java:1)'))`
must equal `'boom'` and must not contain `Bar.java`.

**Verify**: `fvm flutter analyze` → `No issues found!`; `fvm flutter test` → `All tests passed!`.

### Step 3: Prove the class is in the release APK, then stop Gradle

Run the beta build command from the table (it needs the gitignored `dart_defines.env`; if the file is absent, say so and
skip to the report — the Step 1 dependency check still stands), then the dexdump check, then **always** stop Gradle.

**Verify**: build prints `✓ Built …app-arm64-v8a-release.apk`; the dexdump command prints a number > 0; `(cd android && ./gradlew --stop)`
prints `Daemon stopped`.

## Test plan

- Add a unit test for `friendlyError` with a `PlatformException` carrying a stack trace (asserts the short message and that the
  stack text is absent). Use `package:flutter_test`; see `test/tracker_test.dart` for the plain-`test()` style used in this repo.
- Playing a real DASH stream cannot be tested in CI. In your final report, ask the maintainer to open the failing episode
  ("The Apothecary Diaries Season 3, Episode 1") on the new beta and confirm it plays.

## Done criteria

ALL must hold:

- [ ] `grep -n "media3-exoplayer-dash" android/app/build.gradle.kts` shows the new line
- [ ] `fvm flutter analyze` → `No issues found!` and `fvm flutter test` → `All tests passed!` including the new `friendlyError` test
- [ ] `./gradlew :app:compileDebugKotlin` exits 0
- [ ] If a build was possible: the dexdump check prints a number > 0 and Gradle was stopped afterwards
- [ ] `git status --short` lists only the in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The build is fine but dexdump still shows 0 DASH classes (R8 removed them): report it, do not add keep rules on your own.
- Gradle cannot resolve `media3-exoplayer-dash:1.8.0` (offline cache) — report the exact error.
- The excerpts above don't match the live files (drift).
- You find the failing URL is not DASH (e.g. the error persists on a `.mp4`/`.m3u8` after the module is added) — report the URL's extension.

## Maintenance notes

- `media3` modules must share one version: when bumping `val media3`, all three (`exoplayer`, `-hls`, `-dash`) move together.
- Other formats `DefaultMediaSourceFactory` can pick reflectively need their own module (`-smoothstreaming` for `.ism`, `-rtsp`);
  add them the same way if a source ever returns those.
- The same `PlatformException` handling now covers every screen that calls `friendlyError`; reviewers should check no caller relied
  on the stack text.
- This is a good example of why a CI Android build (plan 002's follow-up) is worth having: a missing runtime module only fails on
  the first stream that needs it.

# Plan 011: Recover or report when the Android player fails mid-episode

> **Executor instructions**: Confirm the finding in the live code first (line numbers are approximate). Follow the
> steps, run every verification, and stop on a STOP condition instead of improvising. The reviewer maintains
> `plans/README.md`; do not edit it. Planned at `f0b41d2`, 2026-11-13.

- **Priority** P1 · **Effort** M · **Risk** MED (cannot be run on a device here) · **Category** bug

## Why this matters

On Android (Media3 ExoPlayer) a fatal error after the video has started leaves a frozen picture with no message and
no way to retry: `ExoPlayers.kt` (≈ 197) forwards `onPlayerError`, but the listener in `lib/player.dart` (≈ 252)
drops every error unless `session.stalled(player.state.duration)`, i.e. unless nothing has loaded yet. After
`onPlayerError` Media3 leaves the player idle until it is prepared again. On media_kit (iOS, desktop) the error
stream also carries non-fatal log lines, which is why errors after load are ignored there; keep that.

## Steps

1. In the player's error listener, when the error arrives after load and the backend is ExoPlayer (`!usesMediaKit`):
   reload the same stream at the current position once (`_play(current, at: position)`), with a short hint.
2. If the reloaded stream errors again before making progress, treat it like a failed server: go through
   `_serverFailed` (next server at the same position, else the error view with "Try again").
3. Reset the "already retried" state when playback has progressed past the failure point or the episode/server
   changes, so a long episode can recover from more than one network blip but can never loop.
4. Leave media_kit behaviour after load exactly as it is. Leave the before-load path (`stalled`) as it is.
5. The position watched so far must still be saved (the existing history/progress code must keep running).

## Test plan

`test/player_controls_test.dart` has a fake `Backend` whose `emit` sends events; tests run with `usesMediaKit` true
on desktop, so find how `usesMediaKit` is decided (`lib/platform.dart`) and whether a test can override it. If it
cannot be overridden without touching production code, extract the decision ("ignore / reload / next server / give
up") into a pure function or `PlaybackSession` method and unit-test that, and say what is covered only by reading.
Cases: error after load on ExoPlayer reloads once at the position; a second error without progress moves to the next
server; with no server left the error view shows; progress between two errors allows another reload; media_kit
ignores an error after load.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Format | `fvm dart format <files you touched>` | exit 0 |
| Analyze | `fvm flutter analyze` | `No issues found!` |
| Tests | `fvm flutter test` | `All tests passed!` (381 passing before this plan) |

Widget tests run on a fake clock: do not use real sockets or real timers in them (a `Stream.timeout` only ends when
the test does), and add new tests at the end of an existing test file rather than the start.

## Scope

`lib/player.dart`, `lib/playback.dart`, tests. Not `ExoPlayers.kt`, not `lib/exo.dart` unless a STOP is reported.

## Git

Branch `advisor/011-android-error-after-load`, one commit,
`fix: reload or move on when the Android player fails mid-episode`, no trailers. Do not push.

## STOP conditions

- ExoPlayer's error events are not distinguishable from media_kit's in Dart without changing `lib/exo.dart`.
- The reload could loop.
- A verification fails twice after a reasonable fix attempt.

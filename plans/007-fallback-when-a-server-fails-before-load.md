# Plan 007: Try the next server when one fails before the player loads (iOS and desktop)

> **Executor instructions**: Follow the steps, run every verification, and stop on a STOP condition instead of
> improvising. The reviewer maintains `plans/README.md`; do not edit it.
>
> **Drift check (run first)**: `git diff --stat 5ceb40e..HEAD -- lib/player.dart lib/playback.dart lib/hls_proxy.dart`
> must be empty. If not, compare the excerpts below with the live code; on a mismatch, STOP.

- **Priority** P1 · **Effort** S–M · **Risk** LOW · **Category** bug · **Planned at** `5ceb40e`, 2026-11-13

## Why this matters

Sources often list dead servers, and the player is meant to move on to the next one. On the media_kit platforms
(`usesMediaKit`: iOS and desktop) `_play` first fetches the stream's master playlist to learn its qualities
(`HlsProxy.configureQuality`). If that fetch throws, the player never opens, so its error stream never fires and the
fallback never runs: the user sees "Couldn't play this episode" although other servers were available. When the same
throw happens during a fallback or a manual server switch, the future is not awaited and the error is unhandled.

## Current state

- `lib/player.dart` `_play` (≈ 602–654): `StreamAddress.instance.forPlayer(stream)`, then under `usesMediaKit`
  `HlsProxy.configureQuality(...)` (which does `fetchBytes(upstream, ...)` in `lib/hls_proxy.dart` ≈ 50–70 and can
  throw), then `player.load(...)`. No try/catch.
- Callers: `_load` (≈ 541–565) awaits `_play(streams.first, at: opened.at)` inside a try whose catch sets `error`;
  the error listener (≈ 252–264) calls `_play(next, at: _startAt)` unawaited; find the others with
  `grep -n "_play(" lib/player.dart`.
- The error listener holds the fallback logic inline: if `session.stalled(player.state.duration)`, take
  `session.fallback()`, show the hint `'${current!.label} failed · trying ${next.label}'`, play it, else set `error`.
- `lib/playback.dart`: `PlaybackSession.fallback()` (≈ 237–240) returns the stream after `current`, or null at the
  end, so repeated fallbacks terminate.

## Steps

1. Move the listener's "next server or give up" logic into one method on the player state (e.g.
   `_serverFailed(Object e)`), and have the error listener call it (keeping its `mounted` and `stalled` guards).
2. In `_play`, catch a failure from the work that happens before and during the load (`forPlayer`, the quality
   pre-fetch, `player.load`). When this call is still current (`mounted`, `generation == _playGeneration`,
   `current == stream`), route it to `_serverFailed`. A stale call swallows the error silently. `_play` itself must
   never complete with an error.
3. Keep `_load`'s own catch for failures from `session.open` (no streams at all, a Cloudflare challenge): those are
   not server failures and must still show the error state. A `CloudflareChallenge` thrown inside `_play` must not be
   treated as a dead server; let it reach the error state as today (check how the existing error UI offers
   verification and keep that working).
4. Make sure an explicit server pick by the user (the server menu) that fails still falls back or reports, with no
   unhandled error.

Do not make `configureQuality` swallow errors: the fallback decision belongs in the player, and a silent empty
quality list would hide the failure until the player times out.

## Test plan

Look at `test/playback_test.dart`, `test/hls_playback_test.dart` and `test/player_controls_test.dart` for how the
player and session are faked. Add coverage that, with media_kit behaviour on and the first server's pre-fetch
throwing, the second server is played and the "failed · trying" hint is shown; and that with a single server the
error state is shown. If the player screen cannot be driven that far in a widget test with the existing fakes, extract
the decision into `PlaybackSession` or a small pure function and unit-test that, and say in the report what remains
covered only by reading.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Format | `fvm dart format lib/player.dart lib/playback.dart test` | exit 0, only files you touched change |
| Analyze | `fvm flutter analyze` | `No issues found!` |
| Tests | `fvm flutter test` | `All tests passed!` (352 passing before this plan) |

## Scope

`lib/player.dart`, `lib/playback.dart` only if the decision is extracted, and tests. Out of scope: errors after the
video has started (`stalled` is false then; that is finding 4, which needs a device), `lib/hls_proxy.dart`,
`lib/exo.dart`, the Android side.

## Git

Branch `advisor/007-fallback-before-load`, one commit,
`fix: try the next server when one fails before the player loads`, no trailers. Do not push.

## STOP conditions

- The fix would change behaviour on Android's ExoPlayer path beyond the shared refactor in step 1.
- Fallback could loop (a failing server is retried) with the change.
- A verification fails twice after a reasonable fix attempt.

# Plan 006: Bound every network wait, and stop a failed MyAnimeList renewal from signing out

> **Executor instructions**: Follow the steps, run every verification, and stop on a STOP condition instead of
> improvising. The reviewer maintains `plans/README.md`; do not edit it.
>
> **Drift check (run first)**: `git diff --stat 5ceb40e..HEAD -- lib/net.dart lib/anilist.dart lib/mal.dart
> lib/jellyfin.dart lib/jellyseerr.dart lib/extensions.dart` must be empty. If not, compare the excerpts below with the
> live code; on a mismatch, STOP.

- **Priority** P0 · **Effort** S–M · **Risk** LOW · **Category** bug · **Planned at** `5ceb40e`, 2026-11-13

## Why this matters

Most requests have no time limit, so a host that accepts the connection and then goes quiet hangs the caller forever:
episode lists and stream lookups spin, Home never falls back from AniList to MyAnimeList (the fallback only runs on an
error), and one hung save blocks the whole progress sync queue (`Tracker.syncPending` is single-flight). Separately,
any non-200 answer while renewing the MyAnimeList token (a 5xx, a 429) signs the user out, although the access token
is still valid for up to a day at that point.

## Current state

- `lib/net.dart`: `HttpNet._get` (≈ 39–57) awaits `httpClient.get(uri, headers: all)` with no limit. `streamBytes`
  (≈ 96–113) and `openGet` (≈ 117–123) await `httpClient.send(...)` with no limit. `postJson` (≈ 68–89) already has
  `.timeout(const Duration(seconds: 30))`. `h2Get` (≈ 132 on) has a timeout on incoming messages; check whether
  connecting is bounded too. The `Net` contract says failures are an `HttpException` (or a `CloudflareChallenge`), and
  callers rely on it (e.g. `lib/sources.dart` catches `on HttpException`).
- Direct `package:http` calls with no limit: `lib/anilist.dart:224` (`AniList.query`), `lib/mal.dart:80` (`_grant`),
  `lib/mal.dart:314` (`_get`) and `_mine` (≈ 137 on), `lib/jellyfin.dart:48` (`_post`), `:94`, `:104`, `:357`
  (`report`), `lib/jellyseerr.dart:45`, `:73-74`, `lib/extensions.dart:138`. Find any others with
  `grep -rn "http\.\(get\|post\|put\|patch\|delete\|send\)(" lib`.
- `lib/mal.dart` `_grant` (≈ 79–98): on any non-200, `if (form['grant_type'] == 'refresh_token') await logout();` then
  throws. `_bearer()` (≈ 127–135) renews when under a day is left and lets the renewal's exception propagate.

## Steps

1. In `lib/net.dart` add one shared limit, e.g. `const patience = Duration(seconds: 30);`, documented in the file's
   comment style.
2. `HttpNet._get`: bound the wait for the answer and bound **silence** while the body arrives, not the whole download
   (a large HLS segment on a slow line must not be cut off while bytes are still flowing). One way: `httpClient.send`
   with `.timeout(patience)`, then read the body through `res.stream.timeout(patience)`. Turn a `TimeoutException`
   into `HttpException('Timed out', uri: uri)` so the `Net` contract holds.
3. `streamBytes` and `openGet`: bound the wait for the response headers the same way, and apply the same silence limit
   to the returned body stream. Check each caller (`lib/hls_proxy.dart`, `lib/downloads.dart`) still handles the error
   it now gets; downloads already retry or fail a download on an exception, confirm that and do not add new handling
   unless something would crash.
4. If connecting in `h2Get` is unbounded, bound it with the same limit.
5. Add `.timeout(patience)` (import it from `net.dart`, or a local constant where importing would create a cycle) to
   every direct `package:http` call listed above. Exception: the Jellyfin Quick Connect poll loop keeps polling, but
   each individual request is bounded. Do not wrap `Analytics`, `pairing.dart`, `cloudflare.dart` or `settings.dart`
   calls that already have their own limit.
6. Confirm the AniList to MyAnimeList fallback in `lib/tracker.dart` (≈ 349) catches whatever `AniList.query` now
   throws on a timeout. If it only catches a narrower type, widen nothing in the tracker; instead throw a type it
   already catches from `AniList.query`.
7. MyAnimeList renewal, `lib/mal.dart`:
   - In `_grant`, sign out only when MyAnimeList actually rejects the refresh token (HTTP 400 or 401). Any other
     status, a timeout or a network error throws without signing out.
   - In `_bearer()`, when renewal fails and the user is still signed in and `_expires` is still in the future, carry
     on with the current access token instead of failing the request. Once it has really expired, propagate.

## Test plan

- `test/site_adapters_test.dart` or a new `test/net_test.dart`: with `httpClient` set to a `MockClient` (see how
  existing tests set it) whose answer never completes, `fetch(...)` fails with an `HttpException` after the limit. Use
  `fakeAsync` or a test-only shorter limit; do not add real 30-second waits to the suite.
- A body that keeps arriving in chunks for longer than the limit in total still succeeds.
- `test/mal_test.dart` (follow its existing setup): a 503 on renewal with an unexpired access token keeps the user
  signed in and the request proceeds; a 400/401 on renewal signs out; a 503 with an already expired token throws and
  stays signed in.
- `lib/mal.dart` uses the top-level `http.post`; if its tests cannot intercept that, follow whatever seam
  `test/mal_test.dart` already uses, and say so in the report if a case could not be covered.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Format | `fvm dart format lib test` | exit 0, only files you touched change |
| Analyze | `fvm flutter analyze` | `No issues found!` |
| Tests | `fvm flutter test` | `All tests passed!` (352 passing before this plan) |

## Scope

`lib/net.dart`, `lib/anilist.dart`, `lib/mal.dart`, `lib/jellyfin.dart`, `lib/jellyseerr.dart`,
`lib/extensions.dart`, and tests. Out of scope: retry policies, connection pooling for HTTP/2 (marked `ponytail:` on
purpose), `lib/anilist.dart` `airingAround` (plan 008 edits it), `lib/sources.dart` (plan 010 edits it).

## Git

Branch `advisor/006-bound-network-waits`. Two commits: `fix: time-limit network requests` and
`fix: keep the MyAnimeList session when renewal fails temporarily`. No trailers. Do not push.

## STOP conditions

- A caller depends on a request being allowed to take longer than the silence limit (report which).
- Bounding a call needs changes outside the scope list.
- A verification fails twice after a reasonable fix attempt.

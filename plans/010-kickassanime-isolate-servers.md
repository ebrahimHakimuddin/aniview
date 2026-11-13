# Plan 010: KickAssAnime: one failing server must not fail the episode

> **Executor instructions**: Follow the steps, run every verification, and stop on a STOP condition instead of
> improvising. The reviewer maintains `plans/README.md`; do not edit it.
>
> **Drift check (run first)**: `git diff --stat 5ceb40e..HEAD -- lib/sources.dart` must be empty. If not, compare the
> excerpt below with the live code; on a mismatch, STOP.

- **Priority** P2 · **Effort** S · **Risk** LOW · **Category** bug · **Planned at** `5ceb40e`, 2026-11-13

## Why this matters

The KickAssAnime adapter reads each server's embed page in a loop and means to skip a server that fails ("Another
server can still work"). It catches only `HttpException` and `FormatException`. A connection error
(`SocketException`, `http.ClientException`, a TLS error, a timeout) or markup of an unexpected shape (a `TypeError`
from a cast such as `server['src'] as String`) escapes the loop, so one bad server makes the whole episode report an
error even when another server would have played.

## Current state (`lib/sources.dart` ≈ 476–521)

```dart
final streams = <VideoStream>[];
for (final server in detail['servers'] as List? ?? []) {
  try {
    final embed = Uri.parse(base).resolve(server['src'] as String);
    final html = await net.text('$embed', headers: _headers);
    ...
  } on HttpException {
    // Another server can still work.
  } on FormatException {
    // Older/unsupported player pages are not playable sources.
  }
}
return streams;
```

`CloudflareChallenge` (`lib/net.dart`) is how a site asks for manual verification; the UI handles it when it
propagates. Check how the other adapters in this file isolate a failing server and follow the same pattern if one
exists.

## Steps

1. Catch any failure per server so the loop continues, **except** `CloudflareChallenge`, which must still propagate
   (rethrow it). Catch `Object`, not just `Exception`, so a `TypeError` from odd markup is covered.
2. Do not hide a total failure: if no stream was found and at least one server failed with an error, rethrow the last
   error after the loop so the user sees a real message (and the player can offer another site) instead of an empty
   "no streams" answer. If every server simply had no playable manifest, keep returning the empty list.
3. Keep the two existing comments' meaning in whatever catch replaces them.

## Test plan (`test/kickass_test.dart`, follow its existing fake `Net`)

- Two servers, the first throws a `SocketException` (or `http.ClientException`): the second server's stream is
  returned.
- First server's entry has no `src` (a `TypeError`): the second server's stream is returned.
- Every server throws: the call throws (not an empty list).
- A `CloudflareChallenge` from a server propagates.
- Existing tests keep passing unchanged.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Format | `fvm dart format lib/sources.dart test/kickass_test.dart` | exit 0 |
| Analyze | `fvm flutter analyze` | `No issues found!` |
| Tests | `fvm flutter test` | `All tests passed!` (352 passing before this plan) |

## Scope

The KickAssAnime server loop in `lib/sources.dart` and `test/kickass_test.dart`. Do not touch other adapters or
`lib/net.dart` (plan 006 edits it).

## Git

Branch `advisor/010-kickassanime-isolate-servers`, one commit,
`fix: skip a failing KickAssAnime server instead of failing the episode`, no trailers. Do not push.

## STOP conditions

- Callers treat a thrown error from `videos` differently enough that step 2 changes what users see for an episode
  that has no servers at all (report how).
- A verification fails twice after a reasonable fix attempt.

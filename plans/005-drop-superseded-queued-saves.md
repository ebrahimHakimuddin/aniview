# Plan 005: Stop a queued progress save from overwriting a newer one

> **Executor instructions**: Follow the steps, run every verification, and stop on a STOP condition instead of
> improvising. The reviewer maintains `plans/README.md`; do not edit it.
>
> **Drift check (run first)**: `git diff --stat 5ceb40e..HEAD -- lib/tracker.dart` must be empty. If not, compare the
> excerpts below with the live code; on a mismatch, STOP.

- **Priority** P0 · **Effort** S · **Risk** LOW · **Category** bug · **Planned at** `5ceb40e`, 2026-11-13

## Why this matters

A save that fails is queued per show and retried later. A newer save for the same show that succeeds does not remove
the queued one, and then immediately triggers the retry. Example: mark episode 5 while AniList errors (queued), then
mark episode 6 and it succeeds; `syncPending()` replays the queued 5, and the account ends at 5 while the app shows 6.
The same happens with status changes (Completed replaced by an older Watching).

## Current state (`lib/tracker.dart`)

- `save()` (≈ 440–464): builds `job`, calls `_push(p, job)`; on failure `_queue(p, job)`; on success
  `syncPending().ignore()`. Nothing removes the show's older queued job on success.
- `_push()` (≈ 468–492): the forward-only guard (`job['forwardOnly'] != false && progress <= await p.progressOf(id)`)
  hides the bug for player-driven saves, but manual saves pass `forwardOnly: false`.
- `_queue()` (≈ 539–545): key is `'${media['id'] ?? 'mal:${media['idMal']}'}'`, one job per show and account, stored
  as JSON under `p.pendingKey` in `SharedPreferences`.
- `_syncPending()` (≈ 551–568): reads the pending map once, pushes each entry, then re-reads and removes only the
  entries whose JSON is unchanged.

## Steps

1. Extract the queue key into one private helper (e.g. `_pendingKeyOf(Map media)`) and use it in `_queue`.
2. In `save()`, when `_push` succeeds, remove this show's entry from the pending map for `p` **before** calling
   `syncPending()` (await the removal). Removing a key that is not there must be a no-op without a write.
3. Close the in-flight race: in `_syncPending`, before pushing each entry, re-read the pending map and skip the entry
   if its JSON no longer equals what was read at the start (it was replaced or removed by a newer save). Keep the
   existing "re-read before writing" logic at the end.
4. `removeFromList()` (≈ 523–529) has the same hazard: a queued save would re-add a show just removed. After a
   successful `p.remove(id)`, drop the show's queued entry too.

## Test plan (`test/tracker_test.dart`, follow its existing fakes and setup)

- A save that fails (queued), then a save for the same show that succeeds: the provider's final saved progress is the
  newer one, and the pending map has no entry for the show. Use `forwardOnly: false` (the default) so the guard does
  not mask it.
- Same for status: queued `CURRENT`, then successful `COMPLETED`, ends `COMPLETED`.
- A queued save for show A is still sent when a save for show B succeeds (no over-removal).
- Remove-from-list after a queued save: the show is not re-added by `syncPending()`.

If the existing fakes cannot make a provider fail on demand, extend the fake in the test file, not production code.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Format | `fvm dart format lib/tracker.dart test/tracker_test.dart` | exit 0 |
| Analyze | `fvm flutter analyze` | `No issues found!` |
| Tests | `fvm flutter test` | `All tests passed!` (352 passing before this plan) |

## Scope

Only `lib/tracker.dart` and `test/tracker_test.dart`. Do not change the pending-store format (queued jobs from older
versions must still load), `ListProvider`, or the AniList/MAL adapters.

## Git

Branch `advisor/005-superseded-queued-saves`, one commit, message `fix: drop a queued save once a newer one succeeds`,
no trailers. Do not push.

## STOP conditions

- The excerpts do not match the live code.
- The fix needs a change to the stored job format or to files outside the scope.
- A verification fails twice after a reasonable fix attempt.

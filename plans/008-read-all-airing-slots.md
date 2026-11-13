# Plan 008: Read every airing slot for Schedule and episode notifications

> **Executor instructions**: Follow the steps, run every verification, and stop on a STOP condition instead of
> improvising. The reviewer maintains `plans/README.md`; do not edit it.
>
> **Drift check (run first)**: `git diff --stat 5ceb40e..HEAD -- lib/anilist.dart
> android/app/src/main/kotlin/com/kidfury/aniview/EpisodeJob.kt` must be empty. If not, compare the excerpts below with
> the live code; on a mismatch, STOP.

- **Priority** P1 · **Effort** S · **Risk** LOW · **Category** bug · **Planned at** `5ceb40e`, 2026-11-13

## Why this matters

Both the Schedule tab and the hourly new-episode notification job ask AniList for one page of 50 airing slots. The
Schedule window is two weeks (a week back, a week ahead), so someone following more than about 25 airing shows loses
the later days of the schedule. The notification job has the same cap on its window (up to `MAX_WINDOW`). The job
also advances `last_check` after the list request failed for a temporary reason, so that hour's episodes for
list-only shows are never notified, although the comment says the catch is for an expired token.

## Current state

- `lib/anilist.dart` `airingAround` (≈ 528–544): one query, `Page(perPage:50){airingSchedules(mediaId_in:$ids,
  airingAt_greater:$from,airingAt_lesser:$to,sort:TIME){episode airingAt media{$_media}}}`, returns
  `data['Page']['airingSchedules']`. `airingPopular` just below shows the file's style for multi-page requests.
  `AniList.transport` is the test seam (`@visibleForTesting`).
- `EpisodeJob.kt` `check` (≈ 88–121): reads `ids`, adds the signed-in user's CURRENT/REPEATING `mediaId`s inside a
  `try { ... } catch (_: Exception) { /* signed out on the web (expired token) */ }`, runs the same one-page
  `airingSchedules` query, posts a notification per slot, then `prefs.edit().putLong("last_check", now).apply()`.
  `anilist()` (≈ 123–141) throws `Exception("AniList: HTTP <code>")` on a non-200 and lets I/O exceptions through.

## Steps

1. `airingAround`: add `pageInfo{hasNextPage}` and a `$page` variable, and request pages until `hasNextPage` is false,
   with a hard cap of 6 pages (300 slots). Requests may run one after another; keep the result order (soonest first).
   Keep the doc comment accurate ("one request" is no longer always true).
2. `EpisodeJob.check`, airing query: paginate the same way with the same cap.
3. `EpisodeJob.check`, list request: tell an auth failure from a temporary one. Make `anilist()` throw something the
   caller can inspect for the HTTP status (a small private exception class with the code is enough). On 400, 401 or
   403 keep today's behaviour (carry on with the recently watched ids). On anything else (5xx, 429, an I/O error),
   return from `check` **without** writing `last_check`, so the next run covers this window. `MAX_WINDOW` already
   bounds how far back a later run looks; confirm that and say so in the report.
4. Confirm that when the airing query itself throws, `last_check` is not advanced (it should already propagate before
   the write) and that whatever calls `check` handles the exception (WorkManager retry or a logged failure, not a
   crash loop). Report what you find; fix only if it would crash.

## Test plan

- `test/library_test.dart` or wherever `airingAround`/the schedule is already tested (grep `airingAround` under
  `test/`): with `AniList.transport` faked to answer two pages (`hasNextPage: true`, then `false`), the result has
  both pages' slots in order, and the second request carried `page: 2`. A fake that always says `hasNextPage: true`
  stops at the cap.
- Kotlin has no unit tests in this repo. Verify it compiles: from `android/`, `./gradlew :app:compileDebugKotlin`
  (the first run may take several minutes). If the Android toolchain is not usable in your checkout, say so plainly
  in the report rather than claiming it compiles.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Format | `fvm dart format lib/anilist.dart test` | exit 0, only files you touched change |
| Analyze | `fvm flutter analyze` | `No issues found!` |
| Tests | `fvm flutter test` | `All tests passed!` (352 passing before this plan) |
| Kotlin | `cd android && ./gradlew :app:compileDebugKotlin` | `BUILD SUCCESSFUL` |

## Scope

`lib/anilist.dart` (`airingAround` only; plan 006 edits `AniList.query` in the same file, do not touch it),
`EpisodeJob.kt`, and tests. Out of scope: `airingPopular`, notification content, scheduling of the job.

## Git

Branch `advisor/008-read-all-airing-slots`. Two commits: `fix: read every page of airing slots` and
`fix: recheck the hour when the notification list request fails`. No trailers. Do not push.

## STOP conditions

- AniList's `airingSchedules` page shape differs from what the code assumes (no `pageInfo`).
- The job's caller would retry in a tight loop when `check` returns early.
- A verification fails twice after a reasonable fix attempt.

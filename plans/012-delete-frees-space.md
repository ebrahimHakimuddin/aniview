# Plan 012: Deleting a download must not leave the index and the disk disagreeing

> **Executor instructions**: Confirm the finding in the live code first (line numbers are approximate). Follow the
> steps, run every verification, and stop on a STOP condition instead of improvising. The reviewer maintains
> `plans/README.md`; do not edit it. Planned at `f0b41d2`, 2026-11-13.

- **Priority** P1 · **Effort** M · **Risk** MED · **Category** bug

## Why this matters

`Downloads.remove` and `removeAll` (`lib/downloads.dart` ≈ 590–635) drop the item from memory, start an
asynchronous index write (`_notify(save: true)`), then delete the files whatever happens to that write. When the
write fails (typically a full disk) `storageError` is set: the index on disk still lists the episode as done but its
files are gone, and `_requireStorage()` then refuses every further delete, which is the one action that would free
space.

## Decision (made by the maintainer's advisor)

Deleting must always be able to free space. So: delete the files first, then write the index; if that write fails,
try it once more now that space has been freed; only then surface the storage error. An index that lists an episode
whose files are gone must never be the lasting result of a delete that the user saw succeed.

## Steps

1. Read how `_notify`, `_saving`, `storageError`, `_requireStorage` and the recovery flow
   (`test/storage_recovery_test.dart`, `recoverTo`/`moveTo`) work before changing anything.
2. `remove`: keep stopping the active download first; delete the gallery copy and the files; then write the index and
   await it; on failure retry the write once; if it still fails, leave `storageError` set as today.
3. `removeAll`: same order and the same single retry.
4. A delete must be allowed while `storageError` is set **if** the error came from a failed index write (so the user
   can free space); keep refusing when storage is genuinely unavailable (missing folder, revoked permission). If the
   code cannot tell these apart, STOP and report what it would take.
5. On load, an index entry marked done whose files are missing should not be presented as playable: check what
   happens today and fix only if it shows as done-and-broken.

## Test plan

`test/downloads_test.dart` and `test/storage_recovery_test.dart` show how the store is faked. Cases: index write
fails once then succeeds (delete completes, no `storageError`, files gone, index without the item); index write
keeps failing (files gone, `storageError` set, a further `remove` is still possible and succeeds once writes work);
`removeAll` equivalents; the happy path is unchanged.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Format | `fvm dart format <files you touched>` | exit 0 |
| Analyze | `fvm flutter analyze` | `No issues found!` |
| Tests | `fvm flutter test` | `All tests passed!` (381 passing before this plan) |

Widget tests run on a fake clock: do not use real sockets or real timers in them (a `Stream.timeout` only ends when
the test does), and add new tests at the end of an existing test file rather than the start.

## Scope

`lib/downloads.dart` and tests. Not `DownloadService.kt`. The folder-naming code from plan 009 stays as it is.

## Git

Branch `advisor/012-delete-frees-space`, one commit, `fix: let deleting a download free space on a full disk`, no
trailers. Do not push.

## STOP conditions

- Step 4's distinction cannot be made with what the code knows.
- The change would alter the on-disk index format.
- A verification fails twice after a reasonable fix attempt.

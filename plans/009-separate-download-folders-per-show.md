# Plan 009: Give two shows with the same title separate download folders

> **Executor instructions**: Follow the steps, run every verification, and stop on a STOP condition instead of
> improvising. The reviewer maintains `plans/README.md`; do not edit it.
>
> **Drift check (run first)**: `git diff --stat 5ceb40e..HEAD -- lib/downloads.dart` must be empty. If not, compare
> the excerpts below with the live code; on a mismatch, STOP.

- **Priority** P1 · **Effort** S · **Risk** LOW · **Category** bug (silent data loss) · **Planned at** `5ceb40e`, 2026-11-13

## Why this matters

A download's folder is named from the show's title only. Two different shows with the same title (remakes, a film
and a series, or titles that become equal once illegal characters are stripped) share
`<Title>/Episode <n>-<sub|dub>`. Downloading episode N of the second writes over the first's episode N, and removing
either one deletes the folder the other still points at.

## Current state (`lib/downloads.dart`)

- `Download.relativeFolder` (≈ 66): `storagePath ?? id`. `Download.exportFolder` (≈ 67–73): sanitised
  `titleOf(media)` (empty becomes `Anime`) plus `/Episode ${epNumber(number)}-${dub ? "dub" : "sub"}`.
- `_download` (≈ 694–697): `if (d.storagePath == null && !await _dir(d).exists()) d.storagePath = d.exportFolder;`
  then `_dir(d).create(recursive: true)`. `storagePath` is persisted with the download, so existing downloads keep
  their folder.
- `remove` (≈ 566–582) deletes `_dir(d)` (or the SAF folder `d.relativeFolder` under `d.storageUri`).
- Find every other reader of `exportFolder` / `storagePath` with grep (the move-storage and gallery code use them).

## Steps

1. Where `_download` assigns `d.storagePath`, detect a clash: another item in `items` with a **different**
   `media['id']` whose `relativeFolder` is under the same show folder (the part of `exportFolder` before the last
   `/`). On a clash use a show folder with the id appended, `<Title> [<media id>]/Episode …`. With no clash the folder
   name stays exactly as today.
2. Keep it deterministic for the rest of that show: once one episode of a show uses the suffixed folder, later
   episodes of the same show use the same show folder (look at the show's existing items first and reuse their show
   folder), so a show's episodes never split across two folders.
3. Do not rename or move any existing download. Downloads that already collide on disk are not repaired by this plan;
   say so in the report.
4. Check the other `exportFolder` readers found by grep and make sure they use the download's stored `storagePath`
   (via `relativeFolder`) rather than recomputing the unsuffixed name for a download that already has one. Fix only
   what would point at the wrong folder.

## Test plan (`test/downloads_test.dart`, follow its existing fakes)

- Two shows, different ids, same title, same episode number: after both are assigned folders, the two
  `relativeFolder`s differ, the first is unchanged from today's naming, and the second carries the id.
- A second episode of the suffixed show goes into the same suffixed show folder.
- Removing one show's episode leaves the other's folder in place.
- A single show still gets today's exact folder name (no suffix).

If folder assignment cannot be reached from a test without a network download, extract it into a small method that
takes the download and the current items, and test that directly.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Format | `fvm dart format lib/downloads.dart test/downloads_test.dart` | exit 0 |
| Analyze | `fvm flutter analyze` | `No issues found!` |
| Tests | `fvm flutter test` | `All tests passed!` (352 passing before this plan) |

## Scope

`lib/downloads.dart` and `test/downloads_test.dart`. Out of scope: the order of index write and file deletion in
`remove`/`removeAll` (audit finding 5, deliberately deferred because the right behaviour on a full disk needs a
decision), `DownloadService.kt`, the storage-move flow beyond step 4.

## Git

Branch `advisor/009-download-folder-per-show`, one commit,
`fix: keep same-titled shows in separate download folders`, no trailers. Do not push.

## STOP conditions

- An existing download's folder would change.
- The SAF (custom folder) path needs different handling than the app-storage path and it is not obvious how.
- A verification fails twice after a reasonable fix attempt.

# Plan 015: Keep posters on disk between launches

> **Executor instructions**: Confirm the finding in the live code first (line numbers are approximate). Follow the
> steps, run every verification, and stop on a STOP condition instead of improvising. The reviewer maintains
> `plans/README.md`; do not edit it. Planned at `f0b41d2`, 2026-11-13.

- **Priority** P2 · **Effort** M · **Risk** LOW–MED · **Category** performance

## Why this matters

`Artwork` (`lib/ui.dart` ≈ 1312) shows every poster with `Image.network`, which caches in memory only. Every cold
start downloads all artwork again, and offline (Downloads, Recently watched, My list from cache) posters are blank
colour blocks.

## Decision (made by the maintainer's advisor)

A small disk cache of our own, with no new dependency: `path_provider` is already here.

## Steps

1. Add an `ImageProvider` (in `lib/ui.dart` or a new small `lib/image_cache.dart`) that loads from a file in the
   app's cache directory (`getApplicationCacheDirectory()`), keyed by a hash of the URL, and otherwise downloads
   through the existing `httpClient`/`fetchBytes` in `lib/net.dart` (so it is time-limited and fakeable), writes the
   file atomically (temp file, then rename) and decodes the bytes. Two requests for one URL share one download.
2. Keep `Artwork`'s behaviour: `cacheWidth` downscaling (wrap with `ResizeImage` as `Image.network`'s `cacheWidth`
   does), the fade-in `frameBuilder`, the placeholder, and whatever `errorBuilder` exists.
3. Bound the cache: about 200 MB, trimmed oldest-first by last use, checked at most once per launch and off the UI's
   critical path. A read should refresh the file's last-use time cheaply (or trim by modification time and accept
   least-recently-written; say which).
4. Failures never break the image: an unreadable or corrupt file is deleted and fetched again; a failed write still
   shows the downloaded image; no cache directory (tests, odd platforms) falls back to plain network loading.
5. Only `Artwork` changes. Other `Image.network` uses stay unless they show the same poster URLs; list them in the
   report.

## Test plan

New `test/image_cache_test.dart` with `httpClient` set to a `MockClient` and a temp directory as the cache: a second
load of one URL makes no request; a corrupt cached file is replaced; trimming removes the oldest files past the cap;
with the network failing, a cached URL still loads. Existing widget tests that pump `Artwork` must keep passing
without real I/O (check how they avoid network today and keep that working).

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Format | `fvm dart format <files you touched>` | exit 0 |
| Analyze | `fvm flutter analyze` | `No issues found!` |
| Tests | `fvm flutter test` | `All tests passed!` (381 passing before this plan) |

Widget tests run on a fake clock: do not use real sockets or real timers in them (a `Stream.timeout` only ends when
the test does), and add new tests at the end of an existing test file rather than the start.

## Scope

`lib/ui.dart`, an optional new `lib/image_cache.dart`, tests. No new packages in `pubspec.yaml`.

## Git

Branch `advisor/015-poster-disk-cache`, one commit, `feat: keep posters on disk between launches`, no trailers. Do
not push.

## STOP conditions

- Existing widget tests need real file I/O or hang with the new provider.
- It cannot be done without a new dependency.
- A verification fails twice after a reasonable fix attempt.

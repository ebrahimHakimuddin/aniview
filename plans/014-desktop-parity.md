# Plan 014: Desktop honours "Group related seasons" and reports screen views

> **Executor instructions**: Confirm the finding in the live code first (line numbers are approximate). Follow the
> steps, run every verification, and stop on a STOP condition instead of improvising. The reviewer maintains
> `plans/README.md`; do not edit it. Planned at `f0b41d2`, 2026-11-13.

- **Priority** P2 · **Effort** S–M · **Risk** LOW · **Category** parity

## Why this matters

Two gaps between the desktop UI (`lib/desktop/`) and the phone/TV UI:
- Settings → "Group related seasons" (`Settings.groupSeasons`) switches the phone's details page between
  `SeasonGroupSection` and the "Related" row (`lib/details.dart` ≈ 1080). The desktop details page
  (`lib/desktop/details_page.dart` ≈ 439) always shows relations, so the setting does nothing on Windows, macOS and
  Linux although it is offered there.
- No file under `lib/desktop/` calls `Analytics.screen`, so desktop usage never shows in Rybbit, while every phone
  screen reports itself (`grep -rn "Analytics.screen" lib`).

## Steps

1. Desktop details: when `Settings.groupSeasons` is on, show the grouped seasons in place of the related row. Reuse
   `SeasonGroupSection` if it lays out acceptably at desktop widths; otherwise wrap or adapt it in the desktop style
   (`lib/desktop/widgets.dart`). Changing the setting must take effect the next time a details page opens.
2. Desktop analytics: call `Analytics.screen` with the **same paths and fixed titles** the phone uses (`/`,
   `/search`, `/list`, `/schedule`, `/downloads`, `/settings`, `/details`, `/player`, …) from the matching desktop
   screens, once per visit (not on every rebuild). If the player or settings screens are shared with the phone and
   already report, do not double-report. For `/details` pass the same title argument the phone passes today.
3. Feature events (`Analytics.event`) that the phone sends from code the desktop does not share: list them in the
   report; add only the ones that are a one-line call at an existing desktop action.

## Test plan

`test/desktop_test.dart` and `test/layouts_test.dart` show how desktop pages are pumped. Cases: with the setting on,
the desktop details page shows the season group and not the related row; with it off, the reverse. For analytics,
if `Analytics` has no test seam, do not add one just for this: verify by reading and say so.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Format | `fvm dart format <files you touched>` | exit 0 |
| Analyze | `fvm flutter analyze` | `No issues found!` |
| Tests | `fvm flutter test` | `All tests passed!` (381 passing before this plan) |

Widget tests run on a fake clock: do not use real sockets or real timers in them (a `Stream.timeout` only ends when
the test does), and add new tests at the end of an existing test file rather than the start.

## Scope

`lib/desktop/*`, tests; `lib/details.dart` only to make `SeasonGroupSection` reusable if needed.

## Git

Branch `advisor/014-desktop-parity`. Two commits: `fix: group related seasons on desktop when the setting is on`
and `feat: report desktop screen views`. No trailers. Do not push.

## STOP conditions

- `SeasonGroupSection` cannot be reused without a redesign (report what it needs).
- A verification fails twice after a reasonable fix attempt.

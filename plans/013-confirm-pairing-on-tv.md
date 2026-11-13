# Plan 013: Pairing a phone needs a confirmation on the TV

> **Executor instructions**: Confirm the finding in the live code first (line numbers are approximate). Follow the
> steps, run every verification, and stop on a STOP condition instead of improvising. The reviewer maintains
> `plans/README.md`; do not edit it. Planned at `f0b41d2`, 2026-11-13.

- **Priority** P1 · **Effort** M · **Risk** MED · **Category** security

## Why this matters

While the TV's pairing screen is open, `Pairing._handle` (`lib/pairing.dart` ≈ 169–192) accepts `/pair` from any
device on the network and then `/remote`, which stores a persistent remote key and completes pairing with whatever
sign-in the caller sent. Nobody at the TV confirms anything: the code shown on the TV is never checked by the TV. So
any device on the Wi-Fi can become a permanent remote and sign a signed-out TV in to its own account.

## Decision (made by the maintainer's advisor)

The TV asks. After `/pair` the TV shows the code with "Does your phone show this code?" and Pair / Cancel buttons
(focusable with a remote, Cancel focused by default). `/remote` is only honoured after Pair is pressed for that
exact key agreement.

## Steps

1. Read the whole pairing flow first: the TV side (`pair`, `stopPairing`, `_handle`, `code`), the phone side (the
   `/pair` and `/remote` calls with their timeouts, ≈ 290, 536, 676), and the TV screen that shows `Pairing.code`.
2. TV: add a confirmed state tied to the current agreement (`_agreed`). A new `/pair` replaces the agreement and
   clears the confirmation. `/remote` for an unconfirmed agreement waits for the confirmation (up to about a minute)
   and then proceeds, or answers 403 when cancelled or timed out, without storing a key or completing pairing.
3. TV UI: the confirmation prompt described above, in the style of the existing pairing screen, usable with a D-pad.
4. Phone: wait long enough for the person to press Pair (raise the `/remote` timeout to match), show "Confirm on your
   TV" while waiting, and report a refusal clearly.
5. Compatibility: say in the report what happens between an old phone app and a new TV, and a new phone and an old
   TV. It must fail safe (no pairing without confirmation on a new TV); it need not be seamless.
6. Do not change the key agreement, the sealed message format, `/key`, or existing paired remotes.

## Test plan

`test/pairing_test.dart` shows how the handler is exercised. Cases: `/remote` before confirmation does not add a
remote key and does not complete `pair()`; after confirmation it does; Cancel answers 403 and stores nothing; a
second `/pair` invalidates an earlier confirmation; an already paired remote still works. Add a widget test for the
TV prompt (Cancel has initial focus; Pair confirms) following `test/tv_test.dart`.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Format | `fvm dart format <files you touched>` | exit 0 |
| Analyze | `fvm flutter analyze` | `No issues found!` |
| Tests | `fvm flutter test` | `All tests passed!` (381 passing before this plan) |

Widget tests run on a fake clock: do not use real sockets or real timers in them (a `Stream.timeout` only ends when
the test does), and add new tests at the end of an existing test file rather than the start.

## Scope

`lib/pairing.dart`, the TV pairing screen and the phone pairing sheet (wherever they live), tests.

## Git

Branch `advisor/013-confirm-pairing-on-tv`, one commit, `fix: confirm a new remote on the TV before pairing`, no
trailers. Do not push.

## STOP conditions

- The handler cannot hold a request open without blocking other requests (remote presses from paired phones).
- The change would invalidate existing pairings.
- A verification fails twice after a reasonable fix attempt.

# Plan 003: Let Schedule rows join hold-to-select ("Add to list")

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> 1. `git diff --stat 1fd219d..HEAD -- lib/library.dart lib/ui.dart` — if either file changed, compare the "Current
>    state" excerpts below against the live code before proceeding; on a mismatch, STOP.
> 2. **Prerequisite**: `grep -n "^class PickingScope" lib/library.dart` and `grep -n "^class Picking " lib/ui.dart` must
>    each print one line. At the planned-at commit these classes were still *uncommitted* in the maintainer's working
>    tree. If either is missing, STOP: the hold-to-select work must be committed (or restored) first.

## Status

- **Priority**: P1 (a user-reported gap in a feature that was asked to work "in all sections")
- **Effort**: S
- **Risk**: LOW
- **Depends on**: the hold-to-select work (`Picking`, `PickingProvider`, `PickingScope`) being committed — see drift check 2
- **Category**: bug
- **Planned at**: commit `1fd219d`, 2026-10-02 (the picking classes exist only in the working tree at that commit)

## Why this matters

Holding a poster on Home or Search starts a multi-select with an "Add to list" action. The user expected the same on
the Schedule tab and it does nothing, because Schedule does not use `PosterCard` — the widget that opts in — but its
own two card widgets, `_NextUp` and `_Slot`, which always open the show on tap and ignore long-press. After this plan,
holding any episode on Schedule starts the same selection (same bar, same "Add to list" sheet), tapping toggles while
picking, and selected rows are marked like selected posters.

## Current state

Files and their roles:
- `lib/ui.dart` — `Picking` (shared selection state, a `ChangeNotifier`), `PickingProvider` (an `InheritedNotifier`),
  `PosterCard` (the poster that joins picking), `FocusCard` (the focusable/tappable surface every card is built on).
- `lib/library.dart` — `PickingScope` (owns a `Picking`, shows the `SelectionBar` with "Add to list", runs the bulk save),
  `ScheduleScreen` / `_ScheduleScreenState` (the Schedule tab), `_NextUp` and `_Slot` (its two card widgets).
- `lib/home.dart` — builds `ScheduleScreen` in `_page()`; **do not edit** (it already passes everything needed).

The picking API, as it exists in `lib/ui.dart` (≈ lines 599–645):

```dart
class Picking extends ChangeNotifier {
  Map<Object?, Map>? picked;            // by id; null when not picking
  bool busy = false;
  bool get active => picked != null;
  bool has(Map media) => picked?.containsKey(media['id']) ?? false;
  void toggle(Map media) { /* adds/removes by media['id'], ticks, notifies */ }
  void clear() { ... }
  void setBusy(bool value) { ... }
  /// The picking around [context], if any; the caller rebuilds as picks change.
  static Picking? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PickingProvider>()?.notifier;
}
```

How `PosterCard` joins it (`lib/ui.dart` ≈ 1398–1436) — **this is the pattern to copy**:

```dart
final picking = this.selected == null && onLongPress == null ? Picking.of(context) : null;
final pickingNow = picking?.active == true ? picking : null;
final selected = this.selected ?? pickingNow?.has(media);
...
FocusCard(
  onTap: onTap ?? (pickingNow != null ? () => pickingNow.toggle(media) : () => openDetails(context, media, onBack: onBack)),
  onLongPress: onLongPress ?? (picking == null ? null : () => picking.toggle(media)),
  child: AspectRatio(... Stack(children: [ ..., if (selected case final picked?) ...[ <overlay> ] ]))
```

The selection overlay inside `PosterCard`'s `Stack` today (`lib/ui.dart` ≈ 1492–1522):

```dart
if (selected case final picked?) ...[
  AnimatedContainer(
    duration: const Duration(milliseconds: 180),
    decoration: BoxDecoration(
      color: picked ? scheme.primary.withValues(alpha: .22) : Colors.black.withValues(alpha: .15),
      border: picked ? Border.all(color: scheme.primary, width: 3) : null,
      borderRadius: BorderRadius.circular(radiusLarge),
    ),
  ),
  Positioned(
    top: 8, right: 8,
    child: AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      transitionBuilder: (child, a) => ScaleTransition(scale: a, child: child),
      child: Icon(
        picked ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
        key: ValueKey(picked),
        color: picked ? scheme.primary : Colors.white,
        shadows: const [Shadow(blurRadius: 6)],
      ),
    ),
  ),
],
```

The two Schedule cards in `lib/library.dart` (they are the problem):
- `_NextUp` (`class _NextUp extends StatelessWidget`, ≈ line 940): `return FocusCard(radius: radiusLarge, ..., onTap: () => openDetails(context, media, onBack: onChanged), child: SizedBox(height: isTv ? 220 : 170, child: Stack(fit: StackFit.expand, children: [Artwork(...), DecoratedBox(...gradient...), Positioned(... texts ...)])))`.
- `_Slot` (`class _Slot extends StatelessWidget`, ≈ line 1015): `return FocusCard(radius: nested(8, radiusSmall), ..., onTap: () => openDetails(context, media, onBack: onChanged), child: ColoredBox(color: scheme.surfaceContainer, child: Padding(padding: const EdgeInsets.all(8), child: Row(children: [ClipRRect(... SizedBox(width: 96, height: 54, child: Artwork(...))), SizedBox(width: 12), Expanded(Column(title, 'EP …')), Padding(time text)]))))`.
  Both get `final media = slot['media'] as Map;` at the top of `build`.
- `_ScheduleScreenState.build` (≈ line 705) returns `Scaffold(body: SafeArea(bottom: false, child: FutureBuilder(...)))`.
- `ScheduleScreen` fields: `schedule`, `allSchedule` (both `Future<List<Map>>`), `onRefresh`, `onChanged`. Each slot map is
  `{episode, airingAt (seconds), media}`; `media['id']` is the AniList id.

How `PickingScope` is used elsewhere (the pattern for wrapping a page), `lib/home.dart`:

```dart
Widget build(BuildContext context) => PickingScope(
  onChanged: () => home._reloadLists(force: true),
  child: _feed(context),
);
```

Conventions: widgets read colours through the global `scheme` getter (not `Theme.of`); corner radii come from the
named scale in `ui.dart` (`radiusSmall`, `radiusMedium`, `radiusLarge`, `nested(...)`); format with
`fvm dart format`. Commit messages: sentence-case imperative, no prefix, **no trailers** (no `Co-Authored-By`), e.g.
`Pause the player while a picker, dialog or the episode drawer is open`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Format | `fvm dart format lib/ui.dart lib/library.dart test/schedule_selection_test.dart` | exit 0 |
| Analyze | `fvm flutter analyze` | `No issues found!` |
| One test file | `fvm flutter test test/schedule_selection_test.dart` | `All tests passed!` |
| All tests | `fvm flutter test` | `All tests passed!` (72 before this plan; 73+ after) |

## Scope

**In scope** (the only files you should modify):
- `lib/ui.dart` — add one shared helper, `pickOverlay`, and make `PosterCard` use it (no behaviour change).
- `lib/library.dart` — wrap `ScheduleScreen`'s content in `PickingScope`; make `_NextUp` and `_Slot` join picking.
- `test/schedule_selection_test.dart` (create)

**Out of scope** (do NOT touch, even though they look related):
- `lib/home.dart`, `lib/search.dart` — already wrapped in `PickingScope`.
- The Featured carousel (`_FeaturedPage` in `lib/home.dart`) and Home's "Recently watched" row (it passes its own
  `onLongPress` to remove an entry from history, so it intentionally keeps that action). Do not change either; mention in
  the final report that they do not multi-select, so the maintainer can decide.
- `MyListScreen` / `RecentlyWatchedScreen` — they have their own earlier selection implementations.
- Changing what "Add to list" does (`_PickingScopeState._addTo`).

## Git workflow

- Branch: `advisor/003-schedule-hold-to-select`.
- Commit per step is fine; final message e.g. `Let Schedule rows join hold-to-select`. No trailers.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Share the selection overlay

In `lib/ui.dart`, add this top-level function next to `Picking` (above `/// A light tick under the finger…`):

```dart
/// What marks a card while picking several: a tint (and a ring once picked) with a check at the top right, or over the
/// leading still with [leading]. Goes last in the card's Stack. [radius] is the card's own corner.
List<Widget> pickOverlay(
  bool picked, {
  double radius = radiusLarge,
  bool leading = false,
}) => [
  AnimatedContainer(
    duration: const Duration(milliseconds: 180),
    decoration: BoxDecoration(
      color: picked
          ? scheme.primary.withValues(alpha: .22)
          : Colors.black.withValues(alpha: .15),
      border: picked ? Border.all(color: scheme.primary, width: 3) : null,
      borderRadius: BorderRadius.circular(radius),
    ),
  ),
  Positioned(
    top: leading ? 12 : 8,
    left: leading ? 12 : null,
    right: leading ? null : 8,
    child: AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      transitionBuilder: (child, a) => ScaleTransition(scale: a, child: child),
      child: Icon(
        picked
            ? Icons.check_circle_rounded
            : Icons.radio_button_unchecked_rounded,
        key: ValueKey(picked),
        color: picked ? scheme.primary : Colors.white,
        shadows: const [Shadow(blurRadius: 6)],
      ),
    ),
  ),
];
```

Then replace the whole `if (selected case final picked?) ...[ ... ],` block in `PosterCard` (the excerpt above) with:

```dart
if (selected case final picked?) ...pickOverlay(picked),
```

**Verify**: `fvm flutter analyze` → `No issues found!`; `fvm flutter test` → `All tests passed!` (nothing visible changed; the
existing `test/my_list_selection_test.dart` and `test/poster_row_test.dart` exercise `PosterCard`'s selection).

### Step 2: Wrap Schedule in `PickingScope`

In `lib/library.dart`, in `_ScheduleScreenState.build`, wrap the returned `Scaffold` the way Home does. Keep the existing
body unchanged:

```dart
@override
Widget build(BuildContext context) => PickingScope(
  onChanged: widget.onChanged,
  child: Scaffold( /* unchanged: body: SafeArea(bottom: false, child: FutureBuilder(...)) */ ),
);
```

**Verify**: `fvm flutter analyze` → `No issues found!`.

### Step 3: Make `_NextUp` and `_Slot` pick

In both widgets' `build`, right after `final media = slot['media'] as Map;`, add (same pattern as `PosterCard`):

```dart
final picking = Picking.of(context);
final pickingNow = picking?.active == true ? picking : null;
final picked = pickingNow?.has(media);
```

and change the `FocusCard` arguments in each:

```dart
onTap: pickingNow != null
    ? () => pickingNow.toggle(media)
    : () => openDetails(context, media, onBack: onChanged),
onLongPress: picking == null ? null : () => picking.toggle(media),
```

Then add the overlay as the **last** child of each card's content:
- `_NextUp`: its `Stack(fit: StackFit.expand, children: [...])` → append `if (picked != null) ...pickOverlay(picked),`
  (default radius `radiusLarge`, matching its `FocusCard(radius: radiusLarge)`).
- `_Slot`: its `FocusCard` child is currently `ColoredBox(color: scheme.surfaceContainer, child: Padding(...Row(...)))`.
  Change it to exactly this shape (the existing `ColoredBox…` stays **unchanged** as the first child, so it alone sizes
  the Stack and the row keeps its height):

  ```dart
  child: Stack(
    children: [
      ColoredBox(/* unchanged: color: scheme.surfaceContainer, child: Padding(...) */),
      if (picked != null)
        Positioned.fill(
          child: Stack(
            fit: StackFit.expand,
            children: pickOverlay(
              picked,
              radius: nested(8, radiusSmall),
              leading: true,
            ),
          ),
        ),
    ],
  ),
  ```

  The check then sits over the leading still (top-left), clear of the air time on the right.

Note that a show can have several slots (different days): picks are keyed by `media['id']`, so every slot of a picked
show shows as picked. That is intended.

**Verify**: `fvm flutter analyze` → `No issues found!`. Run `fvm flutter test` → `All tests passed!`.

### Step 4: Add the widget test (see Test plan), then format

**Verify**: `fvm dart format lib/ui.dart lib/library.dart test/schedule_selection_test.dart` → exit 0;
`fvm flutter test test/schedule_selection_test.dart` → `All tests passed!`.

## Test plan

Create `test/schedule_selection_test.dart`, modelled on `test/my_list_selection_test.dart` (same imports, same
`SharedPreferences.setMockInitialValues({})` + `await Settings.load()` + `AniList.token = 'test'` +
`addTearDown(() => AniList.token = null)` setup, same `MaterialApp(theme: buildTheme(), home: ...)` shell). Pump
`ScheduleScreen(schedule: Future.value(slots), allSchedule: Future.value(slots), onRefresh: () async {}, onChanged: () {})`.

Make the slots independent of the time the test runs: build `airingAt` (in **seconds**) from
`DateTime(now.year, now.month, now.day, 0, 0, 1)` — always today and already aired, so every slot renders as a `_Slot` row
and none becomes the "next up" card. Use three shows with ids 1, 2, 3 and titles `Show 1`…`Show 3`
(`{'id': 1, 'title': {'userPreferred': 'Show 1'}, 'coverImage': {'extraLarge': null}}`).

Cases:
1. Long-pressing the `Show 1` row shows `1 selected` and the `Add to list` tooltip button.
2. Then tapping `Show 2` shows `2 selected` and does **not** open a details page (`find.byType(DetailsScreen)` finds nothing).
3. Tapping `Show 1` again shows `1 selected`; tapping the `Done` (close) button removes the selection bar.
4. A second test with one slot at `DateTime(now.year, now.month, now.day, 23, 59, 59)` renders the `_NextUp` card (find by
   the `Next up` eyebrow text); long-pressing it also shows `1 selected`. (Skip this case only if the clock is within a
   second of midnight — don't add sleeps.)

**Verify**: `fvm flutter test test/schedule_selection_test.dart` → all pass, including the new tests.

## Done criteria

ALL must hold:

- [ ] `fvm flutter analyze` → `No issues found!`
- [ ] `fvm flutter test` → `All tests passed!`, with the new `test/schedule_selection_test.dart` cases present and passing
- [ ] `grep -n "pickOverlay" lib/ui.dart lib/library.dart` shows the definition in `ui.dart`, one use in `PosterCard`, and uses in `_NextUp` and `_Slot`
- [ ] `grep -n "borderRadius: BorderRadius.circular(radiusLarge)," lib/ui.dart` no longer matches inside `PosterCard`'s selection block (the duplicate was replaced)
- [ ] `git status --short` lists only `lib/ui.dart`, `lib/library.dart`, `test/schedule_selection_test.dart`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `PickingScope` or `Picking` is missing (drift check 2), or `_NextUp`/`_Slot`/`PosterCard` don't look like the excerpts.
- The selection overlay changes `_Slot`'s height or the day list's layout, and you can't fix it by positioning alone.
- Adding the overlay requires touching `lib/home.dart` or any file outside the scope list.
- A step's verification fails twice after a reasonable fix attempt.
- You find that `slot['media']['id']` is not an `int` for some slots (the bulk save assumes AniList ids) — report which.

## Maintenance notes

- Any new card type shown in a list of shows must opt in the same way (`Picking.of(context)` + `pickOverlay`), or it will
  silently not multi-select — this is exactly how Schedule was missed. If a third place needs it, consider a small
  `PickableCard` wrapper instead of repeating the pattern.
- Reviewer: check TV behaviour (hold OK on a row starts picking; `FocusCard` already maps it to `onLongPress`) and that
  tapping a row while picking never opens details.
- Deferred on purpose: the Featured carousel and Home's "Recently watched" row (its hold already means "remove from
  history"). If the maintainer wants multi-select there too, that needs a UX decision for the latter.

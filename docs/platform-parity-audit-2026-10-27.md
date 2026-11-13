# Platform feature parity audit

Date: 2026-10-27. Baseline: `7f5bc56` plus the current uncommitted working tree,
including the playback fixes and KickAssAnime adapter. This report describes that
working tree, not necessarily the published builds. Source code was not changed.

## Verdict and scope

**The platforms do not yet have equivalent functionality.** Core discovery,
tracking, watch history, built-in streaming sources and episode decisions share
Dart implementations. Separate layouts, native backends and platform services
introduce observable gaps. Treat “implemented” below as code evidence, not proof
of successful playback on every device.

Reviewed: Android phone, Android TV, iOS, Linux, macOS and Windows; user-facing
navigation, playback controls, downloads/storage, social access, notifications,
extensions, pairing, updates and verification coverage. Recovered two completed
read-only reviews from the interrupted audit, re-opened their evidence, and
requested an independent storage/platform-services review.

## Feature matrix

Legend: implemented = reachable code exists; gap = defect or absent equivalent;
limited = deliberate restriction or external dependency; unverified = native
behavior still needs execution on that OS.

| Capability | Android phone | Android TV | iOS | Linux | macOS | Windows |
|---|---|---|---|---|---|---|
| Browse, filters, schedule, lists, tracking, history | Implemented | Implemented | Implemented | Implemented | Implemented | Implemented |
| Built-in sources / Jellyfin | Implemented | Implemented | Implemented; native verification pending | Implemented | Implemented; native verification pending | Implemented; native verification pending |
| Search pagination error/retry | Implemented | Implemented | Implemented | Gap P-05 | Gap P-05 | Gap P-05 |
| Seek, speed, resume, subtitles, audio selection | Implemented | Implemented | Implemented; race P-04 | Implemented; race P-04 | Implemented; race P-04 | Implemented; race P-04 |
| Streaming quality preference / picker | Implemented | Implemented | Gap P-03 | HLS relay implementation | HLS relay implementation | HLS relay implementation |
| Skip filler via Next | Shared decision | Shared decision | Shared decision | Mouse gap P-01 | Mouse gap P-01 | Mouse gap P-01 |
| External video app | Implemented | Implemented | Broken exposed action P-02 | Broken exposed action P-02 | Broken exposed action P-02 | Broken exposed action P-02 |
| Discussion / friends / episode discussion | Implemented | Not exposed | Implemented | Implemented | Implemented | Implemented |
| Offline playback of supported downloads | Implemented | Implemented | Implemented; sandbox | Implemented | Implemented; custom-folder gap P-06 | Implemented |
| Download execution | Android foreground service | Android foreground service | Keep app foregrounded | While app process runs | While app process runs | While app process runs |
| MP4 conversion / export | Native conversion; gallery copy | Native conversion; platform-dependent folder UX | HLS retained; no gallery export | System ffmpeg, HLS fallback | System ffmpeg, HLS fallback | System ffmpeg, HLS fallback |
| Aniyomi APK extensions | Implemented | Implemented | Unavailable | Unavailable | Unavailable | Unavailable |
| Background new-episode notifications | Implemented | Android implementation | Unavailable | Unavailable | Unavailable | Unavailable |
| Control paired Android TV | Implemented | Hosts pairing | Unavailable by design | Client UI exists | Client UI exists; discovery unverified | Client UI exists; discovery unverified |
| Update path | APK install flow | APK install flow | Sideloading app | AppImage replacement / release page | Platform download/install flow | Platform download/install flow |

Shared UI/domain evidence: `lib/home_feed.dart`, `lib/tracker.dart`,
`lib/episode_actions.dart`, `lib/playback.dart`, `lib/home.dart:485`,
`lib/desktop/shell.dart`, `lib/desktop/profile.dart:4`, `lib/sources.dart:28`.
Storage/platform evidence: `lib/downloads.dart:281`, `:311`, `:656`,
`lib/notifications.dart:17`, `lib/sources.dart:1117`,
`lib/settings.dart:1414`, `:1451`, `:1558`, `:1665`, `:1684`, `:1706`, `:1817`,
`docs/ios.md:33-73`. Source availability and codecs remain source/device dependent.

## Prioritized findings

S = hours, M = approximately a day, L = multiple days; estimates include tests.
Confidence describes the evidence, not a claim that every native symptom was reproduced.

| ID | Priority | Finding | Impact | Effort | Fix risk | Confidence |
|---|---|---|---|---|---|---|
| P-01 | P1 | Desktop mouse Next bypasses Skip filler | Plays an episode keyboard/auto-next would skip | S | Low | High |
| P-02 | P1 | Unsupported external-player controls on iOS/desktop | Pauses playback then calls an absent platform method | S to gate; M+ for native support | Low to gate | High |
| P-03 | P1 | iOS streaming quality is a no-op | Preference ignored; no selectable heights | M | Medium | High |
| P-04 | P1 | Stale media_kit external-track work survives a new open | Old subtitles/audio may attach to another episode | M | Medium | High static confidence; race not reproduced here |
| P-05 | P2 | Desktop hides later-page search failures | Incomplete results, no visible retry | S | Low | High |
| P-06 | P1 | macOS custom-folder feature lacks sandbox access support | External folder selection/use and relaunch persistence at risk | M | Medium | High configuration evidence; native reproduction pending |
| P-08 | P1 | Unavailable desktop download folder blocks startup | Entire app unavailable; Settings recovery unreachable | M | Medium | High |
| P-09 | P1 | Partial desktop folder migration is not recoverable | Downloads split or missing from the active index | M | Medium | High |
| P-07 | P1 verification | Native parity is not an automated release gate | Passing Linux tests can miss OS-specific regressions | M–L | Low to runtime; medium CI effort | High |

### P-01 — Reuse the next-episode decision for mouse controls

Evidence: `lib/desktop/player_view.dart:78` uses `_load(index + 1)`, while
`lib/player.dart:405` uses `session.nextIndex` for N. `lib/playback.dart:86`
implements filler-aware selection. The mouse button is enabled with `hasNext`
from that shared decision but launches a different index.

Fix sketch: use the same session decision for the click. Preserve the existing
shared end-of-list policy; do not redesign filler semantics in this fix.
Acceptance: with episodes 1, 2(filler), 3, Next click, N and automatic next all
select episode 3; with skipping disabled, all select episode 2. Test the actual
control wiring, not only `PlaybackSession.nextIndex`.

### P-02 — Remove the unsupported handoff path, then implement equivalents deliberately

Evidence: `lib/desktop/player_view.dart:92` and `lib/player.dart:1530` expose the
action. `_openExternal` pauses at `lib/player.dart:1496`, then invokes
`AndroidApp.playExternal` via `lib/player.dart:612` and `lib/platform.dart:162`.
The catch at `lib/player.dart:625` handles `PlatformException`, not
`MissingPluginException`. iOS has a separate URL-opening bridge; desktop runners
do not implement Android's `external` method. Settings already hide the preference
off Android (`lib/settings.dart:1558`), but player controls do not.

Fix sketch: make action availability depend on an explicit handoff capability.
Keep Android behavior; hide or explain unavailable functionality elsewhere.
Restoring playback on a failed handoff needs coverage. Native desktop/iOS handoff
is a separate feature because URI launching alone does not provide position
return, subtitles, headers or external-audio parity.
Acceptance: unsupported platforms expose no enabled broken action; failed handoff
preserves the original play/pause state; Android successful handoff still saves
returned progress. Update `docs/ios.md:70-72`, which currently overstates that all
unsupported controls are hidden or guarded.

### P-03 — Select quality by backend capability, not desktop layout

Evidence: all platforms display the setting at `lib/settings.dart:1518`.
media_kit ignores the quality command (`lib/exo.dart:235`). Relay configuration
runs only under `isDesktop` (`lib/player.dart:558`), as does variant narrowing
(`lib/hls_proxy.dart:197`). iOS uses media_kit, but its menu reads backend heights
that media_kit never emits (`lib/player.dart:1450`).

Fix sketch: apply a shared media_kit quality policy to desktop and iOS without
changing the phone layout or Android Media3 behavior. Preserve position, pause,
subtitle/audio selection, source headers and separate HLS audio renditions.
Acceptance: a synthetic 360/720/1080 master honors a 720 cap and a manual 1080
selection on iOS, reports real heights, and retains audio. Use the existing iOS
fixture and integration test, extended for multiple variants. Do not equate a
Dart command assertion with a decoded resolution check.

### P-04 — Cancel obsolete external-track additions inside media_kit

Evidence: `lib/exo.dart:174` opens media, then `:185` waits for any future positive
duration. At `:194` and `:203` only disposal is checked before adding captured
external files. The first captured audio is actively selected (`:208`). A new
open or stop does not invalidate that pending work. The outer generation checks
in `ExoPlayer.load` run after backend open returns (`lib/exo.dart:398-412`).

Fix sketch: add an open-generation guard inside the backend, invalidated on
open/stop/dispose and checked after awaits and before track commands. Also inspect
whether subscribing after `mpv.open` can miss the already-arrived duration; that
is a related hypothesis needing a controlled reproduction, not a separate proven
bug in this audit.
Acceptance: delay episode A's load, open B, emit B's duration; no A audio/subtitle
is attached to B. Repeat with stop and dispose. Existing `test/exo_test.dart`
uses a fake backend and covers outer settlement, not this native-backend sequence.

### P-05 — Show desktop pagination errors and an explicit retry

Evidence: `lib/desktop/search.dart:121` shows errors only with zero results;
`:159` shows only a spinner in the populated-results footer. The scroll callback
at `:42` can call `session.more()` again after failure. The phone/TV equivalent
shows `ErrorState(... onRetry: search.more)` at `lib/search.dart:746`.

Fix sketch: show the compact error/retry footer while retaining results and stop
automatic pagination until retry or a new query.
Acceptance: page 1 succeeds, page 2 fails, existing posters remain, failure and
retry are visible, and one explicit retry appends page 2 without duplication.

### P-06 — Make custom download directories work in the macOS sandbox

Evidence: `macos/Runner/Release.entitlements:5` enables sandboxing but includes
only network client/server entitlements; `DebugProfile.entitlements` also lacks
user-selected file access. `lib/settings.dart:1699` exposes a directory picker on
all desktop platforms. `lib/downloads.dart:335` persists a plain path and `:311`
reuses it on launch. No security-scoped bookmark resolution exists in `lib/` or
`macos/`. The installed file_selector_macos README requires user-selected file
access for sandboxed applications.

Fix sketch: add the minimum user-selected read/write access and implement
persistent sandbox authorization, including stale/revoked folder recovery, or
restrict the feature until it is supported. Do not disable the sandbox as a fix.
Acceptance: in the packaged sandboxed macOS build, choose an external directory,
move/download/play files, terminate and relaunch, then play and write again.
Revoked access must show a recovery action rather than prevent startup.
`Downloads.load` is awaited before `runApp` (`lib/main.dart:35-45`), so folder
failures also deserve startup coverage. Native validation requires macOS. The requirements are documented by
[file_selector_macos](https://pub.dev/packages/file_selector_macos) and
[Apple sandbox persistent access](https://developer.apple.com/documentation/Security/accessing-files-from-the-macos-app-sandbox).

### P-07 — Establish a parity verification gate

Evidence: `.github/workflows/ci.yml:23-38` runs analysis and unit/widget tests on
Linux; other jobs compile/package platforms. `test/flutter_test_config.dart:8`
defaults to phone layout. Dedicated desktop tests exist, but that is not native
multi-OS coverage. `integration_test/ios_playback_test.dart:20` is the native iOS
test; it has no quality scenario. `docs/ios.md:23-28` explicitly records pending
physical playback validation and a simulator startup failure.

Fix sketch: add a parameterized capability/control contract suite, then synthetic
native playback smoke tests per supported backend/OS and remote-navigation tests
for TV. Keep third-party source checks opt-in. Record device/OS/build identifiers
and feature outcomes before claiming platform certification.
Acceptance: release evidence covers sign-in callbacks, supported source loading,
multivariant playback with audio/subtitles, quality switching, resume, offline
playback, download-folder persistence and unavailable-action handling. Failures
or skipped devices must remain visible. Do not label build success as playback
success. Existing CI plan 002 is already implemented; extend it rather than
creating a duplicate “add tests to CI” plan.

### P-08 — Allow startup when a desktop download directory is unavailable

Evidence: `lib/downloads.dart:316-320` creates the persisted root and reads its
index without a recovery boundary. `lib/main.dart:35-45` awaits this before
`runApp`. Resetting the chosen folder requires reaching Settings
(`lib/settings.dart:1693`). A disconnected drive or denied path therefore can
prevent access to the recovery control itself. This affects custom desktop
storage, including the macOS permission issue in P-06.

Fix sketch: represent unavailable storage explicitly while allowing browsing and
Settings to open. Offer reconnect/reselect/reset actions and hold the queue until
storage is available; do not silently discard the old index or download elsewhere.
Acceptance: an inaccessible-root launch reaches the app with a visible recovery
state; reconnecting restores the same indexed episodes and queued work. Cover
missing mounts, permission failure and an existing valid directory. Effort M;
medium risk because index identity and queued work must remain intact.

### P-09 — Make desktop download-folder migration transactional or resumable

Evidence: `lib/downloads.dart:335` persists the new folder before moving files.
`:340-348` moves entries one by one, deleting copied originals. On failure,
`:351-353` restores only the setting, not entries already moved. A later failure
can leave downloads split while the app resumes using the old root; interruption
can leave the new root persisted before the move completes.

Fix sketch: stage and verify a full copy before committing the destination, then
clean up originals, or use a persisted resumable migration journal. Preserve all
source media on failure; do not attempt a broad destructive rollback.
Acceptance: inject failure after one successful file move/copy and simulate restart
mid-migration; every prior episode/index remains discoverable or recoverable.
The happy-path test at `test/downloads_test.dart:146` does not cover either case.
Effort M; medium risk because this touches saved user media. Coordinate recovery
states with P-08 and macOS access with P-06 before finalizing the implementation.

## Deliberate differences and product choices

1. **TV social reading:** show Discussion/Friends and episode discussion are
   available on phone/desktop (`lib/details.dart:1097`,
   `lib/desktop/details_page.dart:68`) but TV proceeds from episodes to related
   shows (`lib/details.dart:1498`) and removes episode discussion
   (`lib/details.dart:537`, `:1830`). This is a real feature gap, not a proven
   accidental regression. A remote-friendly read-only social view is a reasonable
   M-sized parity feature; composing replies requires separate focus/input work.
   TV also omits episode multi-selection (`lib/details.dart:538`, `:1822`), so
   bulk episode operations need a remote-friendly interaction if they are part of
   the parity target. Individual episode actions remain available.
2. **Background services:** Android provides episode notifications and a download
   foreground service. iOS explicitly documents foreground-only downloads, no
   background episode job, and pause-on-background playback. Desktop downloads
   depend on the process remaining alive. These need OS-specific implementations
   and an agreed support contract, not merely removal of platform checks.
3. **Extensions and portable downloads:** APK extensions depend on Android's
   runtime and cannot be enabled by showing their settings elsewhere. Prefer
   maintaining equivalent built-in source coverage across platforms. Separate
   audio HLS downloads, including KickAssAnime, are rejected across all platforms
   (`lib/downloads.dart:780`): an important shared limitation, not a parity defect.
   MP4 conversion differs by platform but local HLS fallback preserves offline
   viewing; export parity should be scoped separately.

Other documented differences: iOS updates through the sideloading tool, has no
TV remote controls or gallery export, and uses hardware volume controls. Desktop
mouse/keyboard layouts, schedule week view and window controls are intentional
adaptations. Do not force identical layouts to achieve equivalent user outcomes.

## Recommended order and follow-up scope

- First: P-01, P-02 and P-05, each with its focused control test. These are small
  inconsistencies with existing shared behavior.
- Next: P-03 and P-04, with native/backend regression fixtures prepared before
  their changes. P-06, P-08 and P-09 should share a storage recovery contract; native P-06
  validation requires macOS, while failure tests for P-08/P-09 can run on Linux.
- P-07 is the cross-platform acceptance gate for the above, not a reason to delay
  all small fixes until an entire CI matrix exists.
- Then choose whether TV social reading and background-service equivalence are
  product requirements. Do not silently promise APK extension portability.

This is an audit and fix outline, not implementation approval or a set of selected
executor plans. Detailed numbered plans can follow the selected scope; existing
plans 001–004 are preserved.

## Considered and rejected

- Desktop episode row's empty helper callback: the actual row action is wired;
  the helper only renders a still/badge. Not a broken Play control.
- TV grouped filler indexing concern: TV bypasses episode grouping at
  `lib/details.dart:327`; not a confirmed bug.
- APK extension absence and iOS background/download/export restrictions: recorded
  as deliberate capability differences, not accidental native-method bugs.
- KickAssAnime split-audio download rejection: shared limitation, not OS drift.
- “All desktop quality is missing”: stale after this thread's relay changes;
  the remaining confirmed quality gap is iOS.

## Verification and limits

Run during this audit:

- `fvm flutter test --no-pub`: **313 passed, 5 skipped**.
- `fvm flutter analyze --no-pub`: **No issues found**.

No source fixes, packaging, publication or commits were made for this audit.
No fresh physical Android/TV/iPhone or native macOS/Windows execution was performed.
Not audited deeply: every codec/DRM path, every live provider, battery use,
performance, accessibility, dependency vulnerabilities, every auth recovery path,
or complete updater installation behavior. A feature being present in the matrix
must not be read as device certification.

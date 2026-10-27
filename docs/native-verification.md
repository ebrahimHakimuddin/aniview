# Native release verification

Release packaging in CI depends on `native-release-gate`. Builds and unit tests
remain useful checks, but do not certify native behavior. Missing, failed, skipped,
or pending native outcomes block packaging. Evidence must match the exact commit.
No platform has been certified by adding this gate.

1. Build the candidate commit on Android phone, Android TV, iOS device, Linux,
   sandboxed macOS, and Windows. Record device, OS version, build identity, tester,
   and UTC test time. Use the packaged configuration for storage and callbacks.
2. Run `python3 tool/ios_media_fixture.py` on the test host (requires ffmpeg).
   Run `fvm flutter test integration_test/native_playback_test.dart -d DEVICE`.
   For Android, `adb reverse tcp:8765 tcp:8765` connects to the fixture. For other
   devices, use a reachable host through `--dart-define=FIXTURE_ORIGIN=http://HOST:8765`
   and explicitly forward port 8765; the fixture binds only to loopback by default.
   Save test output. The shared native test checks decoded 720/1080 heights from
   a 360/720/1080 master, separate audio presence, subtitles, seeking and local playback.
   Confirm audio is audible too; track discovery alone does not prove sound.
3. Exercise the checks below in the candidate app. Attach logs/recordings to a
   durable HTTPS location. Automated fixture results cover only part of the gate.
4. Submit the JSON report through **Native verification evidence** on the candidate
   ref. Then dispatch **CI** on the same ref, supplying that run ID in
   `native_verification_run`. A changed commit requires new verification.
   The evidence workflow validates reports; it does not run devices or infer passes.

Each target requires `sign_in_callback`, `source_loading`, `native_playback`,
`quality_switch`, `audio_subtitles`, `resume`, `offline_playback`, `download_storage`,
`unavailable_actions`, `next_episode`, and `search_retry`. Android TV additionally
requires `remote_navigation`; Android phone and iOS require `orientation`.

- Sign in through the platform callback; load a supported source and play an episode
  that is not downloaded. Retry after entering the player from saved/offline context.
- Quality: Auto with a 720 cap, manual 1080, pause/resume, retained playback position,
  selected audio and subtitle; rapidly switch episode/server while tracks load.
- Next: mouse/touch, N where supported, and automatic advance select the same episode
  with filler skipping both on and off.
- Search: page 1 succeeds, page 2 fails, existing results remain, scrolling does not
  retry, explicit Retry appends page 2 once.
- Storage: restart and play saved files; disconnect/revoke the selected folder,
  reach Settings, reconnect/reselect/reset. Interrupt a migration after a partial
  copy and verify original media/index survive. On macOS, confirm new custom-folder
  selection is unavailable and sandbox storage survives relaunch.
- Android export: gallery disabled keeps private files only; enabled with a custom
  folder exports only there under anime title / episode folders; enabled without a
  custom folder exports to Movies/AniView. Play and delete each saved episode after
  relaunch, including legacy ID folders. Verify no duplicate gallery entry.
- Unsupported external-player controls are absent on iOS/desktop. Android handoff
  saves returned progress and restores prior playback on failure.
- TV Details: D-pad focus and selected Sub/Dub remain distinguishable in every theme; Sort is beside Play.
  Test dub fallback both off and on, including a missing dub followed by an episode with dub, network failure,
  and saved playback language. Customize subtitles and restart; check font, size, contrast, edge, and position.
  Toggle the global latest-episodes row and season grouping on/off; paginate and retry without losing results.
- Phone UI stays portrait with system auto-rotation enabled; player orientation is
  unchanged. TV navigation, focus, back and playback work with a remote.

Report shape (repeat for all six platform keys; never fill untested checks with pass):

```json
{
  "commit": "FULL_COMMIT_SHA",
  "platforms": {
    "android": {
      "device": "device model",
      "os_version": "OS version",
      "build": "version + build identifier",
      "tester": "tester name",
      "tested_at": "2026-10-27T12:00:00Z",
      "checks": {
        "native_playback": {"status": "pass", "evidence": "https://host/path/to/log"}
      }
    }
  }
}
```

Validate locally with `python3 tool/check_native_verification.py report.json --commit SHA`.
The gate checks report completeness and commit identity; the tester owns the
accuracy of evidence. Keep pending/failed outcomes in reports so blockers remain visible.
Local packaging scripts produce development artifacts; publish only artifacts from
the gated CI run, after all native outcomes pass.

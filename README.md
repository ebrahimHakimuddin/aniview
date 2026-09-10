# AniView

Flutter (Android) app for watching and tracking anime. Tracking is AniList (in-app sign-in); episodes and
streams come from third-party sites.

## Run

1. Create an AniList API client at https://anilist.co/settings/developer with redirect URL `aniview://auth`.
2. `fvm flutter run --dart-define=ANILIST_CLIENT_ID=<client id>`

## Extras

- Offline downloads save the HLS playlist, segments, encryption keys and preferred subtitles on-device. A
  downloaded episode is preferred during playback even when the network is available. Interrupted downloads
  resume when AniView next runs; downloads only progress while the app process is alive.
- **Download season** (⋮ next to SUB/DUB) queues every episode on the chosen site and audio, skipping ones
  already saved or queued and retrying failed ones.
- Downloaded shows keep their full episode list (titles, thumbnails, synopses) on-device. Offline, home opens
  on a **Downloaded** row and the details page shows the whole season; only downloaded episodes play.
- Long-press an episode to mark everything up to it watched on AniList (long-press a watched one to undo), or
  use **Mark season watched** in the ⋮ menu.
- Watch progress recorded offline is queued locally and synced to AniList when connectivity returns, without
  overwriting newer AniList progress.
- The details page links a show's prequels and sequels.
- The player includes an episode drawer and marks intro/outro ranges on the seek bar.
- Episode titles, synopses and thumbnails: [ani.zip](https://api.ani.zip)
- Intro/outro/recap skip times: [AniSkip](https://api.aniskip.com), falling back to the site's own times
- Some hosts disguise segments as PNGs; a localhost proxy (`lib/hls_proxy.dart`) strips the prefix for FFmpeg

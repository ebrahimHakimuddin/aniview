# AniView

Flutter (Android) app for watching and tracking anime. Tracking is AniList (in-app sign-in); episodes and
streams come from third-party sites.

## Run

1. Create an AniList API client at https://anilist.co/settings/developer with redirect URL `aniview://auth`.
2. `fvm flutter run --dart-define=ANILIST_CLIENT_ID=<client id>`

## Extras

- Episode titles, synopses and thumbnails: [ani.zip](https://api.ani.zip)
- Intro/outro/recap skip times: [AniSkip](https://api.aniskip.com), falling back to the site's own times
- Some hosts disguise segments as PNGs; a localhost proxy (`lib/hls_proxy.dart`) strips the prefix for FFmpeg

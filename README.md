# AniView

Flutter (Android) app for watching and tracking anime. Tracking is AniList or MyAnimeList (in-app sign-in);
episodes and streams come from third-party sites.

## Disclaimer

AniView does not host, store, upload or serve any video, subtitle or image content. Everything shown in the app
comes from third-party websites and APIs; AniView only fetches it from them at your request, like a browser
would. Downloads are saved on your own device only. AniView has no affiliation with and no control over these third parties, and is not responsible for their
content. Any takedown or copyright concerns should be addressed to the site that hosts the content.

## Run

1. Create an AniList API client at https://anilist.co/settings/developer with redirect URL `aniview://auth`.
2. Create a MyAnimeList API client at https://myanimelist.net/apiconfig ("other", no secret) with the same
   redirect URL `aniview://auth`.
3. `fvm flutter run --dart-define=ANILIST_CLIENT_ID=<client id> --dart-define=MAL_CLIENT_ID=<client id>`

Either client id can be left out; the app just loses that service.

## Release

Release APKs are signed with `android/app/aniview-release.jks`, configured by `android/key.properties`
(`storeFile`, `keyAlias`, `storePassword`, `keyPassword`). Both are gitignored: back them up, since updates only
install over builds signed with the same key.

1. Bump `version:` in `pubspec.yaml` and commit.
2. Build and publish:

   ```sh
   fvm flutter build apk --release --split-per-abi --dart-define=ANILIST_CLIENT_ID=<client id> \
     --dart-define=MAL_CLIENT_ID=<client id>
   git tag v1.5.2 && git push origin main v1.5.2
   gh release create v1.5.2 build/app/outputs/flutter-apk/app-*-release.apk --generate-notes
   ```

The app checks the latest GitHub release on launch and when you tap the version in Settings → About.

## Tracking

Sign into AniList, MyAnimeList, or both in Settings. Browsing (trending, this season, search, your lists) uses
AniList and falls back to MyAnimeList when AniList is unreachable; progress is written to every service you are
signed into, and queued on-device when they are all unreachable. MyAnimeList entries get their AniList id from
ani.zip when you open a show, since the streaming sources are keyed by it.

## Extras

- If an automatic match is wrong or missing, **Wrong show?** on the details page searches the site and remembers
  your pick per show and site (reset in Settings).

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

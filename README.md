# AniView

Flutter (Android) app for watching and tracking anime. Tracking is AniList (in-app sign-in), with
MyAnimeList's public data as a fallback for browsing; episodes and streams come from third-party sites.

## Disclaimer

AniView does not host, store, upload or serve any video, subtitle or image content. Everything shown in the app
comes from third-party websites and APIs; AniView only fetches it from them at your request, like a browser
would. Downloads are saved on your own device only. AniView has no affiliation with and no control over these third parties, and is not responsible for their
content. Any takedown or copyright concerns should be addressed to the site that hosts the content.

## Run

1. Create an AniList API client at https://anilist.co/settings/developer with redirect URL `aniview://auth`.
2. Create a MyAnimeList API client at https://myanimelist.net/apiconfig (app type "android"); only its client id
   is used, for public data.
3. Optionally, add a **mobile** site in [Rybbit](https://rybbit.com) for usage analytics and note its site id.
4. `fvm flutter run --dart-define=ANILIST_CLIENT_ID=<client id> --dart-define=MAL_CLIENT_ID=<client id> --dart-define=RYBBIT_SITE_ID=<site id>`

Any of these can be left out: without AniList's client id there's no tracking, without MyAnimeList's no fallback,
without a Rybbit site id no analytics. A self-hosted Rybbit is set with `--dart-define=RYBBIT_HOST=https://…`.

## Release

Release APKs are signed with `android/app/aniview-release.jks`, configured by `android/key.properties`
(`storeFile`, `keyAlias`, `storePassword`, `keyPassword`). Both are gitignored: back them up, since updates only
install over builds signed with the same key.

1. Bump `version:` in `pubspec.yaml` and commit.
2. Build and publish:

   ```sh
   fvm flutter build apk --release --split-per-abi --dart-define=ANILIST_CLIENT_ID=<client id> \
     --dart-define=MAL_CLIENT_ID=<client id> --dart-define=RYBBIT_SITE_ID=<site id>
   git tag v1.5.2 && git push origin main v1.5.2
   gh release create v1.5.2 build/app/outputs/flutter-apk/app-*-release.apk --generate-notes
   ```

The app checks the latest GitHub release on launch and when you tap the version in Settings → About.

## Tracking

Home, search and related shows come from AniList, and from MyAnimeList's public data when AniList fails.
Progress goes to AniList only. A save AniList can't take (down, or you're offline) is queued on-device and
retried when the app opens or returns to the foreground, and after the next save that goes through. Shows found through
MyAnimeList get their AniList id from ani.zip when opened.

## Analytics

With a Rybbit site id, the app sends screen views and a fixed set of events (`episode_play`, `episode_watched`,
`search`, `search_filter`, `download_queue`, `sign_in`) from `lib/analytics.dart`. Events carry AniList ids,
episode numbers, counts and fixed choices, never search text or account details; users are counted by a random
per-install id. The Rybbit site must be of type **mobile**: it accepts native traffic with only the public site
id, so no API key ships in the APK. Users can turn it off in Settings → About.

## Extras

- If an automatic match is wrong or missing, **Wrong show?** on the details page searches the site and remembers
  your pick per show and site (reset in Settings).

- Offline downloads save the HLS playlist, segments, encryption keys and preferred subtitles on-device. A
  downloaded episode is preferred during playback even when the network is available. Interrupted downloads
  resume when AniView next runs; downloads only progress while the app process is alive.
- **Download episodes…** (⋮ next to SUB/DUB) queues a range of episodes on the chosen site and audio, starting
  at the first unwatched one, skipping ones already saved or queued and retrying failed ones. Settings → Storage
  caps the download quality.
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

<p align="center">
  <img src="android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" alt="AniView" width="120">
</p>

<h1 align="center">AniView</h1>

<p align="center">
  Watch and track anime on Android phones and Android TV.<br>
  <a href="https://github.com/ebrahimHakimuddin/aniview/releases/latest">Download the latest release</a> · <a href="https://discord.gg/TXkEgGK9cp">Join the Discord</a>
</p>

<p align="center">
  <a href="https://www.buymeacoffee.com/kidfury"><img src="https://img.buymeacoffee.com/button-api/?text=Buy%20me%20a%20coffee&slug=kidfury&button_colour=FFDD00&font_colour=000000&font_family=Cookie&outline_colour=000000&coffee_colour=ffffff" alt="Buy me a coffee" height="48"></a>
</p>

Flutter app for watching and tracking anime on Android phones, Android TV, Windows, macOS, and Linux.
Sign in with AniList, MyAnimeList, or both; episodes and streams come from third-party sites.

## Disclaimer

AniView does not host, store, upload or serve any video, subtitle or image content. Everything shown in the app
comes from third-party websites and APIs; AniView only fetches it from them at your request, like a browser
would. Downloads are saved on your own device only. AniView has no affiliation with and no control over these third parties, and is not responsible for their
content. Any takedown or copyright concerns should be addressed to the site that hosts the content.

## Run

1. Create an AniList API client at https://anilist.co/settings/developer with redirect URL `aniview://auth`.
2. Create a MyAnimeList API client at https://myanimelist.net/apiconfig (app type "android") with redirect URL
   `aniview://mal`. Its client id enables browsing and sign-in using PKCE; no client secret ships in the app.
3. Optionally, add a **mobile** site in [Rybbit](https://rybbit.com) for usage analytics and note its site id.
4. `fvm flutter run --dart-define=TOP_SITES="$(fvm dart tool/top_sites.dart)" --dart-define=ANILIST_CLIENT_ID=<client id> --dart-define=MAL_CLIENT_ID=<client id> --dart-define=RYBBIT_SITE_ID=<site id>`

`TOP_SITES` is everythingmoe's ranking, read when the app is built; a rebuild picks up a new ranking.

Any of these can be left out: without a provider's client id its sign-in is unavailable; without MyAnimeList's there's no fallback,
without a Rybbit site id no analytics. A self-hosted Rybbit is set with `--dart-define=RYBBIT_HOST=https://…`.

## Release

Release APKs are signed with `android/app/aniview-release.jks`, configured by `android/key.properties`
(`storeFile`, `keyAlias`, `storePassword`, `keyPassword`). Both are gitignored: back them up, since updates only
install over builds signed with the same key.

1. Bump `version:` in `pubspec.yaml`, and `changelogVersion` and `changelogHighlights` in `lib/changelog.dart`, and
   commit. The highlights are Settings → About → What's new, and the dialog shown once on the first launch of a new
   version, which links to Buy me a coffee and the Discord.
2. Build and publish:

   ```sh
   fvm flutter build apk --release --split-per-abi \
     --dart-define-from-file=dart_defines.env \
     --dart-define=TOP_SITES="$(fvm dart tool/top_sites.dart)"
   git tag v2.4.0 && git push origin main v2.4.0
   gh release create v2.4.0 build/app/outputs/flutter-apk/app-*-release.apk \
     --title v2.4.0 --notes-file /tmp/aniview-v2.4.0-notes.md
   ```

   Prepare the short release notes file before the final command. Publish the three split APKs with their
   `app-*-release.apk` names so the in-app updater can select the device's ABI.

The app checks the latest GitHub release on launch and when you tap the version in Settings → About.

### CI artifacts

Every push to main, pull request, and manual CI run checks analysis and tests, then builds and uploads:

- Android release APKs for arm64-v8a, armeabi-v7a, and x86_64 (phones and Android TV).
- Windows x64 installer and macOS DMG, built on their native runners.
- Linux x86_64 AppImage, built in the pinned Debian forky container with WPE WebKit 2.54.

Configure `DART_DEFINES` as a GitHub Actions secret containing the entries in `dart_defines.env` to enable
account integrations. Fork PRs build without these values. For production Android signing, configure both
`ANDROID_KEYSTORE_BASE64` (the base64-encoded release keystore) and `ANDROID_KEY_PROPERTIES` (the contents of
`android/key.properties`, with `storeFile=aniview-release.jks`). Without them, APKs use the debug key and cannot
update a production installation signed with a different key. CI uploads artifacts; it does not publish releases.

The Linux AppImage requires glibc 2.43 or newer and system WPE WebKit 2.54 or newer with the FDO backend.
On Debian forky install `libwpewebkit-2.0-1 libwpebackend-fdo-1.0-1` and GStreamer codecs
(`gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav`). WPE's subprocesses and injected bundles
must match its libraries, so that runtime stays on the host. Ubuntu 24.04 and Debian 13 cannot run this artifact.
For a local build in Debian forky, run `bash tool/linux-deps.sh` as root, then `flutter build linux --release`
and `bash tool/appimage.sh`. Packaging verifies the downloaded linuxdeploy tool's checksum.

To build a separate installable beta with the local app configuration and current streaming-source ranking, run:

```sh
fvm flutter build apk --release --android-project-arg=aniviewBeta=true \
  --dart-define-from-file=dart_defines.env \
  --dart-define=TOP_SITES="$(fvm dart tool/top_sites.dart)" \
  --dart-define=ANIVIEW_BETA=true
```

Its app name is **AniView Beta** and its application id is `com.kidfury.aniview.beta`; the beta build does not offer
production APK updates.
The update APK downloads inside the app with a progress dialog, then goes to a PackageInstaller session, so
Android's own update prompt appears straight away (on TV the offer itself is a dialog). Android asks once to allow
installs from AniView. From Android 12, after AniView has installed itself this way, later updates need no prompt.
The app closes when it's replaced; a notification opens it again.

## Tracking

Home, search and related shows come from AniList, and from MyAnimeList's public data when AniList fails.
The first account signed in is the primary list; progress is saved there first and then to the other signed-in
account. Saves that fail are queued on-device and retried when the app opens or returns to the foreground,
and after the next successful save. Shows found through MyAnimeList get their AniList id from ani.zip when opened.
Desktop sign-in uses the default browser and an OS-registered `aniview://` callback. AniList's social features
and detailed time-watched statistics still require an AniList account.

On Android TV, discovery starts with popular shows and offers sorting and filters. Posters display English
titles when available and ratings; the focused search result has genres and a synopsis beside the grid.
Filters hide while browsing and return when focus moves to search. Use the clear button to erase a query.
Settings → Home screen lets you enable and reorder additional popular, top-rated, upcoming, and genre rows.

## New episode notifications

An Android background job (`EpisodeJob.kt`) runs hourly while online, with the app closed and across reboots. It
asks AniList which episodes aired since its last successful check, for shows on your AniList watching list plus
the ones you watched recently, and posts a notification for each; a missed check is caught up on the next run
(up to a day back). Tapping a notification opens that show's page. The app keeps the job's inputs current each
time home loads. Toggle it in Settings → Notifications.
The bell next to the home wordmark shows the past week's episode releases for your watching list and recently
watched shows. Opening it marks those entries as seen.

## Analytics

With a Rybbit site id, the app sends screen views and a fixed set of events (`episode_play`, `episode_watched`,
`search`, `search_filter`, `download_queue`, `sign_in`, `app_update`, `usage_stats`) from `lib/analytics.dart`. Events carry AniList ids,
episode numbers, counts and fixed choices, never search text or account details; users are counted by a random
per-install id. The Rybbit site must be of type **mobile**: it accepts native traffic with only the public site
id, so no API key ships in the APK. Users can turn it off in Settings → About.

## Extras

- If an automatic match is wrong or missing, **Wrong show?** on the details page searches the site and remembers
  your pick per show and site (reset in Settings).

- New Android downloads combine supported HLS streams into one MP4, or save a direct MP4, plus preferred subtitles. A
  downloaded episode is preferred during playback even when the network is available. Interrupted downloads
  resume when AniView next runs; downloads only progress while the app process is alive.
- Settings → Storage → Download folder lets you pick a folder for new offline episodes. Existing episodes stay
  where they were saved. The app stages a download in private storage, copies its completed video to the selected folder,
  then removes the staging copy; playback and deletion use the selected folder. Android's folder picker grants
  access across reboots. New Android episodes copy their MP4 and subtitles; older HLS downloads remain playable.
- **Download episodes…** (⋮ next to SUB/DUB) queues a range of episodes on the chosen site and audio, starting
  at the first unwatched one, skipping ones already saved or queued and retrying failed ones. Settings → Storage
  caps the download quality.
- Downloaded shows keep their full episode list (titles, thumbnails, synopses) on-device. Offline, home opens
  on a **Downloaded** row and the details page shows the whole season; only downloaded episodes play.
- Long-press an episode to mark everything up to it watched on AniList (or undo it) and to download or delete
  it, or use **Mark season watched** in the ⋮ menu.
- Watch progress recorded offline is queued locally and synced to AniList when connectivity returns, without
  overwriting newer AniList progress.
- The details page links a show's prequels and sequels.
- The player includes an episode drawer and marks intro/outro ranges on the seek bar.
- A phone can act as a TV remote (Settings → TV remote on the phone, Settings → Phone remote on the TV): D-pad,
  OK (hold for long-press), Back, playback keys, and typing into the TV's search box.
- **Hide NSFW shows** (Settings → Home screen, on by default on TV) keeps ecchi titles out of browse and search.
- Episode titles, synopses and thumbnails: [ani.zip](https://api.ani.zip)
- Intro/outro/recap skip times: [AniSkip](https://api.aniskip.com), falling back to the site's own times
- Some hosts disguise segments as PNGs; a localhost proxy (`lib/hls_proxy.dart`) strips the prefix for FFmpeg

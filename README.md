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

Flutter (Android) app for watching and tracking anime. Tracking is AniList (in-app sign-in), with
MyAnimeList's public data as a fallback for browsing; episodes and streams come from third-party sites.

The iPhone target (iOS 15+) uses native media_kit playback. See [iOS build, sideloading and testing](docs/ios.md)
for re-signable IPA builds, client-ID configuration and platform limitations. Android retains ExoPlayer.

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
4. `fvm flutter run --dart-define=TOP_SITES="$(fvm dart tool/top_sites.dart)" --dart-define=ANILIST_CLIENT_ID=<client id> --dart-define=MAL_CLIENT_ID=<client id> --dart-define=RYBBIT_SITE_ID=<site id>`

`TOP_SITES` is everythingmoe's ranking, read when the app is built; a rebuild picks up a new ranking.

Any of these can be left out: without AniList's client id there's no tracking, without MyAnimeList's no fallback,
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

The app checks for a newer release on launch and when you tap the version in Settings → About, and installs it from
inside the app. It looks for its own file in the release, so keep these names:

| | Release | Beta (pre-release) |
|---|---|---|
| Android | `app-<abi>-release.apk` | `AniView-Beta-<abi>.apk` |
| Windows | `AniView-windows-x64-setup.exe` | `AniView-Beta-windows-x64-setup.exe` |
| macOS | `AniView-macos.dmg` | `AniView-Beta-macos.dmg` |
| Linux | `AniView-x86_64.AppImage` | `AniView-Beta-x86_64.AppImage` |
| iOS (sideloaded) | `AniView-<version>-unsigned.ipa` | `AniView-Beta-<version>-unsigned.ipa` |

- **Android:** the APK downloads with a progress dialog, then goes to a PackageInstaller session, so Android's own
  update prompt appears straight away (on TV the offer itself is a dialog). Android asks once to allow installs from
  AniView; from Android 12, later updates need no prompt. The app closes when it's replaced; a notification opens it.
- **Windows:** the installer runs silently once AniView has closed, and opens the new version.
- **Linux:** the new AppImage replaces the running one and starts. Outside an AppImage, the release page opens.
- **macOS:** the sandbox keeps the app from replacing itself, so the disk image opens to drag it into Applications.
- **iOS:** updated through the sideloading app.

### Betas

A beta is **AniView Beta**, an app of its own that installs beside AniView on every platform, with its own data:
`com.kidfury.aniview.beta` on Android, iOS, macOS and Linux, and its own product name, folder and uninstall entry on
Windows. It updates from pre-releases only; AniView updates from releases only. `ANIVIEW_BETA` in the environment
switches the native builds (`linux/CMakeLists.txt`, `windows/runner/CMakeLists.txt`, `tool/appimage.sh`,
`tool/ios_ipa.sh`), and `--dart-define=ANIVIEW_BETA=true` the app.

1. Bump `version:` to `X.Y.Z-beta.N+build`, and `changelogVersion` and the highlights, and push to `main`.
2. Android, here:

   ```sh
   fvm flutter build apk --release --split-per-abi --android-project-arg=aniviewBeta=true \
     --dart-define-from-file=dart_defines.env \
     --dart-define=TOP_SITES="$(fvm dart tool/top_sites.dart)" --dart-define=ANIVIEW_BETA=true
   for abi in arm64-v8a armeabi-v7a x86_64; do
     cp build/app/outputs/flutter-apk/app-$abi-release.apk build/AniView-Beta-$abi.apk
   done
   ```

3. Linux, here (needs WPE WebKit 2.50+): `ANIVIEW_BETA=1 fvm flutter build linux --release …` with the same defines,
   then `ANIVIEW_BETA=1 tool/appimage.sh`.
4. Windows, macOS and iOS in CI: run the CI workflow on `main` with **beta** ticked
   (`gh workflow run ci.yml -f beta=true`), then `gh run download <run>` for the three packages.
5. `gh release create vX.Y.Z-beta.N --prerelease` with all of them.

## Tracking

Home, search and related shows come from AniList, and from MyAnimeList's public data when AniList fails.
Progress goes to AniList only. A save AniList can't take (down, or you're offline) is queued on-device and
retried when the app opens or returns to the foreground, and after the next save that goes through. Shows found through
MyAnimeList get their AniList id from ani.zip when opened.

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

- Offline downloads save the HLS playlist, segments, encryption keys and preferred subtitles on-device. A
  downloaded episode is preferred during playback even when the network is available. Interrupted downloads
  resume when AniView next runs; downloads only progress while the app process is alive.
- Settings → Storage → Download folder lets you pick a folder for new offline episodes. Existing episodes stay
  where they were saved. The app stages a download in private storage, copies its HLS files to the selected folder,
  then removes the staging copy; playback and deletion use the selected folder. Android's folder picker grants
  access across reboots.
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

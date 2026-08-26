# AniView

Flutter (Android) app for watching and tracking anime. Tracking is AniList (SSO); episodes and
streams come from third-party sites.

## Run

1. Create an AniList API client at https://anilist.co/settings/developer with redirect URL `aniview://auth`.
2. `fvm flutter run --dart-define=ANILIST_CLIENT_ID=<client id>`


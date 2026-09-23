# AniView domain

**Watch progress** (`lib/history.dart`, `WatchHistory`): where the user stopped in each show, kept on-device and
mirrored to the TV launcher's Continue watching row. It owns when an episode counts as watched (`finished`, from
the Settings percentage) and what a play does to history (`played`: keep the spot, move on to the next episode, or
drop a finished show). Distinct from **tracked progress**, the episode count on AniList (`mediaListEntry.progress`).

**Episode plan** (`EpisodePlan`): a show's episode list as the details page shows it: pages, the page it opens on,
the **up next** episode (lowest-numbered one not yet watched), and each episode's watched state and resume point.

**Playback session** (`lib/playback.dart`, `PlaybackSession`): the player's decisions about the episode playing,
apart from painting it: server fallback, when it counts as watched, when to save the spot, which skip applies,
when to offer or start the next episode (**up next**), what OK on a TV remote does, and where a held seek lands.

**Sites** (`lib/sources.dart`): the supported streaming sites from everythingmoe's ranking, in rank order. A
**source** is one site's adapter (Anikoto, animepahe, Re:Anime, Miruro); history and downloads remember it by name.

**Tracker** (`lib/tracker.dart`): browsing (AniList, with MyAnimeList as a read-only fallback), the AniList
session, and **tracked progress** saves, queued on-device when AniList can't take them.

**TV link** (`lib/pairing.dart`, `TvLink`): the TV's always-on Wi-Fi endpoint while the app runs on a TV. Phones
find it by broadcast, **pair** with it only while a pairing screen is open on the TV (both show a code the user
compares), then either sign it in to AniList or become a **phone remote**, whose key presses are sealed with the
pairing key and refused when replayed.

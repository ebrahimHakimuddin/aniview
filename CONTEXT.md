# AniView domain

**Watch progress** (`lib/history.dart`, `WatchHistory`): where the user stopped in each show, kept on-device and
mirrored to the TV launcher's Continue watching row. It owns when an episode counts as watched (`finished`, from
the Settings percentage) and what a play does to history (`played`: keep the spot, move on to the next episode, or
drop a finished show). Distinct from **tracked progress**, the episode count on AniList (`mediaListEntry.progress`).

**Episode plan** (`EpisodePlan`): a show's episode list as the details page shows it: pages, the page it opens on,
the **up next** episode (lowest-numbered one not yet watched), and each episode's watched state and resume point.


**Sites** (`lib/sources.dart`): the supported streaming sites from everythingmoe's ranking, in rank order. A
**source** is one site's adapter (Anikoto, animepahe, Re:Anime, Miruro); history and downloads remember it by name.

**Tracker** (`lib/tracker.dart`): browsing (AniList, with MyAnimeList as a read-only fallback), the AniList
session, and **tracked progress** saves, queued on-device when AniList can't take them.

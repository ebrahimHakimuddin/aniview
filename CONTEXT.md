# AniView domain

**Show** (`lib/anilist.dart`, `Show`): a show as AniList describes it (MyAnimeList's answers are mapped to the
same shape), read through its facts: title, cover, backdrop, score, its full **episodes** count (what list tracking
completes at) versus **aired** (episodes out so far), and the user's list entry. A typed view over the raw map.

**Watch progress** (`lib/history.dart`, `WatchHistory`): where the user stopped in each show, kept on-device and
mirrored to the TV launcher's Continue watching row. It owns when an episode counts as watched (`finished`, from
the Settings percentage) and what a play does to history (`played`: keep the spot, move on to the next episode, or
drop a finished show). Each entry is a **watch record** (`WatchRecord`: show, episode, position, site, audio);
the **resume point** is a record's position for the episode it names. Distinct from **tracked progress**, the episode count on AniList (`mediaListEntry.progress`).

**Episode plan** (`EpisodePlan`): a show's episode list as the details page shows it: pages, the page it opens on,
the **up next** episode (lowest-numbered one not yet watched), and each episode's watched state and resume point.
It also decides a show's **main action** (`nextUp`): resume the saved spot, else play the up next episode.

**Playback session** (`lib/playback.dart`, `PlaybackSession`): the player's decisions about the episode playing,
apart from painting it: **opening** it (its download, else the site's servers, from the resume point), server
fallback when a server never loads, which subtitles to show, when it counts as watched, when to save the spot, which skip applies,
when to offer or start the next episode (**up next**), what OK on a TV remote does, and where a held seek lands.

**Sites** (`lib/sources.dart`): the supported streaming sites from everythingmoe's ranking, in rank order. A
**source** is one site's adapter (Anikoto, animepahe, Re:Anime); history and downloads remember it by name.

**Tracker** (`lib/tracker.dart`): browsing (AniList, with MyAnimeList as a read-only fallback), the AniList
session, and **tracked progress** saves, queued on-device when AniList can't take them. Each **catalog**
(`Catalog`) answers browsing; AniList's and MyAnimeList's are its two adapters.

**Search session** (`lib/search.dart`, `SearchSession`): a search as it's typed: waits for typing to pause, skips a
single letter, browses by filters alone, drops answers to replaced searches, and pages on.

**Offline playback**: a download plays instead of streaming only in the chosen audio while the site can be reached,
and in either audio when it can't (`Downloads.toPlay`).

**TV link** (`lib/pairing.dart`, `TvLink`): the TV's always-on Wi-Fi endpoint while the app runs on a TV. Phones
find it by broadcast, **pair** with it only while a pairing screen is open on the TV (both show a code the user
compares). Pairing makes the phone a **phone remote**, whose key presses are sealed with the pairing key and
refused when replayed, and signs the TV in to the phone's AniList account when the TV has none. Each answer tells
the phone what's **now playing**, for its playback controls; its typing searches on the TV (never mid-episode).

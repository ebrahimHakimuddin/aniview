# AniView domain

**Watch progress** (`lib/history.dart`, `WatchHistory`): where the user stopped in each show, kept on-device and
mirrored to the TV launcher's Continue watching row. It owns when an episode counts as watched (`finished`, from
the Settings percentage) and what a play does to history (`played`: keep the spot, move on to the next episode, or
drop a finished show). Distinct from **tracked progress**, the episode count on AniList (`mediaListEntry.progress`).

**Episode plan** (`EpisodePlan`): a show's episode list as the details page shows it: pages, the page it opens on,
the **up next** episode (lowest-numbered one not yet watched), and each episode's watched state and resume point.

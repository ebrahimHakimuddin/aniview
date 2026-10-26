# KickAssAnime source

Added the ranked KickAssAnime entry, using kaa.lt (kaa.to redirects there).
Search uses POST /api/search, exact English/Romaji title matching avoids choosing another season,
and episode lists follow the API's pagination. Episode references retain their original number
so season renumbering does not select the wrong dubbed episode.

The current VidStreaming player publishes Astro-serialized manifest/subtitle properties.
The adapter reads those properties and sends the player's Referer and Origin with media requests.
Unsupported player pages are skipped. This does not implement older encrypted server formats.

Japanese and English episode entries can share the same multilingual master with Japanese as
its default. VideoStream now carries an optional audio language; the relay filters audio
renditions before desktop quality selection, so Dub actually selects English on this master.
Other sources retain their existing defaults.

Validation: 313 tests passed, 5 skipped; Flutter analysis passed. Live Blue Box season 2 episode 2
resolved 32 subtitle tracks including English, and FFmpeg decoded video/audio. A separate dub
check confirmed the English audio tag and decoded video/audio. Regression tests cover ranking,
search method, season matching, ambiguous titles, pagination, saved references, missing dubs,
unsupported/unavailable servers, subtitle extraction, and HLS audio selection.

The existing downloader refuses masters with separate audio renditions; KickAssAnime downloads
therefore remain unsupported. Device UI playback on Android/iOS has not been checked in this run.

Live check: `fvm flutter test tool/kickass_playback_test.dart`; add
`--dart-define=TEST_DUB=true` to check English dubbing. Requires ffprobe and ffmpeg.

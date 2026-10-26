# Source checks · 26 October 2026

Anikoto, ani.pm, and AnimeStream passed live search, automatic matching, episode-list,
sub/dub stream-resolution, HLS-playlist, and first-media-segment retrieval checks.
The sample was Attack on Titan (AniList 16498), episode 1, using the first returned
stream per audio. AnimeStream lists 26 entries including a special; all 25 numbered
episodes were present. Its search required the English title, which the app already
tries after the romaji title.

animepahe remained on Cloudflare verification during direct and browser checks.
The user also reported that it rarely works. It is now labelled Unstable and listed
last among built-in sources. Its internal name is unchanged so saved history and
downloads continue to resolve. Existing explicit source preferences are respected.
AnimeStream is included even when absent from the build-time ranking.

These checks verify retrieval, not full video/audio decoding, all titles, every
returned stream, sustained playback, or native browser clearance. Installed Aniyomi
extensions require an Android device; none was connected for these checks. Jellyfin
is user-configured and was not live-tested against a user's server.

Run the opt-in live checks (normal unit tests do not access these sites):

```sh
fvm flutter test tool/source_health_test.dart --name '^(Anikoto|ani.pm|AnimeStream):' --reporter expanded
```

Run the animepahe check explicitly to investigate future availability; it is expected
to fail while Cloudflare verification remains unsatisfied:

```sh
fvm flutter test tool/source_health_test.dart --plain-name 'animepahe:' --reporter expanded
```

## Beta 8 playback correction

The retrieval-only check missed a decoder failure on AnimeStream, Blue Box season 2,
episode 2 (upstream episode 27, “Admiration”), Japanese audio. The adapter incorrectly
converted the numeric media ID into a four-byte AES key. Preserving the upstream key
URL also failed: its response is base64-wrapped encrypted key material, not a raw key.

The adapter now follows the site's player: fetch key.bin with x-am-media-id, then
unwrap it with AES-CBC/PKCS7 using the first 16 bytes of SHA-256("key" + mediaId)
and SHA-256("iv" + mediaId) as the key and IV. Ordinary key URLs remain untouched.
The resolved key is validated as 16 bytes before passing it to playback.

A fixed encrypted fixture reproduces the bug and passes with the fix. The exact
reported episode now passes FFprobe and decodes one second of video and audio with
FFmpeg through AniView's localhost relay. This does not verify sustained playback
or an Android device.

```sh
fvm flutter test tool/animestream_playback_test.dart --reporter expanded
```

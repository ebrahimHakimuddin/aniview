# Desktop playback corrections

Reproduced with Blue Box season 2, episode 2, Japanese audio, on ani.pm and
AnimeStream.

- ani.pm uses an extensionless HLS entry URL. It was relayed as a binary file,
  bypassing playlist rewriting. HLS entry URLs now explicitly use the playlist
  relay. Subtitle renditions also retain WebVTT segment extensions instead of
  being labelled MPEG-TS, which FFmpeg rejects.
- AnimeStream's Netflix WebVTT header contains whitespace-only separator lines.
  FFmpeg accepted the file but produced zero subtitle packets. The relay now
  removes whitespace on otherwise blank WebVTT lines, preserving cue content and
  timing. The reported episode then yields 375 English subtitle cues.
- Desktop never supplied available heights to the quality menu; the native
  backend's quality command was unimplemented. Desktop now reads heights from
  the master playlist and applies the chosen cap in the relay. Changing quality
  reopens at the current position and restores subtitle selection and pause state.
  The HQ menu also appears for a single available resolution.

The live source data offers 1080/720/480/360/240/144p on ani.pm and only 720p on
AnimeStream for this episode. The app cannot select a higher AnimeStream rendition
that the source does not offer.

Validation:

```sh
fvm flutter test --no-pub
fvm flutter analyze --no-pub
fvm flutter test --no-pub tool/playback_diagnostic_test.dart --reporter expanded
```

The live check uses the actual localhost relay, checks available and decoded video
height, asserts an audio track, counts English subtitle packets on AnimeStream,
and decodes two seconds at 00:14 with both video and non-silent audio. Observed
peak audio levels were -4.4 dB for ani.pm and -16.3 dB for AnimeStream. These are
short decoder checks, not a full-episode or interactive desktop UI test.

#!/usr/bin/env bash
# Synthetic videos for integration_test/native_test.dart; requires ffmpeg/Python.
set -euo pipefail
fixture_dir=${1:-/tmp/aniview-native-fixtures}
mkdir -p "$fixture_dir/plain" "$fixture_dir/encrypted"
fixture_dir=$(cd "$fixture_dir" && pwd)
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=size=160x90:rate=15' \
  -f lavfi -i 'sine=frequency=440:sample_rate=44100' \
  -t 4 -c:v libx264 -pix_fmt yuv420p -g 15 -c:a aac -b:a 32k \
  -movflags +faststart "$fixture_dir/direct.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$fixture_dir/direct.mp4" \
  -c copy -hls_time 1 -hls_playlist_type vod \
  -hls_segment_filename "$fixture_dir/plain/segment_%03d.ts" \
  "$fixture_dir/plain/index.m3u8"
python3 - "$fixture_dir/encrypted/key.bin" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(bytes(range(16)))
PY
printf 'key.bin\n%s/encrypted/key.bin\n00112233445566778899aabbccddeeff\n' \
  "$fixture_dir" > "$fixture_dir/key-info.txt"
ffmpeg -hide_banner -loglevel error -y -i "$fixture_dir/direct.mp4" \
  -c copy -hls_time 1 -hls_playlist_type vod \
  -hls_key_info_file "$fixture_dir/key-info.txt" \
  -hls_segment_filename "$fixture_dir/encrypted/segment_%03d.ts" \
  "$fixture_dir/encrypted/index.m3u8"
printf 'Fixtures generated in %s\n' "$fixture_dir"
if [[ ${2:-} == --serve ]]; then
  exec python3 -m http.server 8765 --bind 0.0.0.0 --directory "$fixture_dir"
fi

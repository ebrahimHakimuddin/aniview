#!/usr/bin/env python3
"""Generate synthetic media and serve it to the iOS simulator (requires ffmpeg).

Run from the repository root. No third-party footage or credentials are used.
All files stay under the ignored build directory; requests must carry our test header.
"""

import functools
import http.server
from pathlib import Path
import subprocess


root = Path("build/ios-media-fixture").resolve()
root.mkdir(parents=True, exist_ok=True)
subprocess.run([
    "ffmpeg", "-y", "-loglevel", "error",
    "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=15",
    "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100",
    "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=44100",
    "-t", "20", "-map", "0:v", "-map", "1:a", "-map", "2:a",
    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "30",
    "-c:a", "aac", "-metadata:s:a:0", "language=jpn",
    "-metadata:s:a:1", "language=eng", "-movflags", "+faststart",
    str(root / "sample.mp4"),
], check=True)
subprocess.run([
    "ffmpeg", "-y", "-loglevel", "error", "-i", str(root / "sample.mp4"),
    "-map", "0:v", "-map", "0:a:0", "-c", "copy", "-hls_time", "2",
    "-hls_list_size", "0", "-hls_playlist_type", "vod",
    str(root / "index.m3u8"),
], check=True)
(root / "en.vtt").write_text(
    "WEBVTT\n\n00:00:00.000 --> 00:00:20.000\nAniView subtitle smoke test\n"
)


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("X-AniView-Fixture") != "1":
            self.send_error(403, "Missing test header")
            return
        super().do_GET()


server = http.server.ThreadingHTTPServer(
    ("127.0.0.1", 8765), functools.partial(Handler, directory=str(root))
)
print("Synthetic media ready at http://127.0.0.1:8765", flush=True)
server.serve_forever()

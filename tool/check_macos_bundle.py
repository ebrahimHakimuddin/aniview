#!/usr/bin/env python3
"""Check macOS playback/login configuration and, optionally, the app going into a DMG."""

import plistlib
from pathlib import Path
import subprocess
import sys


REQUIRED = (
    "com.apple.security.app-sandbox",
    "com.apple.security.network.client",
    # HlsProxy listens on loopback even when the video comes from the internet.
    "com.apple.security.network.server",
)


def check(data, label):
    missing = [key for key in REQUIRED if data.get(key) is not True]
    if missing:
        raise ValueError(f"{label}: missing enabled entitlements: {', '.join(missing)}")
    print(f"OK: {label}")


def check_url_scheme(info, label):
    schemes = {
        scheme
        for url_type in info.get("CFBundleURLTypes", [])
        for scheme in url_type.get("CFBundleURLSchemes", [])
    }
    if "aniview" not in schemes:
        raise ValueError(f"{label}: missing aniview URL scheme for browser sign-in")
    print(f"OK: {label} (aniview URL scheme)")


def main():
    if len(sys.argv) > 2:
        raise ValueError("Usage: python3 tool/check_macos_bundle.py [AniView.app]")
    root = Path(__file__).resolve().parents[1]
    for name in ("DebugProfile.entitlements", "Release.entitlements"):
        path = root / "macos" / "Runner" / name
        check(plistlib.loads(path.read_bytes()), name)
    check_url_scheme(
        plistlib.loads((root / "macos" / "Runner" / "Info.plist").read_bytes()),
        "Runner/Info.plist",
    )

    if len(sys.argv) == 2:
        app = Path(sys.argv[1]).resolve()
        subprocess.run(
            ["codesign", "--verify", "--deep", "--strict", "--all-architectures", str(app)],
            check=True,
        )
        info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
        check_url_scheme(info, f"{app.name}/Info.plist")
        executable = app / "Contents" / "MacOS" / info["CFBundleExecutable"]
        architectures = subprocess.check_output(
            ["lipo", "-archs", str(executable)], text=True
        ).split()
        for architecture in architectures:
            data = subprocess.check_output(
                ["codesign", "-d", "--arch", architecture, "--entitlements", "-", "--xml", str(app)]
            )
            check(plistlib.loads(data), f"{app.name} ({architecture})")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))

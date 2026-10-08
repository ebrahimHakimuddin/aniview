#!/usr/bin/env bash
# Repackage an existing release with the macOS playback/login configuration fixes.
# No Flutter SDK required. The input app and its saved data are never modified.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
source_app=${1:-/Applications/AniView.app}
out=${2:-"$root/build/macos-fixed"}
image="$out/AniView-macos-fixed.dmg"

if [[ ! -d "$source_app/Contents" ]]; then
  echo "App not found: $source_app" >&2
  exit 1
fi
if [[ -e "$image" ]]; then
  echo "Already exists: $image (choose a different output directory)" >&2
  exit 1
fi
codesign --verify --deep --strict --all-architectures "$source_app"
mkdir -p "$out"
stage=$(mktemp -d "$out/.stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/dmg"
ditto "$source_app" "$stage/dmg/AniView.app"

python3 - "$source_app" "$stage" "$root" <<'PY'
import plistlib
from pathlib import Path
import subprocess
import sys

source, stage, root = map(Path, sys.argv[1:])
entitlements = plistlib.loads(subprocess.check_output([
    'codesign', '-d', '--entitlements', '-', '--xml', str(source),
]))
entitlements['com.apple.security.network.server'] = True
(stage / 'Hotfix.entitlements').write_bytes(plistlib.dumps(entitlements))

info_path = stage / 'dmg' / 'AniView.app' / 'Contents' / 'Info.plist'
info = plistlib.loads(info_path.read_bytes())
if info['CFBundleIdentifier'] != 'com.kidfury.aniview':
    sys.exit('Expected the AniView release app (com.kidfury.aniview)')
source_info = plistlib.loads((root / 'macos/Runner/Info.plist').read_bytes())
url_types = source_info['CFBundleURLTypes']
for url_type in url_types:
    url_type['CFBundleURLName'] = info['CFBundleIdentifier']
info['CFBundleURLTypes'] = url_types
info_path.write_bytes(plistlib.dumps(info))
PY

# The distributed app is already ad-hoc signed. Re-sign only the changed outer
# bundle, preserving the bundled frameworks' existing signatures.
codesign --force --sign - --entitlements "$stage/Hotfix.entitlements" "$stage/dmg/AniView.app"
python3 "$root/tool/check_macos_bundle.py" "$stage/dmg/AniView.app"
ln -s /Applications "$stage/dmg/Applications"

# Build the HFS+ filesystem without mounting a temporary disk device.
hdiutil makehybrid -hfs -hfs-volume-name 'AniView Fixed' -o "$stage/raw.dmg" "$stage/dmg"
hdiutil convert "$stage/raw.dmg" -format UDZO -o "$image"
hdiutil verify "$image"
echo "Ready: $image"

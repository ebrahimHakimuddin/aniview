#!/usr/bin/env bash
# Validate and compile the Mac app, then package a locally signed DMG.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
defines=${1:-dart_defines.env}
if [[ ! -f "$defines" ]]; then
  echo "Missing build configuration: $defines" >&2
  exit 1
fi
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub --reporter expanded
python3 tool/check_macos_bundle.py
flutter build macos --release --no-pub --dart-define-from-file="$defines"

app_name=$(cat macos/Flutter/ephemeral/.app_filename)
app="build/macos/Build/Products/Release/$app_name"
python3 tool/check_macos_bundle.py "$app"
out="build/macos-review-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out/dmg"
ditto "$app" "$out/AniView.app"
ditto "$app" "$out/dmg/AniView.app"
ln -s /Applications "$out/dmg/Applications"
hdiutil makehybrid -hfs -hfs-volume-name 'AniView Mac Review' -o "$out/raw.dmg" "$out/dmg"
hdiutil convert "$out/raw.dmg" -format UDZO -o "$out/AniView-macos-review.dmg"
hdiutil verify "$out/AniView-macos-review.dmg"
rm "$out/raw.dmg"
printf '%s\n' "$root/$out" > build/macos-review-location.txt
echo "Build complete: $root/$out"

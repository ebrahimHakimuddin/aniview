#!/usr/bin/env bash
# Build an unsigned device archive and package it for AltStore/SideStore/Sideloadly to re-sign.
# With ANIVIEW_BETA set it's AniView Beta (com.kidfury.aniview.beta), which installs beside AniView.
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v fvm >/dev/null 2>&1; then
  flutter_cmd=(fvm flutter)
  dart_cmd=(fvm dart)
else
  flutter_cmd=(flutter)
  dart_cmd=(dart)
fi

"${flutter_cmd[@]}" pub get
# Fail before building if the ranking cannot be fetched, rather than shipping an empty source list.
top_sites="$("${dart_cmd[@]}" tool/top_sites.dart)"
test -n "$top_sites"
defines=("--dart-define=TOP_SITES=$top_sites")
[[ -n "${ANIVIEW_BETA:-}" ]] && defines+=("--dart-define=ANIVIEW_BETA=true")
defines_file="${DART_DEFINES_FILE:-dart_defines.env}"
if [[ -f "$defines_file" ]]; then
  defines+=("--dart-define-from-file=$defines_file")
elif [[ -n "${DART_DEFINES_FILE:-}" ]]; then
  printf 'DART_DEFINES_FILE does not exist: %s\n' "$defines_file" >&2
  exit 1
else
  printf 'Building without client IDs: public AniList browsing only; sign-in and MAL fallback unavailable.\n'
fi

"${flutter_cmd[@]}" build ipa --release --no-codesign "${defines[@]}"
app=build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app
python3 tool/check_ios_bundle.py "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist")
out="$PWD/build/ios/ipa"
mkdir -p "$out"
stage=$(mktemp -d "$out/staging.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/Payload"
# Do not serialize macOS extended attributes as ._* AppleDouble files in an IPA.
ditto --norsrc --noextattr --noqtn "$app" "$stage/Payload/Runner.app"
name=AniView
if [[ -n "${ANIVIEW_BETA:-}" ]]; then
  # Unsigned, so the bundle can still be renamed; the sideloading app signs it under this id.
  plist="$stage/Payload/Runner.app/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.kidfury.aniview.beta' "$plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName AniView Beta' "$plist"
  name=AniView-Beta
fi
ipa="$out/$name-$version-unsigned.ipa"
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$stage/Payload" "$ipa"
unzip -tq "$ipa"
python3 tool/check_ios_bundle.py "$ipa"
shasum -a 256 "$ipa"
printf '\nRequires signing before installation: %s\n' "$ipa"

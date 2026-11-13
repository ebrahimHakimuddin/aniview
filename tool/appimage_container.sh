#!/usr/bin/env bash
# Builds the Linux release and packs AniView-x86_64.AppImage inside the container of tool/appimage.Dockerfile, so the
# AppImage runs on systems older than this one. Arguments go to `flutter build linux --release` (the dart defines);
# ANIVIEW_BETA is passed on. Needs Docker and fvm. The source and this machine's Flutter are copied in, so build/,
# .dart_tool/ and the SDK here stay untouched.
set -euo pipefail
cd "$(dirname "$0")/.."
flutter=$(fvm flutter --version --machine | sed -n 's/.*"flutterRoot": *"\([^"]*\)".*/\1/p')
test -d "$flutter"
mkdir -p "${PUB_CACHE:-$HOME/.pub-cache}"
docker build -t aniview-appimage -f tool/appimage.Dockerfile tool
docker run --rm --user "$(id -u):$(id -g)" ${ANIVIEW_BETA:+-e ANIVIEW_BETA="$ANIVIEW_BETA"} \
  -v "$PWD":/src:ro -v "$PWD":/out -v "$flutter":/flutter:ro -v "${PUB_CACHE:-$HOME/.pub-cache}":/pub-cache \
  aniview-appimage bash -euo pipefail -c '
    mkdir -p "$HOME" /tmp/work && cp -a /flutter /tmp/flutter && export PATH=/tmp/flutter/bin:$PATH
    cd /tmp/work
    tar -C /src --exclude=./build --exclude=./.dart_tool --exclude=./.git --exclude=./output \
      --exclude="./*.AppImage" -cf - . | tar -xf -
    # The packer this machine already checked, rather than another download of it.
    if [ -f /src/build/linuxdeploy-x86_64.AppImage ]; then
      mkdir -p build && cp /src/build/linuxdeploy-x86_64.AppImage build/
    fi
    flutter config --no-analytics >/dev/null
    flutter pub get
    flutter build linux --release "$@"
    tool/appimage.sh
    cp AniView*-x86_64.AppImage /out/
  ' build "$@"

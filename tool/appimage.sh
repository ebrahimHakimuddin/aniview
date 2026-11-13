#!/usr/bin/env bash
# Packs build/linux/x64/release/bundle into AniView-x86_64.AppImage (run after `flutter build linux --release`; for a
# release, tool/appimage_container.sh does both on a system old enough for the AppImage to run elsewhere).
# With ANIVIEW_BETA set (for the build too), it's AniView-Beta-x86_64.AppImage, named AniView Beta.
set -euo pipefail
cd "$(dirname "$0")/.."
name=AniView out=AniView-x86_64.AppImage
if [ -n "${ANIVIEW_BETA:-}" ]; then name="AniView Beta" out=AniView-Beta-x86_64.AppImage; fi
out="$PWD/$out"
bundle=build/linux/x64/release/bundle
app="$PWD/build/AppDir"
rm -rf "$app" && mkdir -p "$app/usr/bin" "$app/usr/share/applications"
cp -r "$bundle"/. "$app/usr/bin/"
cat > "$app/usr/share/applications/aniview.desktop" <<D
[Desktop Entry]
Type=Application
Name=$name
Exec=aniview
Icon=aniview
Categories=AudioVideo;Video;
D
cp linux/packaging/aniview.png build/aniview.png
tool=build/linuxdeploy-x86_64.AppImage
[ -f "$tool" ] || curl -fsSL -o "$tool" https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
echo '8aea8da0f7f7039d2a2cecb14657d752a222a5e1d3825caeef186c82f751cdd1  build/linuxdeploy-x86_64.AppImage' | sha256sum --check
chmod +x "$tool"
# The video stack talks to the GPU driver, which has to match the host's Mesa, so those libraries come from the host, not from here.
# media_kit dlopen()s libmpv, so linuxdeploy can't see it; name it so its dependencies get bundled too.
mpv=$(ldconfig -p | awk '/libmpv\.so\.2 .*x86-64/{print $NF}' | head -1)
test -n "$mpv"
# linuxdeploy carries the patchelf used below.
deploy="$PWD/build/linuxdeploy"
rm -rf "$deploy" && mkdir "$deploy" && (cd "$deploy" && "../${tool#build/}" --appimage-extract >/dev/null)
patchelf="$deploy/squashfs-root/usr/bin/patchelf"
# A library with no soname (Arch's libmujs) is linked by its full path, which no other system has and linuxdeploy
# doesn't bundle: bundle a copy of libmpv that asks for it by name, and the library itself.
cp "$mpv" build/libmpv.so.2 && mpv="$PWD/build/libmpv.so.2"
extra=()
for needed in $("$patchelf" --print-needed "$mpv" | grep '^/' || true); do
  "$patchelf" --replace-needed "$needed" "$(basename "$needed")" "$mpv"
  extra+=(--library "$needed")
done
# WebKit runs pages in programs of its own and looks for them where the system keeps them, which only a machine with
# WPE WebKit installed has: bundle them, and (below) point the bundled library at the bundled copies.
wpe=$(ldconfig -p | awk '/libWPEWebKit-2\.0\.so\.1 .*x86-64/{print $NF}' | head -1)
test -n "$wpe"
helpers=$(strings -a "$wpe" | awk '/^\/usr\/lib.*\/wpe-webkit-2\.0$/ && !seen++')
test -d "$helpers"
mkdir -p "$app/usr/lib/wpe-webkit-2.0"
cp -r "$helpers"/WPE*Process "$helpers/injected-bundle" "$app/usr/lib/wpe-webkit-2.0/"
# The library can only be given a path of the same length, so a relative one: AppRun starts the app from the AppDir.
cat > build/AppRun <<'R'
#!/bin/sh
here=$(dirname "$(readlink -f "$0")")
cd "$here" && exec "$here/usr/bin/aniview" "$@"
R
chmod +x build/AppRun
"$deploy/squashfs-root/AppRun" --appdir "$app" --custom-apprun build/AppRun \
  --desktop-file "$app/usr/share/applications/aniview.desktop" --icon-file build/aniview.png \
  --executable "$app/usr/bin/aniview" --library "$mpv" "${extra[@]}" --library "$wpe" \
  --deploy-deps-only "$app/usr/lib/wpe-webkit-2.0" \
  --exclude-library "libva*" --exclude-library "libvdpau*" --exclude-library "libvulkan*" --exclude-library "libdrm*" \
  --exclude-library "libwayland-*" --exclude-library "libpulse*"
for helper in "$app"/usr/lib/wpe-webkit-2.0/WPE*Process; do "$patchelf" --set-rpath '$ORIGIN/..' "$helper"; done
for bundle in "$app"/usr/lib/wpe-webkit-2.0/injected-bundle/*.so; do
  "$patchelf" --set-rpath '$ORIGIN/../..' "$bundle"
done
# "usr////lib/wpe-webkit-2.0": as long as the system path, with slashes making up the difference.
relative="usr$(printf '/%.0s' $(seq $((${#helpers} - 21))))lib/wpe-webkit-2.0"
FROM="$helpers" TO="$relative" perl -0pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$app/usr/lib/$(basename "$wpe")"
OUTPUT=$out "$deploy/squashfs-root/AppRun" --appdir "$app" --output appimage
if grep -q "$helpers" "$app/usr/lib/$(basename "$wpe")"; then
  echo 'the bundled WebKit still looks for its programs on the system' >&2
  exit 1
fi
# Every bundled library must be findable inside the AppImage.
if grep -rl --include='*.so*' -e '' "$app/usr/lib" | xargs -r "$patchelf" --print-needed | grep '^/'; then
  echo 'a bundled library still links another by full path' >&2
  exit 1
fi

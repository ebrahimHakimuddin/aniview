#!/usr/bin/env bash
# Packs build/linux/x64/release/bundle into AniView-x86_64.AppImage (run after `flutter build linux --release`).
# With ANIVIEW_BETA set (for the build too), it's AniView-Beta-x86_64.AppImage, named AniView Beta.
set -euo pipefail
cd "$(dirname "$0")/.."
name=AniView out=AniView-x86_64.AppImage
if [ -n "${ANIVIEW_BETA:-}" ]; then name="AniView Beta" out=AniView-Beta-x86_64.AppImage; fi
bundle=build/linux/x64/release/bundle
app=build/AppDir
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
APPIMAGE_EXTRACT_AND_RUN=1 OUTPUT=$out "$tool" --appdir "$app" \
  --desktop-file "$app/usr/share/applications/aniview.desktop" --icon-file build/aniview.png \
  --executable "$app/usr/bin/aniview" --library "$mpv" \
  --exclude-library "libva*" --exclude-library "libvdpau*" --exclude-library "libvulkan*" --exclude-library "libdrm*" \
  --exclude-library "libwayland-*" --exclude-library "libpulse*" --output appimage

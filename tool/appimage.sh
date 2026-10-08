#!/usr/bin/env bash
# Packs build/linux/x64/release/bundle into AniView-x86_64.AppImage (run after `flutter build linux --release`).
set -euo pipefail
cd "$(dirname "$0")/.."
bundle=build/linux/x64/release/bundle
app=build/AppDir
rm -rf "$app" && mkdir -p "$app/usr/bin" "$app/usr/share/applications"
cp -r "$bundle"/. "$app/usr/bin/"
cat > "$app/usr/share/applications/aniview.desktop" <<D
[Desktop Entry]
Type=Application
Name=AniView
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
mpv=$(ldconfig -p | awk '/libmpv\.so\.2 .*x86-64/ && !found {found=$NF} END {print found}')
test -n "$mpv"
# WPE uses processes and injected bundles at absolute distribution paths. Keep
# its libraries with those system resources instead of packaging an incomplete
# WebKit runtime. Hosts need WPE WebKit >= 2.54 and the FDO backend (README).
APPIMAGE_EXTRACT_AND_RUN=1 OUTPUT=AniView-x86_64.AppImage "$tool" --appdir "$app" \
  --desktop-file "$app/usr/share/applications/aniview.desktop" --icon-file build/aniview.png \
  --executable "$app/usr/bin/aniview" --library "$mpv" \
  --exclude-library "libva*" --exclude-library "libvdpau*" --exclude-library "libvulkan*" --exclude-library "libdrm*" \
  --exclude-library "libwayland-*" --exclude-library "libpulse*" \
  --exclude-library "libWPE*" --exclude-library "libwpe*" --output appimage

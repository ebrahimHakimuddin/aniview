#!/usr/bin/env bash
# Run as root in Debian forky, which provides WPE WebKit >= 2.50.
set -euo pipefail
apt-get update
apt-get install -y --no-install-recommends \
  build-essential clang cmake ninja-build pkg-config curl git unzip xz-utils zip \
  libgtk-3-dev libepoxy-dev libsecret-1-dev libwpewebkit-2.0-dev \
  libwpebackend-fdo-1.0-dev libwpe-1.0-dev libwayland-dev libmpv-dev \
  patchelf file desktop-file-utils zsync ca-certificates \
  gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav
pkg-config --atleast-version=2.50 wpe-webkit-2.0

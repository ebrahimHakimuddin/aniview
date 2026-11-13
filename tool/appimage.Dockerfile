# Where tool/appimage_container.sh builds the Linux AppImage. An AppImage needs at least the glibc it was built
# against, and bundles the libraries of the system that built it, so this is the oldest system that has what the
# build needs (WPE WebKit, libmpv) rather than whatever the developer's machine runs. Flutter comes from the host.
FROM debian:trixie
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl file git unzip xz-utils zip \
      clang cmake ninja-build pkg-config libstdc++-14-dev \
    && rm -rf /var/lib/apt/lists/*
RUN apt-get update && apt-get install -y --no-install-recommends \
      libgtk-3-dev liblzma-dev libmpv-dev libepoxy-dev libmimalloc-dev libsecret-1-dev libwayland-dev \
      libwpewebkit-2.0-dev libwpe-1.0-dev libwpebackend-fdo-1.0-dev \
    && rm -rf /var/lib/apt/lists/* \
    && git config --system --add safe.directory '*'
# Plugins that fetch a dependency configure it with CMake's default generator and compiler.
RUN apt-get update && apt-get install -y --no-install-recommends make gcc g++ \
    && rm -rf /var/lib/apt/lists/*
ENV HOME=/tmp/home PUB_CACHE=/pub-cache

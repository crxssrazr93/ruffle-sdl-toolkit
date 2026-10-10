# Cross-compile ruffle_sdl (Ruffle on SDL2 + GLES 3) for aarch64 against glibc 2.31 (Ubuntu 20.04)
# so the binary runs on every PortMaster CFW (muOS, Knulli, ROCKNIX, ArkOS, ...).
# It links the firmware's libSDL2 (2.0.10 or newer) and libasound.
FROM ubuntu:20.04
ENV DEBIAN_FRONTEND=noninteractive
RUN printf '%s\n' \
      "deb [arch=amd64] http://archive.ubuntu.com/ubuntu focal main universe" \
      "deb [arch=amd64] http://archive.ubuntu.com/ubuntu focal-updates main universe" \
      "deb [arch=amd64] http://security.ubuntu.com/ubuntu focal-security main universe" \
      "deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports focal main universe" \
      "deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports focal-updates main universe" \
      "deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports focal-security main universe" \
      > /etc/apt/sources.list \
 && dpkg --add-architecture arm64 && apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git pkg-config build-essential cmake nasm \
      gcc-aarch64-linux-gnu g++-aarch64-linux-gnu libc6-dev-arm64-cross \
      libasound2-dev:arm64 libudev-dev:arm64 libsdl2-dev:arm64 openjdk-17-jre-headless libclang-dev clang \
 && rm -rf /var/lib/apt/lists/*
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --target aarch64-unknown-linux-gnu
ENV PATH=/root/.cargo/bin:$PATH \
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc \
    CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc \
    CXX_aarch64_unknown_linux_gnu=aarch64-linux-gnu-g++ \
    PKG_CONFIG_ALLOW_CROSS=1 \
    PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig \
    PKG_CONFIG_SYSROOT_DIR=/ \
    BINDGEN_EXTRA_CLANG_ARGS_aarch64_unknown_linux_gnu="--target=aarch64-linux-gnu -I/usr/aarch64-linux-gnu/include"
WORKDIR /src

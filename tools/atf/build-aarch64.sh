#!/bin/bash
# build-aarch64.sh [--native] <out-dir>
# Cross compile atftool for aarch64 Linux with a glibc 2.31 floor (runs on every PortMaster CFW).
#
# Default: Docker. Uses ../../ruffle/Dockerfile (the ruffle_sdl cross image) when that file exists,
# otherwise builds a small ubuntu:20.04 image defined below. Needs network on first run.
# --native: no Docker. Host clang + lld against an arm64 sysroot (default ~/chroot-bullseye,
#           override with SYSROOT=...), plus rustup target aarch64-unknown-linux-gnu.
#
# The jpegxr crate generates C bindings at build time, so the image needs clang/libclang and the
# bindgen include path for the arm64 target. Prints the highest GLIBC symbol version and NEEDED libs.
set -euo pipefail

native=0
if [ "${1:-}" = "--native" ]; then native=1; shift; fi
[ $# -eq 1 ] || { echo "usage: $0 [--native] <out-dir>" >&2; exit 2; }

here=$(cd "$(dirname "$0")" && pwd)
out=$(realpath -m "$1")
mkdir -p "$out"
target=aarch64-unknown-linux-gnu

report() {
  local bin=$1
  if command -v llvm-objdump >/dev/null; then obj=llvm-objdump; else obj=objdump; fi
  echo "max glibc: $($obj -T "$bin" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)"
  if command -v readelf >/dev/null; then
    echo "NEEDED: $(readelf -d "$bin" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' | tr '\n' ' ')"
  fi
}

if [ $native = 1 ]; then
  SYSROOT=${SYSROOT:-$HOME/chroot-bullseye}
  [ -d "$SYSROOT" ] || { echo "SYSROOT $SYSROOT not found (arm64 glibc 2.31 root, e.g. debootstrap bullseye)" >&2; exit 1; }
  rustup target add $target >/dev/null
  wrap="$out/.cc"; mkdir -p "$wrap"
  for t in cc c++; do
    drv=clang; [ $t = c++ ] && drv=clang++
    printf '#!/bin/sh\nexec %s --target=aarch64-linux-gnu --sysroot=%s -fuse-ld=lld "$@"\n' "$drv" "$SYSROOT" > "$wrap/$t"
    chmod +x "$wrap/$t"
  done
  export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER="$wrap/cc" \
    CC_aarch64_unknown_linux_gnu="$wrap/cc" CXX_aarch64_unknown_linux_gnu="$wrap/c++" \
    AR_aarch64_unknown_linux_gnu=llvm-ar \
    BINDGEN_EXTRA_CLANG_ARGS_aarch64_unknown_linux_gnu="--target=aarch64-linux-gnu --sysroot=$SYSROOT"
  tdir=${CARGO_TARGET_DIR:-$out/target}
  (cd "$here" && CARGO_TARGET_DIR="$tdir" cargo build --release --target $target)
  cp "$tdir/$target/release/atftool" "$out/"
  report "$out/atftool"
  exit 0
fi

# Docker path
ctx="$here/../../ruffle"
if [ -f "$ctx/Dockerfile" ]; then
  dockerfile="$ctx/Dockerfile"; build_ctx="$ctx"
else
  build_ctx=$(mktemp -d); trap 'rm -rf "$build_ctx"' EXIT
  dockerfile="$build_ctx/Dockerfile"
  cat > "$dockerfile" <<'DOCKER'
FROM ubuntu:20.04
ENV DEBIAN_FRONTEND=noninteractive
RUN printf '%s\n' \
      "deb [arch=amd64] http://archive.ubuntu.com/ubuntu focal main universe" \
      "deb [arch=amd64] http://archive.ubuntu.com/ubuntu focal-updates main universe" \
      "deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports focal main universe" \
      "deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports focal-updates main universe" \
      > /etc/apt/sources.list \
 && dpkg --add-architecture arm64 && apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git pkg-config build-essential cmake \
      gcc-aarch64-linux-gnu g++-aarch64-linux-gnu libc6-dev-arm64-cross libclang-dev clang \
 && rm -rf /var/lib/apt/lists/*
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --target aarch64-unknown-linux-gnu
ENV PATH=/root/.cargo/bin:$PATH \
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc \
    CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc \
    CXX_aarch64_unknown_linux_gnu=aarch64-linux-gnu-g++ \
    BINDGEN_EXTRA_CLANG_ARGS_aarch64_unknown_linux_gnu="--target=aarch64-linux-gnu -I/usr/aarch64-linux-gnu/include"
WORKDIR /src
DOCKER
fi

image=atftool-cross
docker build -q -t "$image" -f "$dockerfile" "$build_ctx"
cache=${CARGO_CACHE:-$here/.cargo-cache}; mkdir -p "$cache"
docker run --rm -v "$here":/src -v "$cache":/root/.cargo/registry -v "$out":/out "$image" bash -c "
  CARGO_TARGET_DIR=/tmp/t cargo build --release --target $target &&
  cp /tmp/t/$target/release/atftool /out/ && chown $(id -u):$(id -g) /out/atftool"
report "$out/atftool"

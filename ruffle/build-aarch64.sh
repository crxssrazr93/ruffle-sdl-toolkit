#!/bin/bash
# build-aarch64.sh <ruffle-src> <out-dir>
# Docker cross build of ruffle_sdl for aarch64 against glibc 2.31 (ubuntu:20.04, so the binary needs
# GLIBC_2.30 at most). Links only libSDL2, libasound and glibc: no X11, Wayland, OpenSSL or fontconfig.
# Writes <out-dir>/ruffle_sdl (stripped) and prints the highest GLIBC version and the NEEDED libraries.
#
#   CARGO_CACHE   host dir used as the cargo registry cache (default: <out-dir>/.cargo-cache)
#   CPU           rustc target-cpu (default cortex-a53; set to generic for other aarch64 devices)
#   IMAGE         docker image tag (default ruffle-sdl-cross)
# Without Docker see build-aarch64-native.sh.
set -euo pipefail

if [ "$#" -ne 2 ] || [ ! -d "$1" ]; then
  echo "usage: $0 <ruffle-src> <out-dir>" >&2
  exit 2
fi
src=$(realpath "$1"); out=$(realpath -m "$2"); here=$(cd "$(dirname "$0")" && pwd)
cache=$(realpath -m "${CARGO_CACHE:-$out/.cargo-cache}")
cpu="${CPU:-cortex-a53}"; image="${IMAGE:-ruffle-sdl-cross}"
mkdir -p "$out" "$cache"

docker build -q -t "$image" "$here"
# -L: libSDL2.so comes from libsdl2-dev:arm64 in the multiarch directory (sdl2-sys links -lSDL2
# without pkg-config)
docker run --rm -v "$src":/src -v "$cache":/root/.cargo/registry -v "$out":/out -e CPU="$cpu" "$image" bash -c '
  set -e
  export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS="-C target-cpu=$CPU -L native=/usr/lib/aarch64-linux-gnu"
  cargo build --release -p ruffle_sdl --target aarch64-unknown-linux-gnu --features lzma
  aarch64-linux-gnu-strip -o /out/ruffle_sdl target/aarch64-unknown-linux-gnu/release/ruffle_sdl
  echo "glibc: $(aarch64-linux-gnu-objdump -T /out/ruffle_sdl | grep -o "GLIBC_[0-9.]*" | sort -uV | tail -1)"
  aarch64-linux-gnu-readelf -d /out/ruffle_sdl | grep NEEDED'
echo "built $out/ruffle_sdl"

#!/bin/bash
# build-aarch64.sh <ruffle-src> <out-dir>
# Docker cross build of ruffle_sdl for aarch64 against glibc 2.31 (ubuntu:20.04, so the binary needs
# GLIBC_2.30 at most). Links only libSDL2, libasound and glibc: no X11, Wayland, OpenSSL or fontconfig.
# Writes <out-dir>/ruffle_sdl (stripped), prints the highest GLIBC version and the NEEDED libraries, and
# fails if the binary needs a newer glibc than MAX_GLIBC.
#
#   CARGO_CACHE   host dir used as the cargo registry cache (default: <out-dir>/.cargo-cache)
#   TARGET_DIR    host dir for cargo's target directory (default: <out-dir>/.target, so the source tree
#                 stays clean and nothing in it is owned by root)
#   CPU           rustc target-cpu (default cortex-a53; set to generic for other aarch64 devices)
#   IMAGE         docker image tag (default ruffle-sdl-cross)
#   MAX_GLIBC     highest GLIBC symbol version the binary may need (default 2.30, the floor of the
#                 oldest PortMaster firmware); the build fails if it needs more
# Without Docker see build-aarch64-native.sh.
set -euo pipefail

if [ "$#" -ne 2 ] || [ ! -d "$1" ]; then
  echo "usage: $0 <ruffle-src> <out-dir>" >&2
  exit 2
fi
src=$(realpath "$1"); out=$(realpath -m "$2"); here=$(cd "$(dirname "$0")" && pwd)
cache=$(realpath -m "${CARGO_CACHE:-$out/.cargo-cache}")
target=$(realpath -m "${TARGET_DIR:-$out/.target}")
cpu="${CPU:-cortex-a53}"; image="${IMAGE:-ruffle-sdl-cross}"; max_glibc="${MAX_GLIBC:-2.30}"
mkdir -p "$out" "$cache" "$target"

docker build -q -t "$image" "$here"
# -L: libSDL2.so comes from libsdl2-dev:arm64 in the multiarch directory (sdl2-sys links -lSDL2
# without pkg-config)
docker run --rm -v "$src":/src -v "$cache":/root/.cargo/registry -v "$target":/target -v "$out":/out \
  -e CPU="$cpu" -e MAX_GLIBC="$max_glibc" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -e CARGO_TARGET_DIR=/target "$image" bash -c '
  set -e
  trap "chown -R $HOST_UID:$HOST_GID /target /out /root/.cargo/registry 2>/dev/null || true" EXIT
  export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS="-C target-cpu=$CPU -L native=/usr/lib/aarch64-linux-gnu"
  cargo build --release -p ruffle_sdl --target aarch64-unknown-linux-gnu --features lzma
  aarch64-linux-gnu-strip -o /out/ruffle_sdl /target/aarch64-unknown-linux-gnu/release/ruffle_sdl
  top=$(aarch64-linux-gnu-objdump -T /out/ruffle_sdl | grep -o "GLIBC_[0-9.]*" | sort -uV | tail -1)
  echo "glibc: $top"
  if [ "$(printf "%s\n%s\n" "${top#GLIBC_}" "$MAX_GLIBC" | sort -V | tail -1)" != "$MAX_GLIBC" ]; then
    echo "ERROR: the binary needs $top, newer than the allowed GLIBC_$MAX_GLIBC (set MAX_GLIBC to override)" >&2; exit 1
  fi
  aarch64-linux-gnu-readelf -d /out/ruffle_sdl | grep NEEDED'
echo "built $out/ruffle_sdl"

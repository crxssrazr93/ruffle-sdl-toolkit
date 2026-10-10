#!/bin/bash
# build-x86_64.sh <ruffle-src> <out-dir>
# Native PC build of ruffle_sdl for development and the Xvfb test harness. Writes <out-dir>/ruffle_sdl.
# Needs the host SDL2 development files (Debian/Ubuntu: libsdl2-dev, libasound2-dev; Arch: sdl2),
# a C compiler, cmake and cargo.
#
#   CARGO_TARGET_DIR  cargo target dir (default <ruffle-src>/target)
set -euo pipefail

if [ "$#" -ne 2 ] || [ ! -d "$1" ]; then
  echo "usage: $0 <ruffle-src> <out-dir>" >&2
  exit 2
fi
src=$(realpath "$1"); out=$(realpath -m "$2"); mkdir -p "$out"
cd "$src"
cargo build --release -p ruffle_sdl --features lzma
install -m 755 "${CARGO_TARGET_DIR:-target}/release/ruffle_sdl" "$out/ruffle_sdl"
echo "built $out/ruffle_sdl"

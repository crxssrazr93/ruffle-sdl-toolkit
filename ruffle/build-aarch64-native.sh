#!/bin/bash
# build-aarch64-native.sh <ruffle-src> <out-dir>
# build-aarch64.sh without Docker. Cross compiles ruffle_sdl for aarch64 with host clang and lld
# against a Debian bullseye arm64 sysroot (glibc 2.31) that has libsdl2-dev and libasound2-dev.
# Needs rustup (or cargo with the aarch64 target), clang, lld, llvm-strip, llvm-objdump, llvm-readelf.
#
#   SYSROOT       arm64 sysroot (default: $HOME/chroot-bullseye). Create it with
#                 debootstrap --arch=arm64 bullseye <dir>, then apt-get install libsdl2-dev
#                 libasound2-dev inside it.
#   CPU           rustc target-cpu (default cortex-a53)
#   CARGO_TARGET_DIR  cargo target dir (default <ruffle-src>/target)
set -euo pipefail

if [ "$#" -ne 2 ] || [ ! -d "$1" ]; then
  echo "usage: $0 <ruffle-src> <out-dir>" >&2
  exit 2
fi
src=$(realpath "$1"); out=$(realpath -m "$2"); mkdir -p "$out"
SYSROOT=${SYSROOT:-$HOME/chroot-bullseye}
cpu="${CPU:-cortex-a53}"
[ -d "$SYSROOT/usr/lib/aarch64-linux-gnu" ] || { echo "SYSROOT $SYSROOT has no arm64 libs" >&2; exit 2; }
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
if command -v rustup >/dev/null; then rustup target add aarch64-unknown-linux-gnu >/dev/null; fi

wrap=$out/.cc; mkdir -p "$wrap"
for t in cc c++; do
  drv=clang; [ "$t" = c++ ] && drv=clang++
  printf '#!/bin/sh\nexec %s --target=aarch64-linux-gnu --sysroot=%s -fuse-ld=lld "$@"\n' "$drv" "$SYSROOT" > "$wrap/$t"
  chmod +x "$wrap/$t"
done
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=$wrap/cc \
  CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS="-C target-cpu=$cpu" \
  CC_aarch64_unknown_linux_gnu=$wrap/cc CXX_aarch64_unknown_linux_gnu=$wrap/c++ \
  AR_aarch64_unknown_linux_gnu=llvm-ar \
  PKG_CONFIG_ALLOW_CROSS=1 PKG_CONFIG_SYSROOT_DIR=$SYSROOT \
  PKG_CONFIG_LIBDIR=$SYSROOT/usr/lib/aarch64-linux-gnu/pkgconfig:$SYSROOT/usr/share/pkgconfig \
  BINDGEN_EXTRA_CLANG_ARGS_aarch64_unknown_linux_gnu="--target=aarch64-linux-gnu --sysroot=$SYSROOT"
cd "$src"
cargo build --release -p ruffle_sdl --target aarch64-unknown-linux-gnu --features lzma
llvm-strip -o "$out/ruffle_sdl" "${CARGO_TARGET_DIR:-target}/aarch64-unknown-linux-gnu/release/ruffle_sdl"
echo "glibc: $(llvm-objdump -T "$out/ruffle_sdl" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)"
llvm-readelf -d "$out/ruffle_sdl" | grep NEEDED
echo "built $out/ruffle_sdl"

#!/bin/bash
# aarch64_qemu_run.sh <aarch64 ruffle_sdl> <swf> <out_dir> [seconds] [extra ruffle_sdl args...]
# aarch64_qemu_run.sh --make-sysroot            (only build the sysroot and qemu, then exit)
#
# Runs the REAL aarch64 ruffle_sdl (the binary you ship to handhelds) on the PC under
# qemu-aarch64-static user mode, against a Debian bookworm arm64 sysroot, on a private Xvfb.
# It tests the exact device binary: glibc floor, linked libraries, startup, behaviour and
# memory. It is minutes slow to the first frame, so use it for correctness, never for speed.
#
# STATUS: verified end to end with an aarch64 ruffle_sdl and tests/fixtures/test_quit.swf
# (sysroot built with Docker, qemu taken from the same container, Mesa 22.3 llvmpipe, clean exit
# in about 15 seconds). Screenshots through the hooks were not run under qemu.
#
# How it works
#  * The sysroot is built once with Docker (image debian:bookworm), without root on the host and
#    without binfmt_misc: inside the container `dpkg --add-architecture arm64`, install the
#    arm64 runtime libraries, copy /usr/lib/aarch64-linux-gnu and /usr/share/glvnd out and
#    chown them to you. The same container also provides qemu-aarch64-static (a static x86_64
#    binary) when the host has none, so nothing needs installing on the host.
#  * The binary is started through the sysroot's dynamic loader explicitly:
#        qemu-aarch64-static -L SYSROOT SYSROOT/lib/ld-linux-aarch64.so.1 --library-path ... BIN
#    Exec'ing the binary directly exits silently when the interpreter symlink dangles (Debian's
#    /lib to /usr/lib merge is not carried over by a plain copy). The script creates
#    lib/ld-linux-aarch64.so.1 and lib/aarch64-linux-gnu symlinks for that reason.
#  * SDL on X11 loads desktop GLX libGL even for a GLES context, so the sysroot has Mesa GLX
#    (libgl1, libglx-mesa0, libopengl0) next to EGL and GLES. SDL_VIDEO_X11_FORCE_EGL=1 alone
#    did not get a window without them.
#  * The rest (private Xvfb display with a lock check, SDL_VIDEODRIVER=x11, private
#    XDG_RUNTIME_DIR, SIGKILL trap, screenshots through the test hooks) is tests/pc_sdl_run.sh,
#    which this script calls with a small wrapper in place of the binary. So the aarch64 build
#    must come from a tree patched with tests/sdl_test_hooks.py to take screenshots.
#  * Debug a silent exit with:  QEMU_EXTRA="-strace" and LD_DEBUG=libs (both are passed through).
#
# Environment (all optional; the pc_sdl_run.sh variables RES, SHOT_AT, EXIT_AFTER_SHOTS, KEYS,
# MEM_MAX, RUST_LOG apply too)
#   SYSROOT      sysroot folder (default ~/.cache/ruffle-sdl-toolkit/sysroot-arm64)
#   QEMU         qemu-aarch64-static to use (default: on PATH, else $SYSROOT/qemu-aarch64-static)
#   EXTRA_LIBS   a folder with bundled aarch64 libraries searched first (a port's lib folder)
#   QEMU_EXTRA   extra qemu options, for example -strace
#   GALLIUM_DRIVER  set to softpipe if llvmpipe's JIT misbehaves under qemu (slower)
#   DOCKER_IMAGE debian:bookworm
here=$(cd "$(dirname "$0")" && pwd)
SYSROOT=${SYSROOT:-$HOME/.cache/ruffle-sdl-toolkit/sysroot-arm64}
IMAGE=${DOCKER_IMAGE:-debian:bookworm}

PKGS="libsdl2-2.0-0 libegl1 libgles2 libgl1 libglx-mesa0 libopengl0 libgl1-mesa-dri libegl-mesa0 \
zlib1g libstdc++6 libx11-6 libxext6 libxcursor1 libxi6 libxrandr2 libxss1 libxkbcommon0 libudev1 libasound2"

make_sysroot() {
  command -v docker >/dev/null || { echo "docker is needed to build the sysroot" >&2; exit 2; }
  mkdir -p "$SYSROOT"
  echo "aarch64_qemu_run: building the sysroot in $SYSROOT (about a minute plus download)"
  local arm_pkgs=""
  for p in $PKGS; do arm_pkgs="$arm_pkgs $p:arm64"; done
  docker run --rm -v "$SYSROOT:/out" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -e ARM_PKGS="$arm_pkgs" \
    "$IMAGE" bash -euc '
      export DEBIAN_FRONTEND=noninteractive
      dpkg --add-architecture arm64
      apt-get update -q
      # shellcheck disable=SC2086
      apt-get install -y -q --no-install-recommends qemu-user-static $ARM_PKGS
      mkdir -p /out/usr/lib /out/usr/share /out/lib
      cp -a /usr/lib/aarch64-linux-gnu /out/usr/lib/
      cp -a /usr/share/glvnd /out/usr/share/ 2>/dev/null || true
      cp -a /usr/share/X11 /out/usr/share/ 2>/dev/null || true
      cp -a /usr/share/drirc.d /out/usr/share/ 2>/dev/null || true
      cp -a /usr/bin/qemu-aarch64-static /out/qemu-aarch64-static
      ln -sfn ../usr/lib/aarch64-linux-gnu /out/lib/aarch64-linux-gnu
      ln -sfn ../usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 /out/lib/ld-linux-aarch64.so.1
      chown -R "$HOST_UID:$HOST_GID" /out
    ' || { echo "sysroot build failed" >&2; exit 3; }
}

if [ "${1:-}" = "--make-sysroot" ]; then make_sysroot; exit 0; fi
[ $# -ge 3 ] || { sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
BIN=$(readlink -f "$1"); SWF=$2; OUT=$3; shift 3
[ -x "$BIN" ] || { echo "not executable: $BIN" >&2; exit 2; }
[ -f "$SYSROOT/lib/ld-linux-aarch64.so.1" ] || [ -e "$SYSROOT/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1" ] || make_sysroot
[ -e "$SYSROOT/lib/ld-linux-aarch64.so.1" ] || { echo "sysroot has no ld-linux-aarch64.so.1, see the README" >&2; exit 3; }

QEMU=${QEMU:-}
[ -n "$QEMU" ] || QEMU=$(command -v qemu-aarch64-static || true)
[ -n "$QEMU" ] || QEMU=$SYSROOT/qemu-aarch64-static
[ -x "$QEMU" ] || { echo "no qemu-aarch64-static (install qemu-user-static or let the sysroot build provide one)" >&2; exit 3; }

LIBPATH="${EXTRA_LIBS:+$(readlink -f "$EXTRA_LIBS"):}$SYSROOT/usr/lib/aarch64-linux-gnu"
WRAP=$(mktemp /tmp/ruffle-qemu-wrap.XXXXXX)
trap 'rm -f "$WRAP"' EXIT
cat > "$WRAP" <<WRAP_EOF
#!/bin/bash
# exec keeps one pid, so the runner's SIGKILL reaches qemu
export LIBGL_DRIVERS_PATH="$SYSROOT/usr/lib/aarch64-linux-gnu/dri"
export __EGL_VENDOR_LIBRARY_DIRS="$SYSROOT/usr/share/glvnd/egl_vendor.d"
export __GLX_VENDOR_LIBRARY_NAME=mesa
exec "$QEMU" ${QEMU_EXTRA:-} -L "$SYSROOT" "$SYSROOT/lib/ld-linux-aarch64.so.1" --library-path "$LIBPATH" "$BIN" "\$@"
WRAP_EOF
chmod +x "$WRAP"
# the aarch64 binary is slow under emulation: allow more time unless the caller set it
"$here/pc_sdl_run.sh" "$WRAP" "$SWF" "$OUT" "${1:-60}" "${@:2}"
rc=$?
rm -f "$WRAP"
exit $rc

#!/bin/bash
# pc_sdl_run.sh [--headless | --visible[=auto|xephyr|vnc]] [--vnc-port N] [--hold SECS]
#               <ruffle_sdl> <swf> <out_dir> [seconds] [extra ruffle_sdl args...]
#
# Runs a PC (x86_64) ruffle_sdl on a SWF headless, on a private Xvfb display, and captures
# screenshots through the test hooks (build the binary from a tree patched by
# tests/sdl_test_hooks.py; a normal binary runs fine but takes no screenshots).
# It never opens a window on the desktop: private X display found with a lock check,
# SDL_VIDEODRIVER=x11, DISPLAY and WAYLAND_DISPLAY of the caller are dropped, private
# XDG_RUNTIME_DIR (mktemp -d), everything ends with SIGKILL from a trap.
#
# Viewing the run (default is --headless: nothing is shown anywhere, which is what automated
# runs must use). Both viewing modes are opt in and only for a human watching a test:
#   --visible=xephyr  the X server is Xephyr, a nested X window on YOUR desktop (needs Xephyr and
#                     a host DISPLAY or WAYLAND_DISPLAY with Xwayland). The test program itself
#                     still only sees the private nested display.
#   --visible=vnc     the X server stays Xvfb (no window) and x11vnc serves it on 127.0.0.1 only,
#                     with a random password in <out_dir>/vnc.pass. Connect with a VNC viewer,
#                     for example: vncviewer localhost:<port>. Needs x11vnc.
#   --visible         same as --visible=auto: xephyr if installed, else vnc.
#   --vnc-port N      first port to try for vnc (default 5990, the next free one is used).
#   --hold SECS       keep the display (and the viewer) up for SECS after the run ends, so the
#                     last frame can be looked at. Default 0.
# Environment equivalents: VIEW=headless|auto|xephyr|vnc, VNC_PORT, HOLD.
#
# Output in <out_dir>: shot-001.png ..., run.log (stdout and stderr of ruffle_sdl, which
# includes the trace output and the RUFFLE_RELAUNCH marker line, if any), exit_code.
#
# Environment (all optional):
#   RES=640x480          Xvfb screen and window size
#   SHOT_AT=2s           RUFFLE_SDL_SHOT_AT (frame numbers, or seconds with an s suffix)
#   EXIT_AFTER_SHOTS=1   quit as soon as every capture is saved (default 0: run <seconds>)
#   KEYS="1:tap Space;3:down Left;4:up Left"
#                        key script, "<seconds after start>:<down|up|tap> <key>" separated by
#                        semicolons, fed through RUFFLE_SDL_KEYS
#   MEM_MAX=700M         cap the run with systemd-run --user --scope -p MemoryMax (keep
#                        parallelism low, an uncapped test once OOMed a desktop)
#   RUST_LOG             default warn,ruffle_sdl=info,avm_trace=info
set -u
usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
VIEW=${VIEW:-headless}; VNC_PORT=${VNC_PORT:-5990}; HOLD=${HOLD:-0}
while [ $# -gt 0 ]; do
  case "$1" in
    --headless) VIEW=headless ;;
    --visible) VIEW=auto ;;
    --visible=*) VIEW=${1#--visible=} ;;
    --vnc-port) shift; VNC_PORT=${1:-}; ;;
    --vnc-port=*) VNC_PORT=${1#--vnc-port=} ;;
    --hold) shift; HOLD=${1:-}; ;;
    --hold=*) HOLD=${1#--hold=} ;;
    -h|--help) usage ;;
    --) shift; break ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
  shift
done
case "$VIEW" in headless|auto|xephyr|vnc) ;; *) echo "bad --visible value: $VIEW (auto, xephyr or vnc)" >&2; exit 2 ;; esac
case "$VNC_PORT$HOLD" in ''|*[!0-9]*) echo "--vnc-port and --hold need numbers" >&2; exit 2 ;; esac
if [ "$VIEW" = auto ]; then
  if command -v Xephyr >/dev/null && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; then VIEW=xephyr
  elif command -v x11vnc >/dev/null; then VIEW=vnc
  else echo "--visible needs Xephyr (with a desktop display) or x11vnc, neither is available" >&2; exit 2; fi
fi
[ $# -ge 3 ] || usage
BIN=$(readlink -f "$1"); SWF=$(readlink -f "$2"); OUT=$3; SECS=${4:-6}
shift 3; [ $# -gt 0 ] && shift
EXTRA=("$@")
[ -x "$BIN" ] || { echo "not executable: $BIN" >&2; exit 2; }
[ -f "$SWF" ] || { echo "no such SWF: $SWF" >&2; exit 2; }
mkdir -p "$OUT"; OUT=$(readlink -f "$OUT")
RES=${RES:-640x480}; W=${RES%x*}; H=${RES#*x}
[ "$VIEW" = xephyr ] || command -v Xvfb >/dev/null || { echo "Xvfb missing" >&2; exit 2; }
command -v xdpyinfo >/dev/null || { echo "xdpyinfo missing (needed to prove the private display is up)" >&2; exit 2; }

XDG=$(mktemp -d /tmp/ruffle-sdl-xdg.XXXXXX); chmod 700 "$XDG"
XP=""; RP=""; KP=""; VP=""; D=""
cleanup() {
  for p in $RP $KP $VP $XP; do kill -9 "$p" 2>/dev/null; done
  wait 2>/dev/null
  # SIGKILL leaves the X lock and socket of our own display behind
  [ -n "$D" ] && rm -f "/tmp/.X${D#:}-lock" "/tmp/.X11-unix/X${D#:}"
  rm -rf "$XDG"
}
trap cleanup EXIT INT TERM

# a free display number, proven by the lock file and the socket, then proven up by xdpyinfo
for _try in 1 2 3 4 5; do
  N=${DNUM:-90}
  while [ -e "/tmp/.X$N-lock" ] || [ -S "/tmp/.X11-unix/X$N" ]; do N=$((N + 1)); done
  if [ "$VIEW" = xephyr ]; then
    command -v Xephyr >/dev/null || { echo "Xephyr missing" >&2; exit 2; }
    # nested server: this one process keeps the caller's DISPLAY/WAYLAND_DISPLAY on purpose,
    # it is the window the user asked to see (only with --visible)
    Xephyr ":$N" -screen "${W}x${H}" -nolisten tcp >"$OUT/xvfb.log" 2>&1 &
  else
    Xvfb ":$N" +extension GLX -screen 0 "${W}x${H}x24" -nolisten tcp >"$OUT/xvfb.log" 2>&1 &
  fi
  XP=$!
  for _ in $(seq 1 40); do
    DISPLAY=":$N" xdpyinfo >/dev/null 2>&1 && { D=":$N"; break; }
    kill -0 "$XP" 2>/dev/null || break
    sleep 0.5
  done
  [ -n "$D" ] && break
  kill -9 "$XP" 2>/dev/null; wait "$XP" 2>/dev/null; XP=""; rm -f "/tmp/.X$N-lock" "/tmp/.X11-unix/X$N"
  DNUM=$((N + 1))
done
[ -n "$D" ] || { echo "no private Xvfb display came up, refusing to continue (see $OUT/xvfb.log)" >&2; exit 3; }
echo "pc_sdl_run: ${VIEW} display on $D, XDG_RUNTIME_DIR $XDG"
if [ "$VIEW" = vnc ]; then
  command -v x11vnc >/dev/null || { echo "x11vnc missing" >&2; exit 2; }
  while (exec 3<>"/dev/tcp/127.0.0.1/$VNC_PORT") 2>/dev/null; do VNC_PORT=$((VNC_PORT + 1)); done
  ( umask 077; head -c 12 /dev/urandom | base64 | tr -d '/+=\n' > "$OUT/vnc.pass" )
  # x11vnc refuses to start when it sees a Wayland session, even for a private X display
  env -u WAYLAND_DISPLAY XDG_SESSION_TYPE=x11 \
    x11vnc -display "$D" -localhost -rfbport "$VNC_PORT" -passwdfile "$OUT/vnc.pass" \
    -forever -shared >"$OUT/x11vnc.log" 2>&1 &
  VP=$!
  sleep 1
  kill -0 "$VP" 2>/dev/null || { echo "x11vnc did not start, see $OUT/x11vnc.log" >&2; exit 3; }
  echo "pc_sdl_run: watch with a VNC viewer: localhost:$VNC_PORT (password in $OUT/vnc.pass, listens on 127.0.0.1 only)"
fi

mkdir -p "$OUT/saves"
rm -f "$OUT"/shot-*.png "$OUT/run.log" "$OUT/exit_code" "$OUT/keys.txt"
: > "$OUT/keys.txt"
RUNNER=()
[ -n "${MEM_MAX:-}" ] && RUNNER=(systemd-run --user --scope -q -p "MemoryMax=$MEM_MAX")

# `env -i` style: only what the test needs, never the desktop's display variables
env -u WAYLAND_DISPLAY -u DISPLAY -u XAUTHORITY \
  DISPLAY="$D" XDG_RUNTIME_DIR="$XDG" SDL_VIDEODRIVER=x11 SDL_VIDEO_X11_FORCE_EGL=1 \
  SDL_AUDIODRIVER=dummy LIBGL_ALWAYS_SOFTWARE=1 \
  RUST_LOG="${RUST_LOG:-warn,ruffle_sdl=info,avm_trace=info}" \
  RUFFLE_SDL_SHOT="$OUT" RUFFLE_SDL_SHOT_AT="${SHOT_AT:-2s}" RUFFLE_SDL_KEYS="$OUT/keys.txt" \
  RUFFLE_SDL_EXIT_AFTER_SHOTS="${EXIT_AFTER_SHOTS:-0}" \
  "${RUNNER[@]}" \
  "$BIN" --width "$W" --height "$H" --save-directory "$OUT/saves" "${EXTRA[@]}" "$SWF" >"$OUT/run.log" 2>&1 &
RP=$!

# key script, appended to the polled file at the given times
if [ -n "${KEYS:-}" ]; then
  (
    start=$(date +%s.%N)
    IFS=';' read -ra items <<< "$KEYS"
    for it in "${items[@]}"; do
      t=${it%%:*}; line=${it#*:}
      now=$(date +%s.%N)
      wait_s=$(awk -v s="$start" -v n="$now" -v t="$t" 'BEGIN{d=s+t-n; print (d>0?d:0)}')
      sleep "$wait_s"
      echo "$line" >> "$OUT/keys.txt"
    done
  ) &
  KP=$!
fi

# wait for the run time, or for the process to end by itself (quit, relaunch, exit after shots)
for _ in $(seq 1 $((SECS * 10))); do
  kill -0 "$RP" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$RP" 2>/dev/null; then
  # <seconds> is the hard timeout: SIGKILL (env, systemd-run and the binary share one pid)
  kill -9 "$RP" 2>/dev/null; wait "$RP" 2>/dev/null
  echo "killed after ${SECS}s" >> "$OUT/run.log"; echo killed > "$OUT/exit_code"
else
  wait "$RP" 2>/dev/null; echo $? > "$OUT/exit_code"
fi
RP=""
if [ "$VIEW" != headless ] && [ "$HOLD" -gt 0 ]; then echo "pc_sdl_run: holding the display for ${HOLD}s"; sleep "$HOLD"; fi
echo "pc_sdl_run: exit $(cat "$OUT/exit_code"); shots: $(ls "$OUT"/shot-*.png 2>/dev/null | wc -l); log: $OUT/run.log"
# a segfault at exit can raise a desktop crash dialog via systemd-coredump: check afterwards
#   coredumpctl list | tail -3

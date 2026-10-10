#!/bin/bash
# pc_sdl_run.sh <ruffle_sdl> <swf> <out_dir> [seconds] [extra ruffle_sdl args...]
#
# Runs a PC (x86_64) ruffle_sdl on a SWF headless, on a private Xvfb display, and captures
# screenshots through the test hooks (build the binary from a tree patched by
# tests/sdl_test_hooks.py; a normal binary runs fine but takes no screenshots).
# It never opens a window on the desktop: private X display found with a lock check,
# SDL_VIDEODRIVER=x11, DISPLAY and WAYLAND_DISPLAY of the caller are dropped, private
# XDG_RUNTIME_DIR (mktemp -d), everything ends with SIGKILL from a trap.
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
[ $# -ge 3 ] || { sed -n '2,3p;5,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
BIN=$(readlink -f "$1"); SWF=$(readlink -f "$2"); OUT=$3; SECS=${4:-6}
shift 3; [ $# -gt 0 ] && shift
EXTRA=("$@")
[ -x "$BIN" ] || { echo "not executable: $BIN" >&2; exit 2; }
[ -f "$SWF" ] || { echo "no such SWF: $SWF" >&2; exit 2; }
mkdir -p "$OUT"; OUT=$(readlink -f "$OUT")
RES=${RES:-640x480}; W=${RES%x*}; H=${RES#*x}
command -v Xvfb >/dev/null || { echo "Xvfb missing" >&2; exit 2; }
command -v xdpyinfo >/dev/null || { echo "xdpyinfo missing (needed to prove the private display is up)" >&2; exit 2; }

XDG=$(mktemp -d /tmp/ruffle-sdl-xdg.XXXXXX); chmod 700 "$XDG"
XP=""; RP=""; KP=""; D=""
cleanup() {
  for p in $RP $KP $XP; do kill -9 "$p" 2>/dev/null; done
  wait 2>/dev/null
  # SIGKILL leaves the X lock and socket of our own display behind
  [ -n "$D" ] && rm -f "/tmp/.X${D#:}-lock" "/tmp/.X11-unix/X${D#:}"
  rm -rf "$XDG"
}
trap cleanup EXIT INT TERM

# a free display number, proven by the lock file and the socket, then proven up by xdpyinfo
for try in 1 2 3 4 5; do
  N=${DNUM:-90}
  while [ -e "/tmp/.X$N-lock" ] || [ -S "/tmp/.X11-unix/X$N" ]; do N=$((N + 1)); done
  Xvfb ":$N" +extension GLX -screen 0 "${W}x${H}x24" -nolisten tcp >"$OUT/xvfb.log" 2>&1 &
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
echo "pc_sdl_run: Xvfb on $D, XDG_RUNTIME_DIR $XDG"

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
echo "pc_sdl_run: exit $(cat "$OUT/exit_code"); shots: $(ls "$OUT"/shot-*.png 2>/dev/null | wc -l); log: $OUT/run.log"
# a segfault at exit can raise a desktop crash dialog via systemd-coredump: check afterwards
#   coredumpctl list | tail -3

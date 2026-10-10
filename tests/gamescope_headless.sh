#!/bin/bash
# gamescope_headless.sh [--headless | --visible] [--hold SECS] <ruffle_sdl> <swf> <out_dir> [seconds] [extra args...]
#
# Same contract as pc_sdl_run.sh, but the X server is the one gamescope brings up with
# `--backend headless` (Xwayland inside gamescope, drawn on the real GPU through Vulkan
# instead of llvmpipe, so GL heavy movies run several times faster than on Xvfb software GL).
# Needs a Vulkan capable GPU and gamescope 3.x. Never opens a window on the desktop: the
# headless backend has no output, the compositor socket lives in a private XDG_RUNTIME_DIR
# (mktemp -d), the caller's DISPLAY and WAYLAND_DISPLAY are dropped, and everything is
# stopped with SIGKILL on the whole process group from a trap.
#
# Captures and key injection use the same test hooks as pc_sdl_run.sh (external grabbers
# such as import fail in gamescope headless, "missing an image filename").
# Viewing: default is --headless (no output anywhere, the mode for automated runs).
# --visible is opt in for a human watching a test: gamescope runs with `--backend auto`, a nested
# window on YOUR desktop session. It keeps the caller's DISPLAY, WAYLAND_DISPLAY and XDG_RUNTIME_DIR
# (the compositor needs them), so the private runtime dir isolation does not apply in this mode.
# --hold SECS keeps the window up SECS seconds after the run. Env: VIEW=headless|visible, HOLD.
# The visible mode is not verified (checking it opens a window), the headless mode is.
#
# Output in <out_dir>: shot-001.png ..., run.log, gamescope.log, exit_code.
#
# Environment (all optional): RES=640x480, SHOT_AT=2s, EXIT_AFTER_SHOTS=1, KEYS="1:tap Space",
# MEM_MAX=700M, RUST_LOG, see pc_sdl_run.sh.
set -u
usage() { sed -n '2,3p;12,18p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
VIEW=${VIEW:-headless}; HOLD=${HOLD:-0}
while [ $# -gt 0 ]; do
  case "$1" in
    --headless) VIEW=headless ;;
    --visible) VIEW=visible ;;
    --hold) shift; HOLD=${1:-} ;;
    --hold=*) HOLD=${1#--hold=} ;;
    -h|--help) usage ;;
    --) shift; break ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
  shift
done
case "$VIEW" in headless|visible) ;; *) echo "bad VIEW: $VIEW" >&2; exit 2 ;; esac
case "$HOLD" in ''|*[!0-9]*) echo "--hold needs a number" >&2; exit 2 ;; esac
[ $# -ge 3 ] || usage
BIN=$(readlink -f "$1"); SWF=$(readlink -f "$2"); OUT=$3; SECS=${4:-8}
case "$SECS" in ''|*[!0-9]*) echo "seconds must be a number, got: $SECS (extra args go after the seconds slot)" >&2; exit 2 ;; esac
shift 3; [ $# -gt 0 ] && shift
EXTRA=("$@")
[ -x "$BIN" ] || { echo "not executable: $BIN" >&2; exit 2; }
[ -f "$SWF" ] || { echo "no such SWF: $SWF" >&2; exit 2; }
command -v gamescope >/dev/null || { echo "gamescope missing" >&2; exit 2; }
mkdir -p "$OUT/saves"; OUT=$(readlink -f "$OUT")
RES=${RES:-640x480}; W=${RES%x*}; H=${RES#*x}

XDG=$(mktemp -d /tmp/ruffle-gs-xdg.XXXXXX); chmod 700 "$XDG"
INNER=$(mktemp /tmp/ruffle-gs-inner.XXXXXX)
# extra ruffle_sdl args, shell quoted so spaces and quotes survive the generated inner script
EXTRA_Q=""; [ ${#EXTRA[@]} -gt 0 ] && EXTRA_Q=$(printf ' %q' "${EXTRA[@]}")
GP=""; KP=""
cleanup() {
  [ -n "$GP" ] && kill -9 -- "-$GP" 2>/dev/null   # the whole group started with setsid
  [ -n "$KP" ] && kill -9 "$KP" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$XDG" "$INNER"
}
trap cleanup EXIT INT TERM

rm -f "$OUT"/shot-*.png "$OUT/run.log" "$OUT/exit_code"; : > "$OUT/keys.txt"
# the program gamescope runs: ruffle_sdl on gamescope's own X display
cat > "$INNER" <<INNER_EOF
#!/bin/bash
unset WAYLAND_DISPLAY
export SDL_VIDEODRIVER=x11 SDL_VIDEO_X11_FORCE_EGL=1 SDL_AUDIODRIVER=dummy
export RUST_LOG="${RUST_LOG:-warn,ruffle_sdl=info,avm_trace=info}"
export RUFFLE_SDL_SHOT="$OUT" RUFFLE_SDL_SHOT_AT="${SHOT_AT:-2s}" RUFFLE_SDL_KEYS="$OUT/keys.txt"
export RUFFLE_SDL_EXIT_AFTER_SHOTS="${EXIT_AFTER_SHOTS:-0}"
echo "inner DISPLAY=\$DISPLAY" >&2
exec "$BIN" --width "$W" --height "$H" --save-directory "$OUT/saves" ${EXTRA_Q} "$SWF"
INNER_EOF
chmod +x "$INNER"

RUNNER=()
[ -n "${MEM_MAX:-}" ] && RUNNER=(systemd-run --user --scope -q -p "MemoryMax=$MEM_MAX")
if [ "$VIEW" = visible ]; then
  # nested window on the user's desktop session, only on request
  setsid "${RUNNER[@]}" gamescope --backend auto -W "$W" -H "$H" -w "$W" -h "$H" -- "$INNER" \
    >"$OUT/gamescope.log" 2>&1 &
else
  env -u DISPLAY -u WAYLAND_DISPLAY -u WAYLAND_SOCKET -u XAUTHORITY XDG_RUNTIME_DIR="$XDG" \
    setsid "${RUNNER[@]}" gamescope --backend headless -W "$W" -H "$H" -w "$W" -h "$H" -- "$INNER" \
    >"$OUT/gamescope.log" 2>&1 &
fi
GP=$!

if [ -n "${KEYS:-}" ]; then
  (
    start=$(date +%s.%N)
    IFS=';' read -ra items <<< "$KEYS"
    for it in "${items[@]}"; do
      t=${it%%:*}; line=${it#*:}
      now=$(date +%s.%N)
      sleep "$(awk -v s="$start" -v n="$now" -v t="$t" 'BEGIN{d=s+t-n; print (d>0?d:0)}')"
      echo "$line" >> "$OUT/keys.txt"
    done
  ) &
  KP=$!
fi

for _ in $(seq 1 $((SECS * 10))); do
  kill -0 "$GP" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$GP" 2>/dev/null; then
  kill -9 -- "-$GP" 2>/dev/null; wait "$GP" 2>/dev/null; echo killed > "$OUT/exit_code"
else
  wait "$GP" 2>/dev/null; echo $? > "$OUT/exit_code"
fi
[ "$VIEW" = visible ] && [ "$HOLD" -gt 0 ] && { echo "gamescope_headless: window closed with the run; --hold only delays the cleanup" >&2; sleep "$HOLD"; }
GP=""
# ruffle_sdl output is inside gamescope.log (the inner program shares its stdout and stderr)
cp "$OUT/gamescope.log" "$OUT/run.log"
echo "gamescope_headless: exit $(cat "$OUT/exit_code"); shots: $(ls "$OUT"/shot-*.png 2>/dev/null | wc -l); log: $OUT/run.log"

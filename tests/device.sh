#!/bin/bash
# device.sh: drive a handheld running a ruffle_sdl port over SSH, launching through
# EmulationStation's HTTP API the way a player would (Knulli, Batocera and similar).
#
# THIS SCRIPT TALKS TO REAL HARDWARE. It is never run by the toolkit's own tests and refuses
# to do anything unless DEVICE_OK=1 is set in the environment, as a deliberate act:
#   DEVICE_OK=1 DEVICE_HOST=handheld.local tests/device.sh launch
# Read only inspection (stat, log, fbinfo, shot, es-games) is harmless. Installing or copying
# builds onto a device needs the owner's approval, do not do it from here.
#
# Subcommands
#   es-games             list the ports ES knows (GET /systems/ports/games)
#   es-reload            ask ES to rescan its game lists (GET /reloadgames)
#   running              what ES thinks is running (GET /runningGame)
#   launch               start DEVICE_LAUNCHER through ES (POST /launch), after checking ES lists it
#   emukill              ES kill (GET /emukill); prefer `stop`, see the pitfalls
#   stop                 kill the player by pid (pidof), SIGTERM then wait
#   keyd                 upload tests/keyd.py and start it on the device (pid file, no pgrep)
#   keys "right 2000" "a 200" "sleep 500" ...   write lines to keyd's FIFO
#   fbinfo               print the detected framebuffer geometry
#   shot <name>          framebuffer screenshot to $DEVICE_OUT/<name>.png
#   stat                 last fps log lines, errors, player RSS, free memory
#   log [file]           fetch the port log (ANSI colours stripped) to a local file
#   waitlog <regex> [timeout_s]   wait for <regex> in log lines written after the last launch
#
# Settings (environment)
#   DEVICE_OK=1                 required, see above
#   DEVICE_HOST                 ssh host name or address (required; DHCP addresses change, use a name)
#   DEVICE_USER                 ssh user (default root)
#   DEVICE_PASS_FILE            file holding the ssh password, used through sshpass -f (optional;
#                               without it plain ssh with keys or an agent is used)
#   DEVICE_SSH_OPTS             extra ssh options (default: -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
#   DEVICE_LAUNCHER             path of the launcher script as ES lists it, for example
#                               /userdata/roms/ports/MYGAME.sh (required for launch)
#   DEVICE_DIR                  the port folder, for example /userdata/roms/ports/mygame (required for log, stat)
#   DEVICE_LOG                  log file (default $DEVICE_DIR/log.txt)
#   DEVICE_BIN                  player process name (default ruffle_sdl)
#   DEVICE_ES_URL               ES API base (default http://127.0.0.1:1234, as seen from the device)
#   DEVICE_TMP                  scratch folder on the device (default /tmp/ruffle-test)
#   DEVICE_FB                   framebuffer device (default fb0, so /dev/fb0 and /sys/class/graphics/fb0)
#   DEVICE_FB_VISIBLE           visible size WxH when /sys/.../modes does not say (for example 640x480)
#   DEVICE_OUT                  local output folder (default ./device-out)
#
# Pitfalls this script works around or that you must keep in mind
#  * Stale logs and screenshots. A wait loop that greps the log matches the PREVIOUS run, and a
#    "screenshot" can be an old file when the command was blocked. launch records the log's line
#    count and waitlog only looks at lines after it; shot deletes the old file first. Never trust
#    mtimes (exFAT and some handheld clocks are hours off), compare content.
#  * pkill -f and pgrep -f match their own shell and the ssh command line, which kills your
#    session (exit 144 or 255) or, with an empty pattern, every process (a stop script once took
#    sshd down). This script uses pidof, pid files and exact names only.
#  * ES caches the game list. A new or renamed launcher is invisible until es-reload (wait about
#    10 seconds, then check es-games). ES also rewrites gamelist edits on reload when dirty.
#  * POST /launch with a path ES does not list starts whatever game is currently selected. launch
#    checks the list first. The body is the plain path (not JSON, not a form), and it must be
#    exactly the path ES lists. Paths with spaces are sent through stdin (curl --data-binary @-)
#    so no shell quoting is involved; set DEVICE_LAUNCH_ENCODE=1 to percent encode the body if a
#    firmware insists on a URL encoded path.
#  * Launch through ES, not an ssh shell: same launcher, same emulatorlauncher wrapper, gamepad
#    mapper, power mode and patcher screen as a player. Starting by hand misleads.
#  * A first launch (or the first after a version bump) shows the patcher, which waits for a key
#    press at the start and at its closing dialogue. While it waits /runningGame reports a game
#    and a new /launch is ignored. Press the confirm button (keyd: "enter 200").
#  * Key presses after the game exits land in ES and can set a filter ("No entries found").
#    Only inject while `running` names a game.
#  * Do not overwrite a running launcher or harness script (bash reads scripts incrementally).
#    Copy to a temp name and mv, or stop the game first. Do not emukill during setup: it can leave
#    the patcher process behind.
#  * Test the real exit path (the firmware hotkey, exit codes 143 and 137), not only emukill.
#  * Orphaned players after emukill hold memory and swap and skew the next run: check `stat`.
#  * Framebuffer grabs of GL output: fbgrab shows white. Read the raw framebuffer as BGRA,
#    crop the visible page at the pan offset. The geometry is detected from sysfs, not assumed.
#  * ssh quirks: scp fails for paths with spaces (this script pipes through ssh cat), zsh does not
#    word split a variable holding a command, first connect can exit 6 without
#    StrictHostKeyChecking=accept-new.
[ "${DEVICE_OK:-}" = 1 ] || { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; echo "refusing to run: set DEVICE_OK=1 to talk to a real device" >&2; exit 2; }
: "${DEVICE_HOST:?set DEVICE_HOST (ssh host of the handheld)}"
USER_=${DEVICE_USER:-root}
here=$(cd "$(dirname "$0")" && pwd)
ES=${DEVICE_ES_URL:-http://127.0.0.1:1234}
TMP=${DEVICE_TMP:-/tmp/ruffle-test}
BIN=${DEVICE_BIN:-ruffle_sdl}
FB=${DEVICE_FB:-fb0}
OUT=${DEVICE_OUT:-./device-out}
mkdir -p "$OUT"
SSH_OPTS=${DEVICE_SSH_OPTS:--o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new}

S() {  # S <remote command...>: run on the device, stdin passes through
  if [ -n "${DEVICE_PASS_FILE:-}" ]; then
    # shellcheck disable=SC2086
    sshpass -f "$DEVICE_PASS_FILE" ssh $SSH_OPTS "$USER_@$DEVICE_HOST" "$@"
  else
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$USER_@$DEVICE_HOST" "$@"
  fi
}
need() { [ -n "${!1:-}" ] || { echo "set $1 for this subcommand" >&2; exit 2; }; }
LOG=${DEVICE_LOG:-${DEVICE_DIR:+$DEVICE_DIR/log.txt}}
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }
logcount() { S "wc -l < '$LOG' 2>/dev/null || echo 0" | tr -d ' \r'; }
MARK="$OUT/.logmark"

fb_geometry() {  # sets VX VY BPP STRIDE PANY VW VH from sysfs
  local base=/sys/class/graphics/$FB
  read -r VX VY < <(S "cat $base/virtual_size" | tr ',' ' ')
  BPP=$(S "cat $base/bits_per_pixel")
  STRIDE=$(S "cat $base/stride")
  PANY=$(S "cut -d, -f2 $base/pan 2>/dev/null || echo 0")
  local mode
  mode=$(S "head -1 $base/modes 2>/dev/null" | sed -n 's/.*:\([0-9]*\)x\([0-9]*\).*/\1 \2/p')
  if [ -n "${DEVICE_FB_VISIBLE:-}" ]; then VW=${DEVICE_FB_VISIBLE%x*}; VH=${DEVICE_FB_VISIBLE#*x}
  elif [ -n "$mode" ]; then read -r VW VH <<< "$mode"
  else VW=$VX; VH=$VY; echo "fb: no visible mode found, using the virtual size (set DEVICE_FB_VISIBLE)" >&2; fi
}

case ${1:-} in
  es-games) S "curl -s -m 5 $ES/systems/ports/games";;
  es-reload) S "curl -s -m 10 $ES/reloadgames"; echo; echo "wait about 10 s, then check es-games";;
  running) S "curl -s -m 5 $ES/runningGame"; echo;;
  launch)
    need DEVICE_LAUNCHER; need DEVICE_DIR
    # ES only launches paths it lists; an unknown path starts the currently selected game
    S "curl -s -m 5 $ES/systems/ports/games | grep -qF -- \"\$(cat)\"" <<< "$DEVICE_LAUNCHER" \
      || { echo "ES does not list $DEVICE_LAUNCHER (try: es-reload, wait 10 s, es-games)" >&2; exit 1; }
    logcount > "$MARK"
    body=$DEVICE_LAUNCHER
    if [ "${DEVICE_LAUNCH_ENCODE:-0}" = 1 ]; then
      body=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$DEVICE_LAUNCHER")
    fi
    printf '%s' "$body" | S "curl -s -m 5 -X POST --data-binary @- $ES/launch"; echo;;
  emukill) S "curl -s -m 5 $ES/emukill"; echo;;
  stop) S "p=\$(pidof $BIN); [ -n \"\$p\" ] && kill \$p; sleep 4; pidof $BIN || echo stopped";;
  keyd)
    S "mkdir -p $TMP && cat > $TMP/keyd.py" < "$here/keyd.py"
    # a pid file, not pgrep -f: pgrep -f would also match this ssh command line
    S "kill -0 \$(cat $TMP/keyd.pid 2>/dev/null) 2>/dev/null || { rm -f $TMP/keys; KEYD_FIFO=$TMP/keys nohup python3 $TMP/keyd.py >$TMP/keyd.log 2>&1 </dev/null & sleep 2; }; cat $TMP/keyd.log; [ -p $TMP/keys ] && echo keyd running";;
  keys) shift; printf '%s\n' "$@" | S "cat > $TMP/keys";;
  fbinfo) fb_geometry; echo "virtual ${VX}x${VY}, ${BPP} bpp, stride $STRIDE, pan y $PANY, visible ${VW}x${VH}";;
  shot)
    name=${2:?usage: shot <name>}
    fb_geometry
    case $BPP in 32) pix=bgra; bytes=4;; 16) pix=rgb565le; bytes=2;; *) echo "unsupported ${BPP} bpp" >&2; exit 1;; esac
    rawwidth=$((STRIDE / bytes))
    # remove the old capture first, so a failed grab can never pass for a new one
    rm -f "${OUT:?}/${name:?}.png" "${OUT:?}/${name:?}.raw"
    S "dd if=/dev/$FB bs=$STRIDE count=$VY 2>/dev/null" > "$OUT/$name.raw"
    ffmpeg -loglevel error -y -f rawvideo -pix_fmt "$pix" -s "${rawwidth}x${VY}" -i "$OUT/$name.raw" \
      -vf "crop=$VW:$VH:0:$PANY" -frames:v 1 "$OUT/$name.png" && rm -f "${OUT:?}/${name:?}.raw"
    [ -s "$OUT/$name.png" ] && echo "$OUT/$name.png" || { echo "screenshot failed" >&2; exit 1; };;
  stat)
    need DEVICE_DIR
    S "sed 's/\x1b\[[0-9;]*m//g' '$LOG' | grep -E 'fps|panic|ERROR' | tail -3; P=\$(pidof $BIN); [ -n \"\$P\" ] && grep VmRSS /proc/\$P/status; free -m | sed -n 2p";;
  log)
    need DEVICE_DIR
    f=${2:-$OUT/log.txt}
    S "cat '$LOG'" | strip_ansi > "$f"; echo "$f";;
  waitlog)
    need DEVICE_DIR
    re=${2:?usage: waitlog <regex> [timeout_s]}; to=${3:-300}
    mark=$(cat "$MARK" 2>/dev/null || echo 0)
    end=$((SECONDS + to))
    while [ $SECONDS -lt $end ]; do
      total=$(logcount)
      # the launcher rotates the log: a shorter file means a new one, count from the top
      [ "${total:-0}" -lt "$mark" ] && mark=0
      if S "tail -n +$((mark + 1)) '$LOG' | sed 's/\x1b\[[0-9;]*m//g' | grep -E -- \"\$(cat)\" | tail -3" <<< "$re" | grep .; then exit 0; fi
      sleep 5
    done
    echo "timeout after ${to}s waiting for /$re/" >&2; exit 1;;
  *) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 1;;
esac

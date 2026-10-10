#!/bin/bash
# PORTMASTER: MYPORT.zip, MYGAME.sh
#
# TEMPLATE. Rename this file to the name shown in the ports list (for example "My Game.sh").
# Replace MYPORT (folder and zip name, lower case, no spaces) and MYGAME (display name) everywhere.
# Line 2 above must stay a PORTMASTER header that names the zip and this script's file name,
# otherwise PortMaster rewrites the running script on the first runtime download.

XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}

if [ -d "/opt/system/Tools/PortMaster/" ]; then
  controlfolder="/opt/system/Tools/PortMaster"
elif [ -d "/opt/tools/PortMaster/" ]; then
  controlfolder="/opt/tools/PortMaster"
elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then
  controlfolder="$XDG_DATA_HOME/PortMaster"
else
  controlfolder="/roms/ports/PortMaster"
fi

source $controlfolder/control.txt
[ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"
get_controls

GAMEDIR="/$directory/ports/MYPORT"
DATADIR="$GAMEDIR/gamedata"
cd "$GAMEDIR"

# User settings (quality, aspect, frame rate, VERBOSE_LOGS, tuning variables). The cfg is read
# before the log starts so that VERBOSE_LOGS can decide whether the last log is kept.
source "$GAMEDIR/MYPORT.cfg"

# Non standard, testing builds only: keep the previous log as log.prev.txt (VERBOSE_LOGS=1)
[ "$VERBOSE_LOGS" = 1 ] && [ -f log.txt ] && mv -f log.txt log.prev.txt
# The log path is relative on purpose: gptokeyb's quit hotkey runs "pkill -f ruffle_sdl" and the
# tee command line must not contain that name, or the logger dies and the launcher with it
exec > >(tee log.txt) 2>&1

$ESUDO chmod +x "$GAMEDIR/ruffle_sdl" "$GAMEDIR/tools/atftool" "$GAMEDIR/tools/patchscript" "$GAMEDIR/tools/run-ruffle"

# The setup patches the game files for Ruffle. It runs again when a port update ships new
# patches (tools/patch/version) or when the files it wrote change (a fresh copy of the game).
# Non standard: PortMaster has no helper for "prepare once, redo when the files change".
PATCH_VERSION="$(cat "$GAMEDIR/tools/patch/version")"
stamp() (
  export LC_ALL=C  # the same file order everywhere
  echo "$PATCH_VERSION"
  # EDIT: list every file the patchscript reads or writes (sources, outputs, converted assets).
  # ls and date are used because muOS has no stat.
  cd "$DATADIR" && for f in MYGAME.swf MYGAME-port.swf data/*.swf data/*.xml; do
    [ -e "$f" ] && echo "$f $(ls -lnL "$f" | awk '{print $5}') $(date -r "$f" +%s)"
  done
)
if [ "$(cat "$DATADIR/.port_prepared" 2>/dev/null)" != "$(stamp)" ]; then
  if [ -f "$controlfolder/utils/patcher.txt" ]; then
    rm -f "$DATADIR/.port_patched"
    export PATCHER_FILE="$GAMEDIR/tools/patchscript"
    export PATCHER_GAME="$(basename "${0%.*}")"
    export PATCHER_TIME="a few minutes"
    export controlfolder
    source "$controlfolder/utils/patcher.txt"
  else
    pm_message "This port requires the latest version of PortMaster."
    sleep 5
    pm_finish
    exit 1
  fi
  # the patch script leaves its version in .port_patched when it succeeds
  if [ "$(cat "$DATADIR/.port_patched" 2>/dev/null)" != "$PATCH_VERSION" ]; then
    pm_message "Preparing the game failed, see ports/MYPORT/patchlog.txt."
    sleep 8
    pm_finish
    exit 1
  fi
  stamp > "$DATADIR/.port_prepared"
fi

mkdir -p "$GAMEDIR/saves"

# gptokeyb is unresponsive on muOS, so gptokeyb2 is used there
if [ "$CFW_NAME" = "muOS" ] && [ -n "$GPTOKEYB2" ]; then
  $GPTOKEYB2 "ruffle_sdl" -c "$GAMEDIR/MYPORT.gptk" &
else
  $GPTOKEYB "ruffle_sdl" -c "$GAMEDIR/MYPORT.gptk" &
fi
pm_platform_helper "$GAMEDIR/ruffle_sdl"

# ruffle_sdl: Ruffle on the firmware's own SDL2 and GLES 3 (no Weston or X11 needed).
# -Pname=value are flashvars the patched shell reads; keep only the ones your shell patch uses.
args=(--stage-scale movie --quality "$QUALITY" -Paspect="$ASPECT" -Pfps="$FRAME_RATE"
      --save-directory "$GAMEDIR/saves")
[ -n "$RENDER_SIZE" ] && args+=(--render-size "$RENDER_SIZE")

# BEGIN TESTING BLOCK (VERBOSE_LOGS=1). Delete this block, and the matching one below, before
# a PortMaster pull request: reviewers reject long launchers.
if [ "$VERBOSE_LOGS" = 1 ]; then
  echo "=== port environment $(date) ==="
  echo "uname: $(uname -a)"
  echo "CFW_NAME=$CFW_NAME DEVICE_NAME=$DEVICE_NAME DEVICE_CPU=$DEVICE_CPU DEVICE_ARCH=$DEVICE_ARCH"
  echo "DEVICE_RAM=$DEVICE_RAM DEVICE_HAS_SWAP=$DEVICE_HAS_SWAP DEVICE_HAS_ZRAM=$DEVICE_HAS_ZRAM"
  echo "display: ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}"
  echo "device glibc: $(ldd --version 2>&1 | head -n 1)"
  # the highest GLIBC symbol version the binary needs must not exceed min_glibc in port.json
  if command -v objdump > /dev/null 2>&1; then
    echo "ruffle_sdl needs glibc: $(objdump -T "$GAMEDIR/ruffle_sdl" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -n 1)"
  fi
  grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo
  echo "swaps:"; cat /proc/swaps
  for z in /sys/block/zram*; do [ -d "$z" ] && echo "$z disksize=$(cat "$z/disksize") comp=$(cat "$z/comp_algorithm")"; done
  echo "cfg: QUALITY=$QUALITY ASPECT=$ASPECT FRAME_RATE=$FRAME_RATE RENDER_SIZE=$RENDER_SIZE"
  echo "patch version: $PATCH_VERSION"
  printf 'run-ruffle ruffle_sdl'; printf ' %q' "${args[@]}" "$DATADIR/MYGAME-port.swf"; echo
  env | grep -E '^(RUST_LOG|RUFFLE_|PM_GPUSTAT|WGPU_|SDL_)' | sort
fi
# END TESTING BLOCK

# run-ruffle restarts Ruffle when the game asks for it (fscommand "relaunch"), so a big game that
# is split into several SWFs keeps only one of them in memory
"$GAMEDIR/tools/run-ruffle" "$GAMEDIR/ruffle_sdl" "${args[@]}" "$DATADIR/MYGAME-port.swf"
rc=$?

# BEGIN TESTING BLOCK
if [ "$VERBOSE_LOGS" = 1 ]; then
  echo "=== ruffle_sdl exited with code $rc $(date) (137 and 143 are normal after the quit hotkey) ==="
  grep -E '^(MemAvailable|SwapFree):' /proc/meminfo
  dmesg 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process|oom_reaper|mali.*(fail|err)' | tail -n 5
fi
# END TESTING BLOCK

# Clean up after ourselves
pm_finish

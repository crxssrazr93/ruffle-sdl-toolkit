#!/usr/bin/env bash
# apply_patch.sh: device side patch step (runs inside a PortMaster patchscript or by hand).
#
# CLI:
#   apply_patch.sh [--step N --total M] [--text "label"] <original> <md5> <patch.xdelta> <output>
#
#   <original>  the game's file as the user copied it (compressed or not)
#   <md5>       expected md5 of the ORIGINAL file as shipped by the store, or - to skip the gate
#   <patch>     xdelta3 delta made by make_patch.sh (against the inflated original)
#   <output>    where the patched file goes. If it is the same path as <original> the file is
#               patched in place and the untouched original is kept as <original>.orig.
#
# In place rules:
#   * no <original>.orig yet: md5 check the file, move it to .orig, patch from .orig.
#   * <original>.orig exists and the file starts with CWS or ZWS (compressed): that is a fresh
#     copy of the game (a patched file is always uncompressed FWS), so it replaces the kept .orig.
#   * otherwise the kept .orig is the source, so running the patch again is safe.
#   The .orig is md5 checked every time.
#
# Sourcing: `source apply_patch.sh` defines apply_swf_patch (same arguments, step and total
# taken from the shell variables STEP and TOTAL) and fail, without running anything.
#
# Output (what PortMaster's patcher screen expects):
#   [n/total] Patching <name>          progress line per step
#   PATCH_FAIL_MSG:<message>           then "Patching process failed!" and exit 1 on failure
#
# Tools: xdelta3 from $controlfolder if executable (PortMaster), else on PATH.
#        Inflate with atftool (tools/atf, env ATFTOOL, or on PATH): atftool inflate in out,
#        else python3 (zlib and lzma modules), no other dependency.
# Everything runs with LC_ALL=C.
export LC_ALL=C

PATCHER_SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STEP=${STEP:-0}
TOTAL=${TOTAL:-1}

fail() {
  echo "ERROR: $*"
  echo "PATCH_FAIL_MSG:Setup failed: $*"
  echo "Patching process failed!"
  exit 1
}

step() { STEP=$((STEP + 1)); echo "[$STEP/$TOTAL] $*"; }

find_xdelta() {
  XDELTA="${controlfolder:+$controlfolder/}xdelta3"
  [ -x "$XDELTA" ] || XDELTA=$(command -v xdelta3 || true)
  [ -n "$XDELTA" ] || fail "xdelta3 not found (install it or place it in the PortMaster control folder)"
}

file_md5() {
  if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | awk '{print $1}'
  elif command -v md5 >/dev/null 2>&1; then md5 -q "$1"
  else fail "no md5sum available"; fi
}

check_md5() { # file expected
  [ -f "$1" ] || fail "missing $1. Copy the complete game folder into the port's gamedata folder"
  [ "$2" = "-" ] && return 0
  local sum
  sum=$(file_md5 "$1")
  [ "$sum" = "$2" ] || fail "$1 has an unexpected checksum ($sum). Only the supported release of the game works"
}

# inflate <in> <out>: CWS and ZWS become FWS, FWS and anything else is copied
inflate_file() {
  local tool="${ATFTOOL:-}"
  [ -n "$tool" ] || tool=$(ls "$PATCHER_SELF/atftool" "$PATCHER_SELF/../atftool" "${GAMEDIR:-.}/tools/atftool" 2>/dev/null | head -n 1) || true
  [ -n "$tool" ] || tool=$(command -v atftool || true)
  if [ -n "$tool" ] && [ -x "$tool" ]; then
    "$tool" inflate "$1" "$2" && return 0
    return 1
  fi
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$1" "$2" <<'PY'
import struct, sys, zlib, lzma
d = open(sys.argv[1], "rb").read()
s = d[:3]
if s == b"CWS":
    d = b"FWS" + d[3:8] + zlib.decompress(d[8:])
elif s == b"ZWS":
    n = struct.unpack("<I", d[4:8])[0] - 8
    body = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE).decompress(d[12:17] + struct.pack("<Q", n) + d[17:])
    d = b"FWS" + d[3:8] + body
open(sys.argv[2], "wb").write(d)
PY
}

is_compressed() { # a file starting with CWS or ZWS is a store copy, patched files are FWS
  case "$(head -c 3 "$1" 2>/dev/null)" in CWS|ZWS) return 0 ;; esac
  return 1
}

# apply_swf_patch <original> <md5> <patch> <output> [label]
apply_swf_patch() {
  local orig=$1 sum=$2 patch=$3 out=$4 label=${5:-}
  local src=$orig
  [ -f "$patch" ] || fail "missing patch file $patch"
  find_xdelta
  if [ "$orig" = "$out" ]; then
    src="$orig.orig"
    if [ ! -f "$src" ] || is_compressed "$orig"; then
      # first run, or a fresh copy of the game replaces the kept original
      check_md5 "$orig" "$sum"
      mv -f "$orig" "$src" || fail "could not keep $src"
    fi
  fi
  step "Patching ${label:-$(basename "$out")}"
  check_md5 "$src" "$sum"
  inflate_file "$src" "$out.tmp" || { rm -f "$out.tmp"; fail "could not decompress $src"; }
  "$XDELTA" -d -f -s "$out.tmp" "$patch" "$out.new" || { rm -f "$out.tmp" "$out.new"; fail "xdelta3 failed on $src"; }
  rm -f "$out.tmp"
  mv -f "$out.new" "$out" || fail "could not write $out"
}

main() {
  set -euo pipefail
  local label=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --step)  STEP=$(( $2 - 1 )); shift 2 ;;
      --total) TOTAL=$2; shift 2 ;;
      --text)  label=$2; shift 2 ;;
      -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      --) shift; break ;;
      -*) echo "unknown option $1" >&2; exit 1 ;;
      *) break ;;
    esac
  done
  [ $# -eq 4 ] || { echo "usage: $0 [--step N --total M] [--text label] <original> <md5|-> <patch.xdelta> <output>" >&2; exit 1; }
  GAMEDIR="${GAMEDIR:-$(pwd)}"
  apply_swf_patch "$1" "$2" "$3" "$4" "$label"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi

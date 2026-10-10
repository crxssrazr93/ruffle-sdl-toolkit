#!/usr/bin/env bash
# make_patch.sh <orig.swf> <new.swf> <out.xdelta>
#
# Build a binary delta that turns <orig.swf> into <new.swf>, for shipping a patch instead of
# the patched game. Both files are inflated to uncompressed SWF (FWS) first, because a delta
# against a compressed stream is useless (one changed byte rewrites the whole zlib or LZMA
# stream). The device inflates the original the same way before applying (apply_patch.sh).
# Non SWF inputs (data files) are used as they are.
#
# xdelta3 is run as   xdelta3 -e -9 -S none -f -s ORIG NEW OUT   (no secondary compression,
# PortMaster's xdelta3 build has no LZMA support). The delta is verified by decoding it and
# comparing with cmp.
#
# xdelta3 source: the local binary when installed, otherwise a Docker alpine:3 container
# (apk add xdelta3). Override with XDELTA3=/path/to/xdelta3, or force Docker with USE_DOCKER=1.
# Docker needs network the first time (image and package download).
#
# Exit codes: 0 ok, 1 usage or missing file, 2 no xdelta3 and no docker, 3 encode or verify failed.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
inflate="$here/../swf/swf_inflate.py"

usage() { echo "usage: $0 <orig.swf> <new.swf> <out.xdelta>" >&2; exit 1; }
[ $# -eq 3 ] || usage
orig=$1; new=$2; out=$3
[ -f "$orig" ] || { echo "make_patch: no such file $orig" >&2; exit 1; }
[ -f "$new" ] || { echo "make_patch: no such file $new" >&2; exit 1; }
command -v python3 >/dev/null || { echo "make_patch: python3 is required" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

prep() { # in out: inflate a SWF, copy anything else
  case "$(head -c 3 "$1")" in
    CWS|ZWS|FWS) python3 "$inflate" "$1" "$2" ;;
    *) cp "$1" "$2" ;;
  esac
}
prep "$orig" "$tmp/orig"
prep "$new" "$tmp/new"
mkdir -p "$(dirname "$out")"
out_abs=$(cd "$(dirname "$out")" && pwd)/$(basename "$out")

use_local=0
XD="${XDELTA3:-}"
if [ -z "${USE_DOCKER:-}" ]; then
  [ -n "$XD" ] || XD=$(command -v xdelta3 || true)
  [ -n "$XD" ] && use_local=1
fi

if [ "$use_local" = 1 ]; then
  "$XD" -e -9 -S none -f -s "$tmp/orig" "$tmp/new" "$out_abs" || { echo "make_patch: xdelta3 encode failed" >&2; exit 3; }
  "$XD" -d -f -s "$tmp/orig" "$out_abs" "$tmp/check" || { echo "make_patch: verify decode failed" >&2; exit 3; }
else
  command -v docker >/dev/null || { echo "make_patch: xdelta3 not installed and docker not found" >&2; exit 2; }
  # the container works on a private copy of the inputs, the output is chowned back to you
  docker run --rm -v "$tmp":/w alpine:3 sh -c '
    apk add -q xdelta3 >/dev/null &&
    xdelta3 -e -9 -S none -f -s /w/orig /w/new /w/out.xdelta &&
    xdelta3 -d -f -s /w/orig /w/out.xdelta /w/check &&
    chown '"$(id -u):$(id -g)"' /w/out.xdelta /w/check' \
    || { echo "make_patch: xdelta3 in docker failed" >&2; exit 3; }
  cp "$tmp/out.xdelta" "$out_abs"
fi

cmp -s "$tmp/check" "$tmp/new" || { echo "make_patch: round trip mismatch, delta is bad" >&2; rm -f "$out_abs"; exit 3; }
echo "make_patch: $(basename "$out") $(wc -c < "$out_abs") bytes (orig $(wc -c < "$tmp/orig"), new $(wc -c < "$tmp/new")), round trip OK"

#!/usr/bin/env bash
# make_manifest.sh <dir> [glob ...]
#
# Print an md5 manifest of the files under <dir>, to stdout, one per line:
#     <md5>  <path relative to dir>        (two spaces, the md5sum -c format)
# sorted with LC_ALL=C so the result is the same on every machine.
# Globs are matched against the file name (find -name), for example:
#     make_manifest.sh gamedata '*.swf' '*.atf' '*.xml' > tools/patch/files.txt
# With no glob every regular file is listed. Quote the globs so the shell does not expand them.
# The manifest contains checksums and names only, no game content, so it is safe to ship.
# Verify on the device with:  cd gamedata && md5sum -c files.txt
#
# Exit codes: 0 ok, 1 usage or bad directory.
set -euo pipefail
export LC_ALL=C

[ $# -ge 1 ] || { echo "usage: $0 <dir> ['glob' ...]" >&2; exit 1; }
dir=$1; shift
[ -d "$dir" ] || { echo "make_manifest: not a directory: $dir" >&2; exit 1; }

md5() { if command -v md5sum >/dev/null; then md5sum "$1" | cut -d' ' -f1; else md5 -q "$1"; fi; }

cd "$dir"
args=()
if [ $# -gt 0 ]; then
  args+=(\()
  first=1
  for g in "$@"; do
    [ "$first" = 1 ] || args+=(-o)
    args+=(-name "$g"); first=0
  done
  args+=(\))
fi
find . -type f "${args[@]}" -print | sed 's|^\./||' | sort |
  while IFS= read -r f; do
    printf '%s  %s\n' "$(md5 "$f")" "$f"
  done

#!/bin/bash
# fetch.sh [dir]
# Clone Ruffle at the commit pinned in PIN and apply the patch series with git am.
#
#   dir             where to put the Ruffle tree (default: ./ruffle-src next to the current directory)
#   RUFFLE_REPO     clone URL or local path (default https://github.com/ruffle-rs/ruffle.git)
#   WITH_OPTIONAL   space separated numbers of patches from optional/ to apply after the series,
#                   e.g. WITH_OPTIONAL="0100"
#
# The patches keep their original authors. git am needs a committer identity, so GIT_COMMITTER_*
# defaults to "ruffle-sdl-toolkit" if you have none configured.
set -euo pipefail

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}
[ "$#" -le 1 ] || usage
case "${1:-}" in -h|--help) usage ;; esac

here=$(cd "$(dirname "$0")" && pwd)
dir="${1:-$PWD/ruffle-src}"
repo="${RUFFLE_REPO:-https://github.com/ruffle-rs/ruffle.git}"
pin=$(tr -d '[:space:]' < "$here/PIN")

if [ -d "$dir/.git" ]; then
  echo "using existing tree $dir"
else
  git clone --no-checkout "$repo" "$dir"
fi
git -C "$dir" cat-file -e "$pin^{commit}" 2>/dev/null || git -C "$dir" fetch origin "$pin" || git -C "$dir" fetch origin
git -C "$dir" checkout -q "$pin"

ident=(-c "user.name=${GIT_COMMITTER_NAME:-ruffle-sdl-toolkit}" -c "user.email=${GIT_COMMITTER_EMAIL:-toolkit@localhost}")
mapfile -t patches < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$here/series" | grep -v '^$')
[ "${#patches[@]}" -gt 0 ] || { echo "empty series" >&2; exit 1; }
list=()
for p in "${patches[@]}"; do list+=("$here/patches/$p"); done
for n in ${WITH_OPTIONAL:-}; do
  m=$(ls "$here"/optional/"$n"-*.patch 2>/dev/null | head -n1 || true)
  [ -n "$m" ] || { echo "no optional patch $n" >&2; exit 1; }
  list+=("$m")
done

git -C "$dir" "${ident[@]}" am -q "${list[@]}"
git -C "$dir" log --format='%h %an: %s' "$pin..HEAD"
echo "ruffle tree ready: $dir"

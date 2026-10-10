#!/usr/bin/env bash
# Round trip test for make_patch.sh, make_manifest.sh and apply_patch.sh on tiny generated SWFs.
# Uses a local xdelta3 when installed, otherwise Docker alpine:3 for both the build and the apply.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tools=$(cd "$here/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass() { echo "PASS $*"; }
die() { echo "FAIL $*" >&2; exit 1; }

# generate: original compressed (CWS) and ZWS variants, and a modified FWS
python3 - "$tmp" "$tools/swf/tests" <<'PY'
import sys
sys.path.insert(0, sys.argv[2]); sys.path.insert(0, sys.argv[2] + "/..")
import test_swf_tools as t
d = sys.argv[1]
base = t.make_fws()
new = t.make_fws(abc=True, atf=True)
open(d + "/game.fws", "wb").write(base)
open(d + "/game.cws", "wb").write(t.make_cws(base))
open(d + "/game.zws", "wb").write(t.make_zws(base))
open(d + "/new.fws", "wb").write(new)
open(d + "/new.cws", "wb").write(t.make_cws(new))
PY

"$here/make_patch.sh" "$tmp/game.cws" "$tmp/new.cws" "$tmp/p.xdelta" || die make_patch
[ -s "$tmp/p.xdelta" ] && pass "make_patch (CWS in, CWS out, delta made against FWS)"

# manifest
mkdir -p "$tmp/m/sub dir"; echo a > "$tmp/m/b.swf"; echo b > "$tmp/m/a.swf"; echo c > "$tmp/m/sub dir/c.atf"; echo d > "$tmp/m/skip.txt"
"$here/make_manifest.sh" "$tmp/m" '*.swf' '*.atf' > "$tmp/man.txt"
[ "$(wc -l < "$tmp/man.txt")" = 3 ] || die "manifest line count"
[ "$(cut -d' ' -f3- "$tmp/man.txt" | tr '\n' '|')" = "a.swf|b.swf|sub dir/c.atf|" ] || die "manifest order or names"
(cd "$tmp/m" && md5sum -c "$tmp/man.txt" >/dev/null) || die "manifest md5sum -c"
pass "make_manifest (format, order, md5sum -c)"

# apply on the "device"
sum() { md5sum "$1" | cut -d' ' -f1; }
cat > "$tmp/dev.sh" <<'DEV'
set -eu
cd "$1"
src="$2"
mkdir -p g; cp game.cws g/game.swf
orig=$(md5sum g/game.swf | cut -d' ' -f1)
# first apply, in place
"$src/apply_patch.sh" --step 1 --total 2 g/game.swf "$orig" p.xdelta g/game.swf
cmp g/game.swf new.fws.expected; test -f g/game.swf.orig
head -c 3 g/game.swf.orig | grep -q CWS
# second apply keeps working from the kept .orig
"$src/apply_patch.sh" --step 2 --total 2 g/game.swf "$orig" p.xdelta g/game.swf
cmp g/game.swf new.fws.expected
# a fresh compressed copy replaces the kept .orig (different file, new md5 expected)
cp game.zws g/game.swf
orig2=$(md5sum g/game.swf | cut -d' ' -f1)
"$src/apply_patch.sh" g/game.swf "$orig2" p.xdelta g/game.swf >/dev/null
cmp g/game.swf new.fws.expected
head -c 3 g/game.swf.orig | grep -q ZWS
# wrong md5 must fail with the patcher markers
cp game.cws g/other.swf
if "$src/apply_patch.sh" g/other.swf 00000000000000000000000000000000 p.xdelta g/out.swf > out.log; then echo "md5 gate did not fire"; exit 1; fi
grep -q '^PATCH_FAIL_MSG:' out.log; grep -q 'Patching process failed!' out.log
# separate output path
"$src/apply_patch.sh" g/other.swf - p.xdelta g/out.swf
cmp g/out.swf new.fws.expected
echo DEVICE_OK
DEV
cp "$tmp/new.fws" "$tmp/new.fws.expected"
if command -v xdelta3 >/dev/null; then
  bash "$tmp/dev.sh" "$tmp" "$here"
else
  docker run --rm -v "$tmp":/w -v "$here":/src:ro alpine:3 sh -c \
    'apk add -q bash python3 xdelta3 >/dev/null && bash /w/dev.sh /w /src; rc=$?; chown -R '"$(id -u):$(id -g)"' /w; exit $rc' > "$tmp/dev.out" 2>&1 || { cat "$tmp/dev.out"; die "device apply"; }
  grep -q DEVICE_OK "$tmp/dev.out" || { cat "$tmp/dev.out"; die "device apply"; }
fi
pass "apply_patch (in place, .orig kept, rerun, md5 gate, separate output)"
echo "all delivery tests passed"

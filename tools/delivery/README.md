# tools/delivery: shipping patches, not games

You may not redistribute a game. You can redistribute a binary delta that only works on
files the user already owns, plus a checksum manifest that lets the device refuse the
wrong release with a clear message. Three scripts cover that.

| Script | Runs on | Purpose |
| --- | --- | --- |
| make_patch.sh | your PC | Inflate original and patched SWF, create and verify an xdelta3 delta. |
| make_manifest.sh | your PC | Print an md5 manifest of files, LC_ALL=C sorted. |
| apply_patch.sh | the device | md5 gate, inflate, apply the delta, keep `.orig`, report progress. |
| tests/test_delivery.sh | your PC | Round trip test on tiny generated SWFs. |

## make_patch.sh

    make_patch.sh <orig.swf> <new.swf> <out.xdelta>

Both SWFs are inflated to FWS first (swf_inflate.py from ../swf), because a delta against a
compressed stream rewrites everything after the first changed byte. The delta is built with

    xdelta3 -e -9 -S none -f -s ORIG NEW OUT

`-S none` turns secondary compression off: the xdelta3 build that PortMaster ships has no
LZMA support, and a delta that needs it fails on the device. The delta is then decoded again
and compared with `cmp`, so a bad delta is never written.

xdelta3 comes from the local install when there is one (override with `XDELTA3=/path`).
Otherwise the script runs it in a throwaway Docker container, `docker run --rm -v ... alpine:3
sh -c 'apk add xdelta3 ...'`, with the inputs in a temporary folder and the output
returned to you with your user ownership. Set `USE_DOCKER=1` to force the container route.
Docker needs network access the first time (image and package download).

Exit codes: 0 ok, 1 usage or missing input, 2 neither xdelta3 nor docker, 3 encode or
verify failed.

Remember to bump your port's patch version file whenever a delta changes, so that
already prepared installs patch again.

## make_manifest.sh

    make_manifest.sh <dir> ['*.swf' '*.atf' ...] > files.txt

Output lines are `<md5>  <relative path>` (two spaces, the `md5sum -c` format), sorted with
`LC_ALL=C`, so the file is identical on every machine. Globs are matched against the file
name, with no globs every regular file is listed. The manifest holds names and checksums
only, so it can be shipped. On the device:

    cd gamedata && md5sum -c ../tools/patch/files.txt

A setup script can read it line by line to check that every needed file exists and is the
supported release, and to decide which conversions are still missing.

## apply_patch.sh

    apply_patch.sh [--step N --total M] [--text "label"] <original> <md5|-> <patch.xdelta> <output>

Runs on the handheld, in bash, from a PortMaster patchscript or by hand.

1. xdelta3 is taken from `$controlfolder/xdelta3` when that is executable, otherwise from PATH.
2. The original is checked against the expected md5 (`-` skips the check). A missing file
   or a wrong checksum stops with a message that tells the user what to do.
3. The original is inflated with `atftool inflate` (from ../atf, found through `ATFTOOL`,
   next to the script, in the port's tools folder or on PATH), otherwise with an embedded
   python3 fallback that handles CWS and ZWS.
4. The delta is applied to the inflated file and moved into place atomically.

In place patching, where `<output>` equals `<original>`:

* The untouched original is kept as `<original>.orig` and every later run patches from it,
  so setup can be run any number of times.
* A patched SWF is always uncompressed. If the file at `<original>` starts with `CWS` or
  `ZWS`, the user has copied a fresh game over it. That file is md5 checked and replaces
  the kept `.orig`.

Output follows what PortMaster's patcher screen reads:

    [2/5] Patching World2.swf
    ERROR: ... 
    PATCH_FAIL_MSG:Setup failed: <reason>
    Patching process failed!

The `[n/total]` lines drive the progress text, and the last two lines make the patcher report
a failure instead of "completed". Everything runs with `LC_ALL=C`.

You can also source the script. It then defines `apply_swf_patch <original> <md5> <patch>
<output> [label]`, `fail`, `step`, `check_md5` and `inflate_file` and runs nothing, using the
`STEP` and `TOTAL` variables for progress:

    source "$GAMEDIR/tools/apply_patch.sh"
    TOTAL=3
    apply_swf_patch Game.swf "$md5_game" "$PATCHDIR/Game.xdelta" Game-port.swf
    apply_swf_patch World1/W1.swf "$md5_w1" "$PATCHDIR/W1.xdelta" World1/W1.swf

Copy `apply_patch.sh` into the port's tools folder next to the patch files.

## Testing

`tests/test_delivery.sh` generates a tiny compressed SWF and a modified one, builds a delta,
checks the manifest format and applies the delta in place several times, including the fresh
copy replacing the kept original, the md5 failure markers and a separate output path. It
uses the local xdelta3 or Docker alpine:3 for both the build and the apply step.

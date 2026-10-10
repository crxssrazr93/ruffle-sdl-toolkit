# 03 Delivery

## When you need this

Read this when your patched SWFs work on the PC and you have to get them onto users' handhelds without shipping any game content. It explains the delta approach (xdelta3 over inflated SWFs), how the device side patcher behaves, how the setup state markers and stamps work, and the robustness rules that came out of testing on several firmwares. The model is: the user copies their own game files, the port applies small deltas, converts what must be converted, and records that it did so.

## 1. Why deltas, and why inflate first

The port package holds code only: the binaries, xdelta patches, a patch version file, an md5 manifest, a patch script and a run wrapper. No game data, no GPU blob. Source is linked from the submission.

SWFs are usually compressed. CWS is zlib, ZWS is LZMA, FWS is plain. A delta against a compressed file is roughly the size of the file (up to 11 MB in the example), because one changed byte rewrites the whole compressed stream. Against the inflated (FWS) file the deltas were 0.1 to 47 KB; shipped delta sizes in the finished port ranged from 90 bytes to 8 KB, with one Stage3D world at 76 KB.

Inflate both the original and the patched SWF before diffing:

```
python3 tools/swf/swf_inflate.py original.swf original.fws.swf
python3 tools/swf/swf_inflate.py patched.swf  patched.fws.swf
```

`swf_inflate.py <in.swf> <out.swf>` accepts FWS (copied unchanged), CWS (zlib) and ZWS (LZMA, rebuilt into an LZMA alone header). Exit codes: 0 ok, 1 usage, 2 unreadable input, 3 not a SWF or corrupt data. For CWS the conversion is `'FWS' + d[3:8] + zlib.decompress(d[8:])`. On the device the same job is done by `atftool inflate <in> <out>` (doc 07), which also handles CWS and ZWS, because there is no Python there. Both keep the version and length fields and only change the signature to `FWS`.

## 2. xdelta3 with `-S none`

PortMaster's xdelta3 has no LZMA secondary compressor. A delta built by a stock xdelta3 (Alpine's encodes with LZMA secondary by default) fails on the device with:

```
unavailable secondary compressor: LZMA
```

Always disable secondary compression:

```
xdelta3 -e -9 -S none -f -s orig.fws.swf new.fws.swf out.xdelta
xdelta3 -d -f -s orig.fws.swf out.xdelta /tmp/check.swf && cmp /tmp/check.swf new.fws.swf
```

`tools/delivery/make_patch.sh` does all of it:

```
tools/delivery/make_patch.sh original.swf patched.swf out/Shell.swf.xdelta
```

It inflates both inputs, runs `xdelta3 -e -9 -S none -f -s`, and verifies the round trip with `xdelta3 -d` plus `cmp` before it writes the delta, so a bad delta is never left behind. It uses the local `xdelta3` (override with `XDELTA3=/path`) and otherwise runs it in a throwaway `alpine:3` Docker container, which needs network the first time. `USE_DOCKER=1` forces the container. Exit codes: 0 ok, 1 usage or missing input, 2 neither xdelta3 nor Docker, 3 encode or verify failed. It was tested with xdelta3 in a Docker alpine container.

To do the same by hand without xdelta3 on your PC, build deltas in a throwaway container and always force the architecture:

```
docker run --rm --platform linux/amd64 -v "$PWD/fws:/w:ro" -v "$PWD/out:/out" alpine \
  sh -c 'apk add -q xdelta3 && xdelta3 -e -9 -S none -f -s /w/o.swf /w/n.swf /out/x.xdelta && chown '"$(id -u):$(id -g)"' /out/*'
```

Pitfalls seen here: a local `alpine` image had silently become arm64, nothing ran, and the device re patched with old deltas while recording the new version. A periodic `docker system prune -af` also deleted helper images. To run the real device patch script on the PC without installing xdelta3, put a shim `bin/xdelta3` on PATH that execs `docker run --rm -u $(id -u):$(id -g) -v "$PWD":"$PWD" -w "$PWD" <image> xdelta3 "$@"`. Rebuild the image with `printf 'FROM alpine\nRUN apk add -q xdelta3\n' | docker build -t xd3 -` (no entrypoint), or use `ubuntu:20.04` with apt.

## 3. The device side patch step

Two pieces implement the same contract. `tools/delivery/apply_patch.sh` is the standalone, generic apply for one file. The template `templates/port/MYPORT/tools/patchscript` does the same for every row of a table (section 8) and is what a port normally ships. The contract of a patch step:

1. Check the original exists, then check its md5 against the manifest (section 7). Missing file and wrong file are different errors.
2. For an in place patch, keep the original as `<file>.orig` and always patch from `.orig`. A fresh copy of the game replaces `.orig` (section 6).
3. Inflate the original to a temporary file, apply the xdelta to a `.new` file, then `mv -f` over the output. The input is never modified, so re running gives byte identical output and an interrupted run leaves nothing half written that the next run trusts.
4. A shell that becomes a new file (for example `Shell-port.swf`) is written next to the original and the original stays untouched. Sub movies are usually patched in place, with the original kept as `<file>.orig`.

`apply_patch.sh [--step N --total M] [--text "label"] <original> <md5|-> <patch.xdelta> <output>` takes `xdelta3` from `$controlfolder/xdelta3` when executable, otherwise from `PATH`. The md5 `-` skips the check. It inflates with `atftool inflate` (found through `ATFTOOL`, next to the script, in the port's tools folder or on `PATH`) and falls back to an embedded python3 snippet that handles CWS and ZWS. It prints the lines the patcher screen reads (`[2/5] Patching World2.swf`, `ERROR: ...`, `PATCH_FAIL_MSG:Setup failed: ...`, `Patching process failed!`) and runs with `LC_ALL=C`. When sourced it defines `apply_swf_patch`, `fail`, `step`, `check_md5` and `inflate_file` and runs nothing. See `tools/delivery/README.md`.

Keep an md5 table (the manifest) for every SWF. Print an error that says what to do: `missing X. Copy the whole game folder into ports/<port>/gamedata/` or `X has an unexpected checksum (<sum>). Only the supported release of the game works.`

## 4. The patch version file

`tools/patch/version` is one integer. Bump it every time a patch changes. It is the first line of the stamp (section 5), so changing it forces every install to re run setup once (6 to 8 seconds in the example, plus any conversion).

Rules:

- A version that has been published is immutable. If it shipped, the next change is a new number.
- For upgrades that should reach already prepared installs without a full re copy, ship `patch/<file>.<old patched MD5>.xdelta` upgrade deltas.

## 5. Markers and stamps

Two files in `gamedata/` do two jobs. Do not merge them.

| File | Written by | Content | Meaning |
|---|---|---|---|
| `.port_patched` | The patch script, as its very last step, only on success | `PATCH_VERSION` only | "The patch script finished" |
| `.port_prepared` | The launcher, after it verified `.port_patched` | Patch version line, then one line per output with size and mtime | "The current outputs match this version" |

History: first `.port_prepared` held only the version, which let a re copied game run unpatched. Then the stamp was added. Finally the stamp logic moved into the launcher where reviewers read it, and the patch script only reports success through `.port_patched`.

The stamp is the patch version plus the size and modification time of every output (patched SWFs, atlas XMLs, PNGs, level SWFs). The launcher compares `"$(echo $PATCH_VERSION; stamp)"` with the file. If anything was touched, deleted or re copied, setup runs again.

Rules for writing a stamp that works on every firmware:

- No `stat`. muOS has none. The stamp came out empty and one port compared empty to empty and skipped patching. Use only portable forms, under `LC_ALL=C`:

```
size=$(ls -lnL "$f" | awk '{print $5}')
mtime=$(date -r "$f" +%s)
```

- `LC_ALL=C` everywhere, including any `sort`. A stamp written in one locale and compared in another mismatched because globs listed files in locale order. Use a fixed list or `LC_ALL=C sort`.
- Run the stamp function in a subshell if it changes directory.
- mtimes can change across firmwares. An exFAT card read under Knulli and then muOS shows times 2 hours apart, so setup re runs once after switching firmware. Harmless, expect it.

Launcher flow (the template is `templates/port/launcher.sh`):

```
rm -f "$DATADIR/.port_patched"
export PATCHER_FILE="$GAMEDIR/tools/patchscript"
export PATCHER_GAME="$(basename "${0%.*}")"
export PATCHER_TIME="a few minutes"
source "$controlfolder/utils/patcher.txt"
if [ "$(cat "$DATADIR/.port_patched" 2>/dev/null)" != "$PATCH_VERSION" ]; then
  pm_message "Preparing the game failed, see ports/<port>/patchlog.txt."
  sleep 8; pm_finish; exit 1
fi
# only now write the .port_prepared stamp
```

## 6. Fresh copies win over kept originals

The user may copy the game again over a prepared install, or install an updated build. Decide per file what is "original":

- `apply_patch.sh`: a file at the output path whose first three bytes are `CWS` or `ZWS` is a fresh store copy, because patched ones are stored as FWS. It is md5 checked and replaces `.orig`.
- The template patchscript uses a different test that also works for stores that ship uncompressed SWFs: for an in place row, a file whose md5 equals the manifest entry is a fresh original and is moved over `.orig` (`mv -f "$orig" "$orig.orig"`). Anything else at that path is a leftover patched file, and the kept `.orig` is used.
- An atlas XML that is neither the original nor its scaled version becomes the new original.
- A freshly moved subfolder replaces the old one: `rm -rf dest && mv src dest`.

## 7. md5 manifests and converting only missing outputs

For loose assets (level SWFs, ATF textures, atlas XMLs), generate a manifest at build time from the user's own copy:

```
tools/delivery/make_manifest.sh /path/to/game 'Levels/*.swf' 'Levels/*.atf' '*.xml' > templates/port/MYPORT/tools/patch/manifest.txt
```

The script prints to stdout (redirect it yourself). Each line is `<md5>  <relative path>` with two spaces, the `md5sum -c` format, sorted with `LC_ALL=C` so it is identical on every machine. Globs match file names, with no globs every regular file is listed. The file contains no game content, and `cd gamedata && md5sum -c ../tools/patch/manifest.txt` checks a copy of the game by hand. In the template port the manifest is `tools/patch/manifest.txt`, listing the originals the patchscript is allowed to use (paths relative to `gamedata/`). Setup checks SWFs always, XMLs against `.orig`, and an ATF only when its PNG has to be made. Tested cases for the 42 entry example: fresh install, one PNG deleted, embedded PNG deleted, ATF missing, ATF damaged, XML and its `.orig` missing, level SWF missing, restored.

Convert only missing outputs:

- Skip an `atf` job when the matching `.png` exists. Skip a `swf` extraction job when its marker `<outdir>/.done.<swf name>` exists. Both are what the template patchscript does for `tools/patch/atf.txt`.
- Re extract embedded atlas PNGs only if the marker is missing (delete the `.done.*` file to force it).
- Verify each PNG after conversion. Write to a temp file and rename (the converter does).
- A deleted PNG is reconverted alone (8 seconds on the device in the example).

## 8. patcher.txt integration

PortMaster's patcher screen is driven by `utils/patcher.txt`. Set the variables, then source it:

| Variable | Use |
|---|---|
| `PATCHER_FILE` | Absolute path of your patch script |
| `PATCHER_GAME` | Display name (the launcher basename) |
| `PATCHER_TIME` | Free text estimate, for example "a few minutes" |

Protocol details:

- Your script prints `PATCH_FAIL_MSG:<message>` to replace the failure text, and `Patching process failed!` to mark failure. Without this a failed setup still showed "completed".
- patcher.txt already calls `pm_gptokeyb_finish`. Do not kill gptokeyb yourself (a `kill -9 $(pidof gptokeyb)` after the patcher was removed in review).
- Numbered steps like `[3/29]` are read as progress. There is no real bar. Compute TOTAL up front (5 fixed steps plus one per texture to convert).
- The patcher waits for A or Enter before running your script and again at the end. While it waits, EmulationStation reports a running game, so a new launch request is ignored. The setup log is stale until A is pressed.
- `fail()` in your script: print `ERROR: msg`, `PATCH_FAIL_MSG:Setup failed: msg`, `Patching process failed!`, exit 1.
- Require patcher.txt. If `$controlfolder/utils/patcher.txt` is missing, `pm_message "This port requires the latest version of PortMaster."` and exit. A fallback that ran `bash tools/patchscript` was a dead end: it was removed to match merged ports.
- Call `pm_finish` before every error exit, otherwise PortMaster cleanup (gptokeyb and others) is skipped.
- Log the setup to `patchlog.txt` with `exec > >(tee "$GAMEDIR/patchlog.txt") 2>&1`, so it can be attached to a bug report.

Script shape (`templates/port/MYPORT/tools/patchscript`, generic and driven by the tables in `tools/patch/`):

```
GAMEDIR, DATADIR, PATCHDIR, ATFTOOL (tools/atftool), XDELTA ($controlfolder/xdelta3, else xdelta3 on PATH)
exec > >(tee "$GAMEDIR/patchlog.txt") 2>&1
plan:  count the steps from files.txt, atf.txt (only jobs still needed) and atlas.txt
1  files.txt   "orig|patch|out": md5 check against manifest.txt, keep .orig, inflate, xdelta3 -d, mv -f
2  atlas.txt   "factor|file.xml": always scaled from file.xml.orig with atftool atlasxml
3  atf.txt     "kind|scale|input|outdir": atftool atf or atftool swf for what is still missing
4  cleanup.txt one glob per line, relative to gamedata/, absolute paths and .. refused
cat tools/patch/version > gamedata/.port_patched ; echo "=== Done. Enjoy! ==="
```

Clean only what you know is dead, and list it in `cleanup.txt` (for example `Adobe AIR`, `META-INF`, `*.exe`, `*.dll`, `mimetype`). Never broader, and never name emulator folders. The patchscript writes its log to `$GAMEDIR/patchlog.txt` (an absolute path, which is fine here because gptokeyb's kill name does not appear in it, unlike the launcher's log, see doc 11).

First run time: about 1.5 minutes for 29 steps on an RG35XX H class device in the example, about 30 seconds on a PC, and 18 minutes for one unrelated port's conversion on an H700 with 2 threads. Report the real number to users. Compare device and PC outputs by size or md5 to validate the device path.

## 9. The seven robustness rules

These came from testers on muOS who hit missing files and the message `unexpected version (MD5 )` across several ports.

1. Markers live next to the files they describe (in `gamedata`).
2. Judge "prepared" from outputs (stamp plus version), not from a flag alone.
3. Fresh copies win over `.orig`.
4. Write the marker before the atomic rename of the final output, never after an unchecked step.
5. Check existence before the checksum. Say "missing, copy the whole game again". Never print an empty md5. On failure run `find "$DATADIR" -name <basename>` and write a gamedata listing to the setup log. Keep names with spaces in that listing (an awk version cut at the first space).
6. For in place patched packs, point missing entries back at originals.
7. A cache named by path needs a content key (the original's md5).

Test matrix: reinstall, re copy over a prepared install, interrupted run, deleted outputs, one missing file, game update. After you swap a stamped file for a test, regenerate the stamp or setup re runs, and keep an md5 verified backup.

## 10. Third party binaries and licences

Fetch ffdec, Ruffle sources and toolchains pinned to a commit or md5 at build time. Never commit them. Add the build cache folder to `.gitignore` (a missed ignore nearly allowed binaries into the repo). List licences of anything you ship (jxrlib BSD notice for the JPEG XR crate, MIT crates, Apache 2.0 crates) next to the converter.

## Pitfalls

- Diffing compressed SWFs. Deltas become the file size.
- Forgetting `-S none`. Device error `unavailable secondary compressor: LZMA`.
- Running xdelta in a container without `--platform linux/amd64`.
- Using `stat`, or an unset `LC_ALL`, in a stamp.
- Comparing an empty stamp to an empty file. Check existence first.
- Writing `.port_prepared` before `.port_patched` is verified.
- Not deleting `.port_patched` before a patch run, so a stale success passes.
- Patching in place with no `.orig`, or from a patched file instead of `.orig`.
- Letting a fresh copy lose to a stale `.orig`.
- A failure path that skips `pm_finish`.
- Reusing a published version number.
- Broad cleanup globs.

## See also

- 02 Shell patching (what the deltas contain).
- 07 Textures and ATF (the converter and the converted marker).
- 10 Testing (running the real patch script on the PC, mock launcher).
- 11 Launcher and packaging.
- `tools/delivery/README.md`, `templates/port/launcher.sh`, `templates/port/MYPORT/tools/patchscript`.

# 11 Launcher and packaging

## When you need this

Read this when you turn a patched Flash or AIR game into a PortMaster port: filling in the launcher template, the cfg and gptk files, the patcher and its markers, the relaunch wrapper, the metadata files, the release zip, and the review and testing thread steps. The templates live in `templates/port/`. This page explains why each line is there so you can defend it in review.

## The template walk through

`templates/port/launcher.sh` is a PortMaster standard launcher for a `ruffle_sdl` port. In order:

1. **Line 2 must be the PORTMASTER header.** `# PORTMASTER: MYPORT.zip, MYGAME.sh`. Without it harbourmaster inserts the header on the first runtime download and rewrites the running script ("untime_check: command not found" and a syntax error). It is also needed for the port to be listed in Manage Ports. Hand copied ports without it do not appear on some firmwares. Install test builds the way a release installs.
2. **`controlfolder` detection** (`/opt/system/Tools/PortMaster`, `/opt/tools/PortMaster`, `$XDG_DATA_HOME/PortMaster`, `/roms/ports/PortMaster`), then `source control.txt`, `source mod_${CFW_NAME}.txt` when present, and `get_controls`. This is the standard block, keep it as is.
3. **`GAMEDIR="/$directory/ports/MYPORT"`**, then `cd "$GAMEDIR"`. Replace MYPORT with the lower case folder name.
4. **`source MYPORT.cfg`**. All user settings come from the cfg. No defaults are duplicated in the launcher. Tell users in the port README how to reset the cfg.
5. **Relative tee.** `exec > >(tee log.txt) 2>&1` after the `cd`. Not `tee "$GAMEDIR/log.txt"`. See "Why a relative tee" below.
6. **`chmod +x`** for `ruffle_sdl` and the tools, with `$ESUDO`.
7. **The setup gate** (stamp, patcher). See below.
8. **`mkdir -p saves`**.
9. **gptokeyb** (or gptokeyb2 on muOS) with `-c MYPORT.gptk`, watching `ruffle_sdl`.
10. **`pm_platform_helper "$GAMEDIR/ruffle_sdl"`**. Pass the real binary.
11. **The `run-ruffle` call** with the front end arguments:
    `--stage-scale movie --quality "$QUALITY" -Paspect="$ASPECT" -Pfps="$FRAME_RATE" --save-directory "$GAMEDIR/saves" <shell>.swf`, plus `--render-size "$RENDER_SIZE"` when the cfg sets one. Keep only the `-P` flashvars your patched shell reads.
12. **`pm_finish`** at the end, and before every error exit. Otherwise PortMaster's cleanup (gptokeyb and so on) is skipped.

Front end arguments, for reference (patch 0006): `--width` and `--height` (default full screen), `-q/--quality` (default `low`, the fastest, no AA), `--player-runtime` (default `air`), `--save-directory` (required), `-Pkey=value` flashvars (repeatable), `--render-size WxH` (draw at this size and scale up), `--gl-finish` (replace GL fence waits by `glFinish`, for drivers with a broken `glClientWaitSync`) and `--stage-scale fit|movie` (default `fit`: centred with letterbox bars; `movie`: the movie's own scale mode and alignment). The quality names come from Ruffle's own `StageQuality` parser (`low`, `medium`, `high`, `best`, `8x8`, `8x8linear`, `16x16`, `16x16linear`), and the template cfg offers `low`, `medium` and `high`. There is no filesystem access option in this front end's command line. See [04](04-ruffle-sdl.md). Saves land in `saves/localhost/<name>.sol`, the same storage as desktop Ruffle. Ruffle keys saves by SWF URL path, which differs between firmwares, and canonicalises symlinks, so make the shell save with a path independent `SharedObject.getLocal(name, "/")`.

### Why a relative tee

The firmware quit hotkey runs `pkill -f <name>` and then `pkill -9 -f <name>` after 3 seconds. The standard `exec > >(tee "$GAMEDIR/log.txt") 2>&1` produces a tee command line that contains the port folder path. If the kill name equals the folder name, tee is killed, the launcher dies on the broken pipe before `pm_finish`, the log is truncated and some firmwares show "A general error has occurred". With the kill name `ruffle_sdl` the standard form is fine, but the relative form costs nothing and protects you if you change the name. Explain the deviation in the PR in plain words. Note that with the kill name `ruffle_sdl` the pkill also matches `run-ruffle`'s command line, which stops the relaunch loop. That is wanted.

### The setup gate: stamp and markers

Two marker files in `gamedata/`:

* `.port_patched`: written by the patchscript, containing only `PATCH_VERSION`, and only on success.
* `.port_prepared`: written by the launcher after the patcher succeeded. It holds the patch version plus one `<file> <size> <mtime>` line per file the patchscript reads or writes.

The launcher computes the stamp in a subshell with `LC_ALL=C`, using `ls -lnL` for the size and `date -r` for the mtime (muOS has no `stat`). If `.port_prepared` differs from the stamp, it removes `.port_patched` and runs the patcher. After the patcher it checks that `.port_patched` equals `PATCH_VERSION`, and only then writes `.port_prepared`. A version only marker let a re-copied game run unpatched, hence the stamp. A re-copy of the game files, a port update with a new `tools/patch/version`, or a touched output file all cause one re-run.

Rules:

* Bump `tools/patch/version` every time any SWF patch changes. Versions that were pushed are immutable.
* The stamp logic lives in the launcher, where reviewers can read it. Do not source a helper that both patchscript and launcher use.
* Edit the file list in `stamp()` (marked `EDIT` in the template, the default list is only an example) to match your patchscript: sources, outputs, converted assets.
* A fresh copy wins over backups. For an in place patch the template patchscript compares the file with the manifest md5: a file that matches the manifest is a fresh copy of the game and replaces the kept `<file>.orig`, anything else is a leftover patched file and the kept `.orig` is used (see [03](03-delivery.md)).

### The patcher

If `$controlfolder/utils/patcher.txt` exists, export `PATCHER_FILE`, `PATCHER_GAME`, `PATCHER_TIME` and `controlfolder`, then source it. If it does not exist, show "This port requires the latest version of PortMaster.", sleep, `pm_finish`, `exit 1`. Do not keep a patcher fallback; merged ports do not. On failure show "Preparing the game failed, see ports/MYPORT/patchlog.txt.", sleep, `pm_finish`, `exit 1`. The game is never started with an unprepared marker.

The patchscript (`tools/patchscript`) follows a fixed protocol:

* `fail()` echoes `ERROR: ...`, `PATCH_FAIL_MSG:Setup failed: ...`, `Patching process failed!` and exits 1. The patcher screen shows the message.
* Progress lines look like `[3/12] Patching shell`. There is no real progress bar, numbered steps read like one.
* It logs through `exec > >(tee "$GAMEDIR/patchlog.txt") 2>&1`, because output is otherwise only on the screen.
* It is generic and data driven. Nothing game specific lives in the script, you edit the tables in `tools/patch/`:

| File | Content |
|-|-|
| `version` | one integer, the patch version. Bump it on every change of any patch or table |
| `manifest.txt` | `md5  path` lines (the `md5sum` format) for every original input, paths relative to `gamedata/`. Made with `tools/delivery/make_manifest.sh` |
| `files.txt` | `orig\|patch\|out` per SWF to patch. The patch is an xdelta in `tools/patch/` made against the inflated original. `out` equal to `orig` patches in place and keeps `orig.orig`, a different `out` writes a new file and leaves `orig` alone |
| `atf.txt` | optional, `kind\|scale\|input\|outdir`. `atf` decodes one ATF to a PNG, `swf` extracts the ATF textures embedded in a SWF |
| `atlas.txt` | optional, `factor\|file.xml`. Scales an atlas XML, always from `file.xml.orig` |
| `cleanup.txt` | optional, one glob per line (relative to `gamedata/`) of files the port never loads, deleted at the end. Absolute paths and `..` are refused. Keep it narrow |

* For every file it checks the md5 against the manifest (a missing file gives "Copy the whole game folder into ports/MYPORT/gamedata/", a mismatch names the unsupported release), inflates CWS and ZWS with `tools/atftool inflate`, applies `xdelta3 -d` to a temporary file and renames it into place.
* It counts the steps first, so the screen shows `[n/total]`.
* The last step writes the version into `gamedata/.port_patched` and prints "=== Done. Enjoy! ===". Success is only announced this way.

Ship deltas only, never patched SWFs. The README lists the md5 of each supported input and the patcher refuses other builds.

## cfg

`MYPORT.cfg` is sourced by the launcher. Typical variables:

| Variable | Values | Meaning |
|-|-|-|
| `QUALITY` | low (default), medium, high | `--quality`. Low is fastest (no anti aliasing). Medium and high use 2x and 4x multisampling in Ruffle |
| `ASPECT` | fit (default), fill, extend | passed as `-Paspect=` and needs the shell patch (see [08](08-screen-aspect.md)) |
| `FRAME_RATE` | 30 (default), 60 | passed as `-Pfps=`, needs the shell patch. 60 only for devices that hold it |
| `RENDER_SIZE` | empty (default) or WxH | `--render-size`, draw smaller and scale up |
| `RUFFLE_MIN_KEY_HOLD_MS` | 100 (default) | minimum key hold, see [09](09-input.md) |
| `RUFFLE_GC_STEP`, `RUFFLE_TRIM_SECS`, `RUFFLE_GC_LONG_TICK` | 0.01, 2, 1.0 | memory tuning, see [05](05-memory.md) |
| commented `RUFFLE_*` switches | off by default | advanced comparison switches (lazy shapes, draw in place and so on), remove the `#` to apply, see [env-vars.md](env-vars.md) |
| `VERBOSE_LOGS` | 0 or 1 (template default 1) | see below |

The cfg is plain shell (`NAME="value"` or `export NAME=value`) and documents each variable in comments. Per level values belong in `tools/run-ruffle.env`, not here. Add a variable only when something reads it. An env switch with no reader (a leftover `FPS_LOG_OFF`) was once left in a launcher and had to be removed.

## Relaunch wrapper (run-ruffle)

Ruffle never frees the library of an unloaded movie, so a big game made of several SWFs runs out of memory on 1 GB. The shell calls `fscommand("relaunch", "<args>")`. `ruffle_sdl` prints a stdout line `RUFFLE_RELAUNCH <args>` and exits (patches 0002 and 0006). `tools/run-ruffle <ruffle_sdl> <args...> <file.swf>` is a bash script that uses only shell builtins (no `stat`, `mktemp`, `sed` or `tail`, so it cannot fail on a firmware that lacks one):

* it runs the binary and copies every output line to its own stdout, so it reaches `log.txt`,
* when it sees a line that starts with the marker it restarts the binary with the words after the marker (split like a shell does: spaces separate, quotes group, a backslash escapes),
* a `-Pname=value` in those words replaces the same `-Pname` from the first command line, the other first command line arguments are kept, and an argument that ends in `.swf` replaces the SWF to run,
* otherwise it exits with the code of the last `ruffle_sdl` run (127 when the binary is missing or not executable).

Environment: `RELAUNCH_MARKER` (marker word, default `RUFFLE_RELAUNCH`), `RELAUNCH_MAX` (restart limit per run, default 500, then it stops with exit 1) and `RUN_RUFFLE_ENV` (the per level table, default `tools/run-ruffle.env` next to the script).

`tools/run-ruffle.env` is the table of per level environment. One rule per line, `glob|VAR=value VAR=value`, lines starting with `#` ignored. The glob is matched against all arguments joined by spaces with a space at both ends, for example `* -Plevel=big *|RUFFLE_FRAMESKIP=1`. The matching variables are exported for that run only (a lazy mouse pick for AS2 SWFs, or frame skip for one heavy SWF). The wrapper is non standard, so keep it and justify it: "one big SWF in memory at a time". A black screen of a few seconds on a world change is expected and worth a line in the README.

Do not read Ruffle's output through `sed` or `tail` in the wrapper under a compositor wrapper (a dead end: the preload banner was re-read as a target and it looped).

## gptk

The gptk is covered in [09 Input](09-input.md). Rules for the file in the port folder: only keys the game uses, `back` and `guide` unbound, one source of truth for README control tables, gptokeyb watches `ruffle_sdl`.

## Keeping non standard lines minimal and justified

Launcher length is the top rejection reason (merged ports range from about 47 to 108 lines). The reviewers' checkbox is "I can explain every non-standard line in my launch script". Keep a list in the PR body:

| Non standard part | Justification |
|-|-|
| run-ruffle | one big SWF in memory at a time |
| stamp and version check | re-run the patcher when the files or the patch change |
| `-P` flashvars from the cfg | shell reads aspect and frame rate |
| gptokeyb2 on muOS | gptokeyb is unresponsive on muOS |
| relative tee | gptokeyb hotkey pkill |

Things reviewers asked to remove: a patcher fallback, `kill -9` of gptokeyb after the patcher (the patcher manages its own), duplicated cfg defaults, an unused library path, `RUST_BACKTRACE`, fps log plumbing, a diagnostics helper sourced by launcher and patchscript. A launcher must not mention other ports by name. Remove Steam or DRM tooling. Never fetch binaries at runtime, never bundle `libstdc++` or `libGL`, and do not re-implement PortMaster features.

## Logs that help bug reports (VERBOSE_LOGS)

`VERBOSE_LOGS` is a cfg switch read by the launcher. The template default is `1`, for testing builds. Everything it adds is marked so it can be removed.

With `VERBOSE_LOGS=1`:

* The launcher keeps the previous log: `mv -f log.txt log.prev.txt` runs before the new log starts (a non standard line, marked as testing only).
* The first block, marked `BEGIN TESTING BLOCK` and `END TESTING BLOCK`, runs before the game: date, `uname -a`, `CFW_NAME`, `DEVICE_NAME`, `DEVICE_CPU`, `DEVICE_ARCH`, `DEVICE_RAM`, swap and zram flags, display size, the device's glibc version, the highest `GLIBC_` symbol the binary needs (compare it with `min_glibc` in `port.json`), `MemTotal`, `MemAvailable`, `SwapTotal`, `SwapFree`, `/proc/swaps`, zram disk size and algorithm, the cfg values, the patch version, the exact `run-ruffle` command with its arguments, and every `RUST_LOG`, `RUFFLE_*`, `PM_GPUSTAT`, `WGPU_*` and `SDL_*` variable in the environment.
* A second block with the same markers runs after the game: the exit code (137 and 143 are normal after the quit hotkey), free memory and swap, and the last kernel lines about out of memory kills or Mali errors.
* The cfg exports the diagnostics for the player (inside `if [ "$VERBOSE_LOGS" = 1 ]`): `RUST_LOG="warn,ruffle_sdl=debug,memlog=info,pmgpu=info,ruffle_core::player::port_fps=info"`, `RUFFLE_FPS_LOG=1`, `RUFFLE_SDL_TIMING=1`, `RUFFLE_MEMLOG=1` with `RUFFLE_MEMLOG_MS=500`, `RUFFLE_MEMLOG_TOP=8` and `RUFFLE_MEMLOG_PEAK="$GAMEDIR/memlog-peak.txt"`, `RUFFLE_AS3_PROF=1` and `PM_GPUSTAT=1`. See [env-vars.md](env-vars.md). Note that the AS3 profile lines are logged at info level under the target `ruffle_core::avm2::function::as3prof`, which this `RUST_LOG` does not list, so add it if you want to see them.

With `VERBOSE_LOGS=0` only what `ruffle_sdl` prints itself (warnings and errors) is logged, plus the setup log.

Before a PortMaster pull request, remove all of it: delete both `BEGIN TESTING BLOCK` to `END TESTING BLOCK` blocks and the `mv -f log.txt log.prev.txt` line from the launcher, set `VERBOSE_LOGS=0` and delete the diagnostics exports from the cfg. Reviewers reject long launchers. Ask testers in the testing thread to attach `log.txt` and `patchlog.txt`. Read the whole log, not the head.

## Metadata

| File | Rules |
|-|-|
| `port.json` | version 4 with all fields. `items` lists the launcher and the folder. `arch` `["aarch64"]` (ignored when a runtime is set). `runtime` is `[]` for ruffle_sdl. `min_glibc` as a string. `exp` true hides the port by default. `inst` and `inst_md` tell the user to copy the game files and that the first launch takes a few minutes. `availability` fits the licence (for example "paid" for a store game). `reqs` only when needed (`["2gb"]` only for 2 GB devices, also `power`, `!lowres`, `analog_1`). |
| `gameinfo.xml` | `path`, `name`, `desc` (same text as port.json), `releasedate` (like 20240218T000000), `developer`, `publisher`, `genre` (shooter and roguelike are not allowed), `image ./MYPORT/cover.png`. Paths must match the files. |
| `screenshot.png` | 640x480, 4:3, real gameplay. |
| `cover.png` | 640x480 landscape, like merged ports (not portrait). A logo needs an outline to read on the dark PortMaster background. The ES menu uses the gameinfo image, the PortMaster app shows the cover. |
| `README.md` | Installation, controls table (by SDL position), notes, reporting problems, thanks. Renamed to `MYPORT.md` in the zip. |
| `licenses/` | Flat files `LICENSE.<component>.txt`: Ruffle with all linked crates (generate with `ruffle/make_licenses.py`) and any tool you ship. Required. |

`desc` should describe the game (the store blurb), not the port. The metadata files sit next to the launcher in the zip. The port folder contains no `.sh`. Launchers are committed with mode 644 and made executable at runtime. Line endings are LF. No file over 90 MB (split it). Names are unique across PortMaster (check the list).

### min_glibc

Set `min_glibc` to the measured maximum `GLIBC_x.y` symbol of the shipped binaries (`objdump -T ruffle_sdl | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1`), not to the build container's version. A build in Ubuntu 20.04 (glibc 2.31) can still produce a binary that needs only 2.30, which also lets ArkOS (glibc 2.30) run it. `ruffle/build-aarch64.sh` prints the maximum and the NEEDED list. Expected NEEDED: `libasound.so.2`, `libSDL2-2.0.so.0`, `libdl`, `libgcc_s`, `libpthread`, `libm`, `libc`. No `libstdc++`, OpenSSL, freetype or GL. The official Ruffle nightly aarch64 needs GLIBC 2.39 and extra libraries, which is why you build your own.

## Release zip

The toolkit has no packaging script, so do it with a short script of your own (outside the repository history if it only encodes your paths): copy the launcher and the port folder, remove saves, logs, `patchlog.txt` and every file in `gamedata/` except the placeholder text file, copy the metadata, rename `README.md` to `MYPORT.md`, delete `SUBMISSION.md`, and run `zip -9 -r -q -X`. Always list the zip contents before release. An untracked old 33 MB binary nearly got zipped once. Updates do not delete old files on devices, so compare the release zip against an install by md5 and tell users about obsolete files. Leave `port.json` alone on the device (PortMaster adds fields at install).

## Submission flow

1. Layout, trimmed launcher, licences, metadata, README, screenshot and cover, all emulator or other port references purged.
2. Device smoke test, including deleting the gamedata marker to force the patcher.
3. Open a thread in the PortMaster testing channel with a post that matches the build: runtime (none), controls, swap notes, frame rate expectations, and how to attach `patchlog.txt` and `log.txt`. Discord posts are limited to 2000 characters, tables do not render, link to the repository.
4. Test across firmwares and resolutions. The review template lists AmberELEC, ArkOS, dArkOS, ROCKNIX (Libmali and Panfrost), muOS, Knulli (Crossmix and others optional) and resolutions 480x320 (optional), 640x480, 720x720 (optional) and higher. Ports tested only on some firmwares are rejected. Moderators may ask for a 1280x720 device.
5. Reviewers compare the PR with the thread, so rewrite the thread's first post to match any change.
6. Run `python3 tools/build_release.py --do-check` in a sparse PortMaster-New clone.
7. Open the PR once the owner says go. The PR template's answers:
   * the AI statement checkbox: "I wrote and understand this script/patch myself, or clearly marked which parts came from an AI assistant". Say plainly which parts were AI assisted and the testing state.
   * "I can explain every non-standard line in my launch script": list the table above.
   * tick the firmwares and resolutions actually tested.
   * list what ships: binaries, xdelta patches, version, manifest, patchscript, run-ruffle, licences; link the source repository for patches and builds.
   * no "Test plan" section, and no mention of the tool that helped you write it.
8. Fork pull request CI shows `action_required` until a maintainer approves it.

Legal model: bring your own files. Ship code and deltas only, never game data, never a GPU blob.

## Pitfalls

* Missing PORTMASTER line 2 rewrites the running script.
* Absolute `tee` path equal to the kill name kills the logger.
* A version only marker lets a re-copied game run unpatched.
* Not calling `pm_finish` on an error exit.
* A launcher that mentions other ports, uses `kill -9` on gptokeyb, or sets variables nothing reads.
* `min_glibc` set from the container version instead of the measured symbol.
* Stale files in the zip or on the device, and an old port.json overwritten.
* The README and gptk drifting apart.
* Patcher screens waiting for a button during automated tests (see [10](10-testing.md)).

## See also

* [03 Delivery](03-delivery.md)
* [08 Screen and aspect](08-screen-aspect.md)
* [09 Input](09-input.md)
* [10 Testing](10-testing.md)
* [env-vars.md](env-vars.md)
* `templates/port/README.md` and `templates/port/SUBMISSION.md`

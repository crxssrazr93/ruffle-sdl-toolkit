# Submitting the port to PortMaster

Notes for the person preparing the pull request to PortMaster-New. Delete this file from the port before packaging (it is not part of the zip).

You must test the port on a real device yourself, on more than one firmware if you can. No PC test, emulator run or automated harness replaces that, and PortMaster reviewers reject ports that were only tested on some firmwares without saying so. Every checkbox below is your own statement to the reviewers, so tick only what you have really done.

## 1. Layout of the pull request

```
ports/MYPORT/
  MYGAME.sh            the launcher (this template's launcher.sh, committed as mode 644)
  port.json
  gameinfo.xml
  README.md            becomes MYPORT.md in the zip
  screenshot.png       640x480, 4:3, real gameplay
  cover.png            640x480, landscape
  MYPORT/
    ruffle_sdl         the stripped aarch64 front end (see below)
    tools/atftool      the aarch64 build of the toolkit's atftool, only if the setup needs it
    tools/patchscript, tools/run-ruffle, tools/patch/ (version, manifest, tables, xdeltas)
    MYPORT.cfg, MYPORT.gptk
    gamedata/          only the placeholder text file, never game files
    licenses/          LICENSE.ruffle.txt, LICENSE.atftool.txt (flat files, one per component)
```

* No `.sh` file inside the port folder (that is why the wrapper is called `run-ruffle`, not `run-ruffle.sh`).
* LF line endings. The `.sh` is committed without the executable bit, and the launcher makes things executable at run time with `$ESUDO chmod +x`.
* No single file over 90 MB. Never bundle libstdc++, libGL or any system library. ruffle_sdl uses the firmware's own SDL2 and GLES.
* Never fetch binaries at run time. Ship them in the zip.
* The port name must be unique across PortMaster (check the existing ports list).
* `gameinfo.xml` paths must match the real file names, with a releasedate such as 20240101T000000.
* Run `python3 tools/build_release.py --do-check` from a PortMaster-New checkout. It must pass.

## 2. Launcher rules the reviewers apply

* Keep it as short as possible. A long launcher is the most common reason for rejection (merged ports run from about 47 to 108 lines).
* Line 2 must be `# PORTMASTER: MYPORT.zip, MYGAME.sh`. Without it harbourmaster rewrites the running script and manage ports does not list it.
* Use PortMaster's own helpers: control folder detection, `control.txt`, `mod_${CFW_NAME}.txt`, `get_controls`, `pm_platform_helper`, `pm_finish`, the patcher screen (`utils/patcher.txt`) for the first run setup. Do not reimplement what PortMaster provides.
* Call `pm_finish` before every error exit, so gptokeyb and the rest are cleaned up.
* No patcher fallback: if `patcher.txt` is missing, tell the user to update PortMaster and exit.
* Settings come only from the cfg file. Do not duplicate the defaults in the launcher.
* Use a relative `tee log.txt` after `cd "$GAMEDIR"`. gptokeyb's quit hotkey runs `pkill -f ruffle_sdl`, and a tee path that contains that name would die and take the launcher down.
* Every non standard line needs a one line justification (this template comments them). Typical justified ones: the relaunch wrapper, the setup stamp, gptokeyb2 on muOS.
* Remove the TESTING BLOCK markers and everything between them (the verbose environment report), set `VERBOSE_LOGS=0` and remove the exports that follow it in the cfg, or at least ship the release with `VERBOSE_LOGS=0`. Remove any unused variable, library path, `RUST_BACKTRACE` or `RUST_LOG` line.
* A launcher or file must not mention other ports.
* No custom helpers: no shared shell libraries, no logging framework, no scripts that duplicate PortMaster features.

## 3. port.json and metadata

* `version` 4 with every field present. `min_glibc` is `"2.30"` and must equal the highest GLIBC symbol the shipped binaries need (check with `objdump -T ruffle_sdl | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1`).
* `runtime` is empty (ruffle_sdl needs no runtime). `arch` is `["aarch64"]`. `rtr` false, `exp` false.
* `desc` describes the game, as the store page does, not the port.
* Genres must come from PortMaster's list. Shooter and roguelike are not allowed as genres.
* `reqs` only when needed: `["2gb"]` only for ports that need 2 GB. Others seen: `power`, `analog_1`, `analog_2`.
* `availability`: `paid` or `demo`, with the store link. Never ship game files or anything that works around a store's protection. Bring your own files, ship code and deltas only.
* The port README must have Installation, Controls, Notes and Reporting problems sections, with the zram advice and the performance expectations.

## 4. Binaries and licences

* Build ruffle_sdl with the toolkit's `ruffle/build-aarch64.sh` (glibc 2.30 floor) and check the report it prints: highest GLIBC, and NEEDED must list only libasound, libSDL2, libdl, libgcc_s, libpthread, libm, libc.
* The official Ruffle nightly cannot be used on handhelds (it needs a newer glibc, freetype and OpenSSL).
* Ship `licenses/LICENSE.ruffle.txt` covering Ruffle and the crates linked into the binary, and one more file per extra component you ship (atftool, with the notices of its crates).
* Say in the PR where the patched source and the build scripts live (a public repository) so reviewers can audit the binary.

## 5. Pull request template answers

PortMaster's template asks for these. Answer truthfully.

* "I wrote and understand this script/patch myself, or clearly marked which parts came from an AI assistant": tick it, and if an assistant helped, say which parts in the description. Mention AI use plainly. Do not name tools in PR text beyond what you must.
* "I can explain every non standard line in my launch script": tick it only if true, and list the non standard parts in the description to answer questions early: the relaunch wrapper (frees memory between SWFs), the setup stamp (runs again the setup when files or the patch version change), the cfg flashvars, gptokeyb2 on muOS (gptokeyb is unresponsive there).
* Firmware tested: ArkOS, AmberELEC, ROCKNIX (Libmali and Panfrost), muOS, Knulli, Crossmix (optional), Other. Tick only the ones you actually ran, and state how long you played.
* Resolutions tested: 480x320 (optional), 640x480, 720x720 (optional), higher.
* Do not add a Test plan section. Do not mention the tools you used to write the code or the PR.
* Describe the current testing state honestly, for example "tested on one device with firmware X".

## 6. What reviewers asked before (so you can pre empt it)

* Why is the launcher not shorter? Answer with the justifications above.
* Remove unused libraries, variables and extra kill commands.
* Why `gptokeyb2` on muOS? Because gptokeyb is unresponsive there.
* Is the binary built against the firmware's SDL2? It must be.
* Does the port work on every firmware, or only some? State it. Ports tested on only some firmwares were rejected.
* Is there a first run patcher screen with progress and a clear failure message? Use `PATCH_FAIL_MSG:` and `[n/total]` lines as `patchscript` does.
* Feedback often arrives on Discord rather than as written GitHub comments. Watch both.

## 7. Testing thread workflow

1. Prepare the full package first: launcher, port.json, gameinfo.xml, README, screenshot, cover, licences. Do the device smoke test (delete `gamedata/.port_prepared` and `gamedata/.port_patched` to force the setup).
2. Install the way a release installs (from the zip through PortMaster, or by copying the zip content exactly), not by copying single files: a hand copied launcher without the PORTMASTER line does not appear in the ports list.
3. Open a thread in the PortMaster Discord testing channel. The first post must match the build and the PR: runtime (none), controls, swap or zram advice, the fps expectations, and attach `patchlog.txt` and `log.txt` from a real run. Posts are limited to 2000 characters and tables do not render, so link the source repository instead of pasting long text.
4. Ask for testers on several firmwares and screen sizes. Collect their logs, fix, bump `tools/patch/version` for any patch change (pushed versions are immutable), and update the thread's first post.
5. Only after that open the pull request. Fork pull requests show a pending CI check until a maintainer approves it.
6. Before updating an installed port, compare the release zip with the device by checksum and remove files the new version no longer ships (updates do not delete old files).

## 8. Screenshot and cover

* `screenshot.png`: 640x480, 4:3, real gameplay. PortMaster requires it.
* `cover.png`: 640x480 landscape (merged ports use landscape, not portrait). A dark logo needs a light outline to read on PortMaster's dark background.
* The ports list in the firmware uses the `<image>` of gameinfo.xml, the PortMaster app uses the cover.

## 9. Packaging checklist (final)

* [ ] Tested on a real device, on the firmwares and resolutions you will tick
* [ ] `VERBOSE_LOGS=0`, testing block removed from the launcher
* [ ] Launcher short, every non standard line justified, `pm_finish` before each exit
* [ ] `.port_prepared` and `.port_patched` logic checked: first start sets up, second skips, touching a game file sets up again, a wrong file stops with a readable message
* [ ] `min_glibc` equals the measured value, NEEDED list clean
* [ ] licenses folder complete
* [ ] No game files, saves, logs or config in the zip (`unzip -l` it)
* [ ] `build_release.py --do-check` passes
* [ ] PR text states testing honestly, no test plan section

# ruffle-sdl-toolkit

A toolkit and a set of notes for running Flash and AIR games on handheld Linux devices (PortMaster targets such as Knulli, muOS, ROCKNIX, AmberELEC and ArkOS) with a patched Ruffle. It contains:

* a pinned series of Ruffle patches, including `ruffle_sdl`, a small SDL2 and GLES 3 front end that runs on the firmware's own libraries,
* scripts to fetch, patch and cross build Ruffle for aarch64 with a low glibc floor,
* tools to patch AIR shells and AS2 or AS3 SWFs from decompiled source, to convert ATF textures, and to ship only binary deltas,
* a PortMaster launcher template with the relaunch wrapper, patcher, cfg and gptk files,
* PC test harnesses (Xvfb, gamescope headless, a capture hook, qemu) that never open a window on your desktop,
* docs that record what worked, what did not, and why.

A finished Flash/AIR port that uses this approach: https://github.com/crxssrazr93/fancypants-portmaster

## When Ruffle fits (and when not)

Ruffle fits when:

* the game is mostly AS2 (Flash 8 era), which runs very well, or AS3 that stays within what Ruffle implements,
* you can strip native extensions and AIR only features from the shell (Ruffle will not run native extensions),
* memory is manageable once the memory patches are applied and the game is split into several SWFs that the relaunch wrapper can load one at a time,
* the game is stage based enough for a 480x320 to 1920x1080 screen with a gamepad mapped to keys.

It does not fit when:

* the game depends on native extensions, a captive AIR runtime features Ruffle cannot stub, or heavy Stage3D features with unsupported texture formats that you cannot convert offline,
* one huge movie must stay in memory at once on a 1 GB device,
* the game needs real multitouch or sensors,
* a native rewrite or an engine reimplementation is clearly easier.

Start with [01 Feasibility](docs/01-feasibility.md): run every SWF headless on the PC, count the Ruffle stub log lines, and classify each SWF by script type before committing.

## Quick start

Every command below is run from the repository root.

1. Read [01 Feasibility](docs/01-feasibility.md) and triage your game on the PC (`python3 tools/swf/swf_info.py MYGAME/*.swf`).
2. Get the patched Ruffle and build it. `ruffle/fetch.sh ./src` clones the pinned commit and applies the series 0001 to 0013 (add `WITH_OPTIONAL="0100"` for an optional patch such as the software cursor, if present). Then `ruffle/build-aarch64.sh ./src ./out` (needs Docker) for the device and `ruffle/build-x86_64.sh ./src ./out-x86` for the PC (needs the SDL2 and ALSA development packages).
3. Decompile the shell and SWFs with `tools/swf/ffdec.sh as3 MYGAME.swf work/dec Main` (set `FFDEC` to your ffdec first), then write your patches with the `anchor.py` library, starting from `tools/swf/example_patch.py` (see [02 Shell patching](docs/02-shell-patching.md)).
4. Handle screen size: aspect modes and the audit of fixed height constants ([08](docs/08-screen-aspect.md)).
5. Map the pad with a gptk, and add what the game lacks (volume keys, a cursor) ([09](docs/09-input.md)).
6. Test on the PC without opening a window on your desktop. Build a hooked copy of the tree for captures (`python3 tests/sdl_test_hooks.py <scratch copy of ./src>`, then `ruffle/build-x86_64.sh` on that copy, and never ship that binary). Then run `RES=640x480 SHOT_AT=3s tests/pc_sdl_run.sh <hooked ruffle_sdl> MYGAME-port.swf out/run1 20` and repeat for 720x720, 960x544, 1024x768, 1280x720 and 1920x1080 ([10](docs/10-testing.md)). The default `--headless` mode is the one for automated runs. To watch a run yourself add `--visible` (a nested Xephyr window, or a localhost only VNC server on a private Xvfb with `--visible=vnc`), and `--hold SECS` keeps it up after the run. `tests/gamescope_headless.sh` takes the same arguments and runs on the real GPU.
7. Convert textures if the game uses ATF (build `tools/atf` with `cargo build --release` in that folder, or `tools/atf/build-aarch64.sh <out>` for the device, see [07](docs/07-textures-atf.md)). Make deltas with `tools/delivery/make_patch.sh orig.swf new.swf out.xdelta` and the md5 list with `tools/delivery/make_manifest.sh <game dir> '*.swf' > manifest.txt` ([03](docs/03-delivery.md)).
8. Copy `templates/port/` to your port, replace MYPORT and MYGAME, fill in the stamp file list in the launcher, the tables in `MYPORT/tools/patch/` (`manifest.txt`, `files.txt`, `atf.txt`, `atlas.txt`, `cleanup.txt`, `version`) and the metadata ([11](docs/11-launcher-packaging.md)).
9. Test on a device through the firmware's own launcher path, with `VERBOSE_LOGS=1`, then profile ([06](docs/06-performance.md), [05](docs/05-memory.md)).
10. Set `VERBOSE_LOGS=0`, delete the two `BEGIN TESTING BLOCK` blocks from the launcher, run the packaging checks, and follow `templates/port/SUBMISSION.md`.

## Map

| Path | What is there |
|-|-|
| `docs/01-feasibility.md` | Can this game run, what to check first |
| `docs/02-shell-patching.md` | Patching AS3 shells and AS2 SWFs |
| `docs/03-delivery.md` | Deltas, manifests, on device patching |
| `docs/04-ruffle-sdl.md` | The SDL front end |
| `docs/05-memory.md` | Memory limits and the memory patches |
| `docs/06-performance.md` | Profiling and speed work |
| `docs/07-textures-atf.md` | ATF textures |
| `docs/08-screen-aspect.md` | Aspect modes, resolutions, fixed height pitfalls |
| `docs/09-input.md` | Pad mapping, key taps, cursors, SDL 2.0.10 |
| `docs/10-testing.md` | PC, headless, qemu and device testing |
| `docs/11-launcher-packaging.md` | Launcher, markers, metadata, review |
| `docs/12-dead-ends.md` | What was tried and failed |
| `docs/env-vars.md` | Every runtime switch |
| `ruffle/` | Pin, patch series, optional patches, fetch and build scripts |
| `tools/swf/` | SWF inflate, info, anchored patching library, ffdec wrapper, snippets |
| `tools/atf/` | ATF decoder and conversion tool (Rust) |
| `tools/delivery/` | Delta and manifest scripts |
| `templates/port/` | Launcher, port folder, metadata, README and submission templates |
| `tests/` | PC and device harnesses, capture hook, fixtures |
| `examples/` | Pointer to a finished port |
| `INVENTORY.md` | The evidence base the docs were written from |

## Verification status

This section is maintained by hand. Update it when you verify something.

| Area | Status | Notes |
|-|-|-|
| Patch series 0001 to 0013 applies to the pinned commit | verified | `ruffle/fetch.sh` applies it cleanly on the pinned commit |
| x86_64 `ruffle_sdl` build from the series | verified | release build, about 3.5 minutes |
| aarch64 build (Docker) and glibc floor | verified | `ruffle/build-aarch64.sh` built `ruffle_sdl` from the 0001 to 0013 series: 16.7 MB, max GLIBC_2.30, needs libSDL2, libasound, libdl, libgcc_s, libpthread, libm, libc. The script fails above `MAX_GLIBC` (default 2.30). `atftool` also built for aarch64 (652 KB, glibc 2.30) |
| aarch64 binary under qemu | verified for start and exit | The toolkit built `ruffle_sdl` ran the relaunch fixture under qemu user mode: started, ran the AVM1 movie, printed `RUFFLE_RELAUNCH next`, exit 0. Emulation only, no GPU, no real handheld |
| `tools/swf` tests | verified | 5 tests pass |
| `tools/delivery` test | verified | passes using xdelta3 in a Docker alpine container |
| `atftool` tests | verified | 14 cargo tests pass |
| Templates: `run-ruffle` and `patchscript` | verified with fakes | tested against fake binaries and tools. shellcheck is clean except pattern warnings in the launcher |
| PC harness: Xvfb capture and key injection | verified | hooked x86_64 build on the generated fixtures: PNG capture at 640x480 checked visually, `Key.isDown` saw the injected keys |
| gamescope headless run | verified | |
| `--visible=vnc` viewing mode | verified | server starts, listens on localhost only, cleaned up |
| `--visible=xephyr` and gamescope `--visible` | not verified | Xephyr is not installed here, and checking gamescope visible opens a window |
| `device.sh` and `keyd.py` | not verified | never run (they need a device and uinput) |
| Software cursor (all five approaches) | planned | see docs/09-input.md |
| Right stick mouse end to end on a device | needs a device | |
| 1920x1080 frame rate | needs a device | never measured |
| Launcher template on a device | needs a device | nothing in this toolkit has been tested on a real handheld |
| ROCKNIX Panfrost run of ruffle_sdl | needs a device | only tester reports exist |

Verified in the example port (not re-run here): the patch series on several handhelds, the front end memory savings, the minimum key hold fix for Start taps.

## Credits

Short version: the `ruffle_sdl` front end and the memory patches are by Knifethrower, the remaining patches, tools, templates and docs are by crxssrazr93, and everything stands on Ruffle (MIT OR Apache-2.0), JPEXS FFDec and the PortMaster ecosystem. See [CREDITS.md](CREDITS.md).

## Licence

MIT for this toolkit ([LICENSE](LICENSE)). Ruffle patches stay under Ruffle's licence ([LICENSE-RUFFLE.md](LICENSE-RUFFLE.md)). Bring your own game files. This repository contains no game data.

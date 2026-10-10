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

1. Read [01 Feasibility](docs/01-feasibility.md) and triage your game on the PC.
2. Build the patched Ruffle: `ruffle/fetch.sh ./src`, then `ruffle/build-aarch64.sh ./src ./out` (Docker) for the device and `ruffle/build-x86_64.sh ./src ./out-x86` for the PC. Add `WITH_OPTIONAL="0100"` for the software cursor patch.
3. Decompile the shell and SWFs with `tools/swf/ffdec.sh`, then write your patches with `tools/swf/anchor.py` (see [02 Shell patching](docs/02-shell-patching.md)).
4. Handle screen size: aspect modes and the audit of fixed height constants ([08](docs/08-screen-aspect.md)).
5. Map the pad with a gptk, and add what the game lacks (volume keys, a cursor) ([09](docs/09-input.md)).
6. Test on the PC with `tests/pc_sdl_run.sh` at 640x480, 720x720, 960x544, 1024x768, 1280x720 and 1920x1080 ([10](docs/10-testing.md)).
7. Convert textures if the game uses ATF (`tools/atf`, [07](docs/07-textures-atf.md)), and make deltas with `tools/delivery/make_patch.sh` ([03](docs/03-delivery.md)).
8. Copy `templates/port/` to your port, replace MYPORT and MYGAME, fill in the stamp file list, patchscript manifest and metadata ([11](docs/11-launcher-packaging.md)).
9. Test on a device through the firmware's own launcher path, with `VERBOSE_LOGS=1`, then profile ([06](docs/06-performance.md), [05](docs/05-memory.md)).
10. Set `VERBOSE_LOGS=0`, remove the testing blocks, run the packaging checks, and follow `templates/port/SUBMISSION.md`.

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
| Patch series applies to the pinned commit | to be verified | |
| aarch64 build (Docker) and glibc floor | to be verified | |
| x86_64 build for the PC harness | to be verified | |
| PC harness with the capture hook | to be verified | |
| gamescope headless run | to be verified | no committed script existed before this toolkit |
| aarch64 binary under qemu | to be verified | recipe proven on another SDL app only |
| Software cursor (all five approaches) | planned | see docs/09-input.md |
| Right stick mouse end to end on a device | needs a device | |
| 1920x1080 frame rate | needs a device | never measured |
| Launcher template on a device | needs a device | |
| ROCKNIX Panfrost run of ruffle_sdl | needs a device | only tester reports exist |

Verified in the example port (not re-run here): the patch series on several handhelds, the front end memory savings, the minimum key hold fix for Start taps.

## Credits

Short version: the `ruffle_sdl` front end and the memory patches are by Knifethrower, the remaining patches, tools, templates and docs are by crxssrazr93, and everything stands on Ruffle (MIT OR Apache-2.0), JPEXS FFDec and the PortMaster ecosystem. See [CREDITS.md](CREDITS.md).

## Licence

MIT for this toolkit ([LICENSE](LICENSE)). Ruffle patches stay under Ruffle's licence ([LICENSE-RUFFLE.md](LICENSE-RUFFLE.md)). Bring your own game files. This repository contains no game data.

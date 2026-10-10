# Example

A finished Flash/AIR port that uses this approach:

https://github.com/crxssrazr93/fancypants-portmaster

Use it to see the pieces working together in a real PortMaster submission. Nothing from it is copied into this toolkit. Game specific names, anchors, md5 tables and assets must be replaced with your own.

## What to look at in it

| Path | What it shows |
|-|-|
| `ports/*/` launcher `.sh` | A launcher with PORTMASTER line 2, controlfolder detection, relative tee, stamp and patcher gate, gptokeyb2 on muOS |
| `ports/*/*/tools/patchscript` | The on device patcher: md5 checks, inflate and xdelta, `.orig` handling, markers, failure protocol |
| `ports/*/*/tools/run-ruffle` | The relaunch wrapper |
| `ports/*/*/*.cfg`, `*.gptk` | User settings and the keyboard mapping |
| `ports/*/port.json`, `gameinfo.xml` | Metadata for a runtime free aarch64 port |
| `build/ruffle-patches/` | The original Ruffle patch series (0001 to 0013) |
| `build/fetch_ruffle.sh`, `build_ruffle.sh`, `build_ruffle_native.sh` | Pinned clone and cross builds |
| `build/make_licenses.py`, `build/package.sh`, `build/make_patches.sh` | Licence text, release zip, delta generation |
| `patch/patch_shell.py`, `patch_world_as2.py`, `build_*.sh` | Anchored shell and P-code patch scripts (game specific anchors) |
| `tools/*/` | The ATF to PNG preparation tool (a Rust crate) |
| `tests/` | Early forms of the device, keyboard, Xvfb and capture hook helpers |
| `docs/PORTING.md`, `TESTING.md`, `PERFORMANCE.md` | The notes this toolkit's docs grew from |
| the repository's pull requests | Review of the Ruffle patches and the memory work |

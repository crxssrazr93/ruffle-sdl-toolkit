# Credits

## Credit rules

* Keep the author line of every patch as it was written. Do not rewrite history to change who authored a change.
* The toolkit licence (MIT, `LICENSE`) covers the scripts, tools, templates and docs. Ruffle patches stay under Ruffle's licence (see `LICENSE-RUFFLE.md`).
* When you ship a port built with this toolkit, credit the people below in the port README, in a "Thanks" section, and ship the licence texts.
* When you add a patch to `ruffle/patches/` or `ruffle/optional/`, add one line to `ruffle/README.md` with the true author and mention it here.

## People and projects

### Knifethrower

Author of the `ruffle_sdl` front end (patch 0006: Ruffle on SDL2 and GLES 3 for handhelds) and of the memory and GPU patches:

* 0005 core: `Player::add_gc_work` and `Player::collect_garbage_now`
* 0007 core: tessellate shapes on first render, parse shape records on demand
* 0008 wgpu: draw `BitmapData.draw` in place, cap the offscreen pool
* 0009 core: blank `BitmapData` without resident pixels or zero uploads
* 0010 memory accounting by category (`RUFFLE_MEMLOG`)
* 0011 Stage3D uploads without a submit, consecutive draws in one render pass
* 0012 `ruffle_sdl` on SDL 2.0.10
* 0014 core: free the libraries of movies loaded by AVM1 once nothing uses them (author line Knifethrower)
* optional patch 0101: the software cursor follows the movie (`Mouse.hide()`, hand over buttons), with the `test_hide.swf` and `test_button.swf` fixtures and their `cursor_test.sh` cases

These were contributed through pull request #1 on the example repository (see `examples/README.md`). In the original history the author line reads "port <port@localhost>", which is a placeholder identity and not the author. The credit belongs to Knifethrower.

### crxssrazr93

* Ruffle patches 0001 to 0004 (readGraphicsData, Stage3D batching and caches, GPU side texture uploads and the AS3 profiler, lazy mouse picking and frame skipping) and 0013 (minimum key hold). Patches 0002 and 0006 were lightly edited after export by crxssrazr93 (generic relaunch marker name and neutral prose, author lines untouched)
* the optional software cursor patch 0100 (front end overlay and SDL colour cursor) and the shell side cursor snippets
* the shell and SWF patching tools, the ATF decoder tool, the delivery scripts, the relaunch wrapper, the launcher, patchscript and cfg templates
* the test harnesses, the capture hook script and the device helpers
* the documentation

### Ruffle project

Ruffle is licensed under MIT OR Apache-2.0 and is the foundation of everything here. Thanks to all Ruffle contributors. https://github.com/ruffle-rs/ruffle

### JPEXS Free Flash Decompiler (FFDec)

Used through `tools/swf/ffdec.sh` to export, decompile, recompile and replace scripts in SWF files. Not shipped in this repository. https://github.com/jindrapetrik/jpexs-decompiler

### Adobe dds2atf

The ATF container format is documented by Adobe's `dds2atf` tool and format notes. They were used as a reference for the decoder in `tools/atf/`. No Adobe code is included.

### Other pieces

* PortMaster (https://portmaster.games) and its launcher conventions, `gptokeyb` and `gptokeyb2`, `pm_platform_helper`.
* Rust crates linked into `ruffle_sdl`, including `sdl2`, `wgpu`, `jpegxr` (with Microsoft's jxrlib BSD notice) and many more. Their licences are collected by `ruffle/make_licenses.py` and `tools/atf` licence notes.
* SDL, ALSA, Mesa and the handheld firmware projects (Knulli, muOS, ROCKNIX, AmberELEC, dArkOS, ArkOS) whose behaviour the docs describe.
* xdelta3 for the binary deltas.
* Testers on the PortMaster Discord who ran builds on many devices.
* Other Ruffle on handheld efforts (ruffle4consoles based forks) that mapped the ground first.

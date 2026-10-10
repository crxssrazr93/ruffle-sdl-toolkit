# 06. Performance and profiling

## When you need this

Read this when a ported game runs below its target frame rate, when speed wobbles between 30 and 60 fps, when a game plays in slow motion, or when you need to find out whether the CPU, the GPU driver or the game's own scripts are the bottleneck. The reference device is a single Cortex A53 cluster (up to 1.5 GHz) with a Mali G31 blob driver. The same ideas apply to other small GLES handhelds.

## Where the time goes

A Stage3D hub (an AS3 game with Starling) on the reference device cost about 60 ms per frame:

| Part | Cost |
|-|-|
| AS3 (game plus Starling) | about 25 ms |
| wgpu command encoding, about 36 Stage3D draws, one pass each, at `finish()` | about 13 ms |
| Mali GL driver replay at `queue.submit` | about 13 ms |
| `hitTestPoint`, about 870 calls | 3 to 6 ms |

The Mali blob costs 17 to 28 microseconds of CPU per draw call (measured on another port on libmali r20p0), a ceiling of roughly 600 to 900 draws per frame. That is why everything below is about doing fewer submits, fewer passes and fewer draws, and about not doing work the game does not need.

## Rendering side patches

**Stage3D batching (patch 0002).** One `CommandEncoder` per frame records all copies and passes and submits at `present()`. Per draw submits are very expensive on mobile GLES drivers. Pipelines and bind groups are cached (a GLES pipeline is GLSL generation plus a program link), and the compiled AGAL shader LRU grows from 2 to 32 entries. Result: 2.9 fps to 15 fps on the hub.

**Deferred uploads and merged passes (patch 0011).** `RUFFLE_S3D_DEFER_UPLOAD` removes two queue submits per texture upload (each one is a full GL replay plus `glFlush`). The command buffers are queued and drained first by the next submit. `RUFFLE_S3D_MERGE_PASSES` joins consecutive `drawTriangles` calls into the pending render pass on the same target, copying the constants per draw into a 1 MB uniform ring with dynamic offsets. On a PC, the hub went from about 30 passes per frame to about 4. On the device (same hub) passes per 2 s fell from 720 to 105 and fps from 12.0 to 13.2 in an on, off, on test.

**GPU side texture copies (patch 0003).** `Texture.uploadFromBitmapData` copies a GPU drawn `BitmapData` straight into the Stage3D texture, so there is no readback per upload. It first has to submit pending offscreen work (`flush_pending_gpu_work`). If that flush is missing the copy reads an empty texture and the symptom is an invisible character.

**BitmapData.draw instead of copyPixels.** Starling's `ConcretePotTexture` pads non power of two bitmaps with `copyPixels`, and in Ruffle `copyPixels` on a GPU drawn bitmap reads it back to the CPU every frame. Patching the game so it uses `buffer.draw(data)` keeps it on the GPU. This is a game side (shell or SWF) change, see `02-shell-patching.md`.

## Script side patches

**Lazy mouse picking (patch 0004, `RUFFLE_LAZY_MOUSE_PICK`).** Ruffle looks for the clip under the mouse every frame, walking every clip and looking up button handlers. In a large AVM1 level that was about 35 percent of the main thread (about a third of frame time on a Cortex A53). With the switch on, the hovered object is reused unless the mouse moved or a button changed. Good for large AVM1 levels and games played with a gamepad. Not for games that depend on objects moving under a still pointer.

**Frame skipping (patch 0004, `RUFFLE_FRAMESKIP`).** Ruffle stops catching up once logic takes more than a third of a frame. With the switch on, `max_frames_per_tick` is at least 2 so frame based games keep their speed. The picture updates only 12 to 19 times per second when the game is busy and looks choppier. Use it only for fixed step games, never for games timed by a clock. On a fixed step level game, fps went from standing 15, jumping 12 to 13, running 8 to 13 to standing 28 to 29, jumping 22 to 23, running 23 to 30 (together with lazy picking).

Per sub game switches are normally set in the wrapper (`run-ruffle`), because only some worlds need them. The lesson: keep a per target table of environment settings, do not set them globally.

## Frame pacing and game clocks

**Classify the timing model first.** A clock timed game (step equals elapsed time divided by about 33 ms) plays at the right speed even at 15 fps, so a low frame rate is acceptable. A frame counted game (30 Hz logic written for a fixed frame) runs slower when frames are missed. Between 30 and 60 fps, speed can jump between about 0.65 times and 1.3 times, and a half tick design runs in slow motion below 60 fps.

**Half tick rules.** One world advanced a 30 Hz logic clock by half a tick per frame, assuming 60 fps, so below 60 fps it ran slow. The fix was to keep a timer based on `getTimer()`: after `timeDelta = 0.5`, if the time since the last tick (from `getTimer()`) is not below 25 ms then `timeDelta = 1`. Generic lesson: frame locked logic slows on handhelds, so replace per frame assumptions with elapsed time based steps.

**Lock to 30 fps.** When the logic clock is 30 Hz, set `stage.frameRate = 30` (unless a flashvar such as `worldfps=60` asks otherwise). Handhelds that land between 30 and 60 then run at a steady speed instead of wobbling. Check the game's tick rate before unlocking.

**Smaller drawing.** `--render-size WxH` and `--quality low` (the default) reduce fill rate. See `04-ruffle-sdl.md`.

## Governor and power mode

Clock speed matters on these SoCs. On Knulli, the High performance mode (performance governor) took the hub from 15.3 to 16.6 fps, and an unlocked 1.704 GHz instead of the 1.512 GHz cap gave 18.2 fps. muOS with its default governor ran the same hub at 13 to 14 fps. The port does not change clocks. Per game on Knulli, `ports["<launcher>.sh"].powermode=highperformance` in `/userdata/system/batocera.conf` (or the ES options) sets it. Another port pins the governor and GPU devfreq minimum and restores them in an `EXIT` trap. That is non standard and needs justification, so the toolkit leaves clocks to the firmware.

## Profiling

Always repeat benchmarks. Identical runs scored 40.5 and 43.4 fps, so a +2.5 fps win was noise. Use on, off, on ordering, repeat at least twice, and wait for loading to finish (presented frames above 20 per second) before measuring.

### RUFFLE_FPS_LOG (frames and logic time)

Set `RUFFLE_FPS_LOG=1` and make the filter include its target: `RUST_LOG=warn,ruffle_core::player::port_fps=info`. Every 2 s you get:

```
port_fps: 30.0 frames/s (10.6 ms logic), 30.5 renders/s (4.5 ms render)
```

* `frames/s` is game ticks run. `renders/s` is frames drawn. They differ when frame skipping or lazy rendering applies.
* `ms logic` is the average time per tick in scripts and Ruffle's own update. `ms render` is the average time to record and submit a frame.
* Compare logic ms with your frame budget (33 ms at 30 fps). If logic exceeds it you are script bound.

Warning: the switch is enabled by the variable being set at all. `RUFFLE_FPS_LOG=0` also turns it on. To disable, unset it (an empty `RUFFLE_FPS_LOG_OFF` style placeholder is not needed and does nothing).

### RUFFLE_SDL_TIMING (where the main loop spends wall time)

`RUFFLE_SDL_TIMING=1` with `RUST_LOG=...ruffle_sdl=info` prints every 2 s:

```
ruffle_sdl: loop: tick 33% render 13% swap 0% (60 renders, 29.9/s)
```

Read it as shares of wall time. High tick means scripts and Ruffle logic. High render means encoding and GL replay. High swap means vsync or present is the limit. Swap at 0 to 1 percent shows present is not the bottleneck. Examples: a hub showed tick 55 percent render 7 percent, a menu tick 16 render 16. The sum below 100 means the loop is sleeping, so the game is hitting its target.

### RUFFLE_AS3_PROF (hot AS3 methods)

`RUFFLE_AS3_PROF=1` with `RUST_LOG=ruffle_core::avm2::function::as3prof=info` prints every 5 s a table headed `as3prof (self ms / total ms / calls over 5 s):` and one row per hot method (self time, total time, call count, name). Use it to pick which game methods to patch in the shell. It is off by default and costs time when on, so turn it off for a final measurement.

### PM_GPUSTAT (GPU submit counters)

`PM_GPUSTAT=1` with `RUST_LOG=...pmgpu=info` prints every 2 s:

```
per 2s: submits N, buffers N, deferred N, presents N, s3d passes N, s3d draws N, breaks buffer N, texture N, ring N
```

Few submits and passes per frame is the goal. `s3d passes` against `s3d draws` shows how well draws are merged. `breaks buffer`, `texture` and `ring` count early pass ends (the code names them as such, they relate to a buffer, a texture or the uniform ring forcing a new pass). `deferred` counts queued upload command buffers. Read the patch 0011 source (`pmstat.rs`) for the exact trigger of each counter.

### gdb sampling plus symbolising

When the counters point at the CPU but not where, sample stacks:

1. On the device, find the load address of the binary in `/proc/<pid>/maps` (the text mapping base).
2. Repeat several hundred times at about 0.25 s: `gdb -p $(pidof ruffle_sdl) -batch -ex 'thread 1' -ex 'bt 60'`.
3. On the PC, convert addresses (subtract the base) with `llvm-addr2line -f -C -e <unstripped aarch64 build>`, strip generic arguments, and count inclusive and self percentages per function.

This found the 35 percent mouse pick cost and the hub budget above. You need the unstripped build of exactly the binary on the device. Build with `strip` as a separate step so you can keep both.

### Other measurement tools

* Presented frame rate from the kernel: count changes of `/sys/class/graphics/fb0/pan` (or sample the framebuffer through mmap). It measures frames the display actually got, independent of Ruffle's counters.
* `RUST_LOG=warn,wgpu_hal=debug,wgpu_core=debug` counts compiled shaders and linked programs. Useful to see a shader compile hitch.
* `RUST_LOG=warn,avm_trace=info` on a PC under Xvfb prints AS trace output. Use it to read game values at each resolution.
* `SDL_AUDIODRIVER=dummy` rules audio out.
* Bisect at runtime with the off switches (see `05-memory.md`) instead of rebuilding.
* A probe build that disables one display subtree per 8 s phase (with baselines between) finds expensive subtrees. For Flash this means hiding display objects.
* Do not prove a quality toggle by pixel diff. Idle animation alone changes 100 to 270 pixels. Use a log line or a static scene.

Keep the frame rate log temporary in a release (the final launcher has no fps option). In a testing build, `VERBOSE_LOGS=1` in the port cfg turns the profiling variables on (see `11-launcher-packaging.md`).

## Measurements

Numbers are from the reference port on an Allwinner H700 device unless it says PC. Where two sources disagree, both are given as a range and the reason is noted.

| What | Before | After | Note |
|-|-|-|-|
| Stage3D batching (0002), hub | 2.9 fps | about 15 fps | |
| Hub on PC before batching | 8.4 to 9.6 fps (81 to 93 ms logic) | 15.7 fps (51 ms logic) | |
| Hub under ruffle_sdl, device | 14.9 to 15.4 fps (Westonpack, 58 to 63 ms logic) | 13.2 to 16.6 fps | Range: 13.2 is an A/B test with merged passes, 15 and about 16 are contributor and README figures, 16.6 is high performance mode, muOS default governor 13 to 14. Differences are build, governor and firmware. |
| 0011 merged passes, hub | 12.0 fps, 720 passes per 2 s | 13.2 fps, 105 passes per 2 s | |
| Stage3D passes per frame, hub on PC | about 30 | about 4 | |
| Lazy mouse pick, fixed step level | standing 15, jumping 12 to 13, running 8 to 13 fps | 28 to 29, 22 to 23, 23 to 30 | with frame skip |
| Mouse pick share of main thread | about 35 percent | removed when idle | commit text says about a third |
| Power mode, hub | 15.3 fps | 16.6 fps (high performance), 18.2 (1.704 GHz) | |
| drawWithQuality cap (dead end) | 15.5 fps | 13.7 fps | slower |
| Cache bitmap 1x to 0.5x (dead end) | | about 75 MB and 3 fps saved, blockier art | |
| Peak RSS on PC, lazy shapes (0007) | 813 MB | 271 to 351 MB | Commit text says 351 (lazy shapes alone), PR text says 271 (likely the whole series) |
| Peak, draw in place (0008) | 546 / 351 MB | 473 / 326 MB | two test cases |
| Peak, blank bitmaps (0009) | 473 / 326 MB | 346 / 275 MB | two test cases |
| GC push 1 percent (0006), PC | 750+ MB heap | about 560 MB | |
| Full collect after long tick | 620 MB | 400 MB | |
| Second EGL context avoided | about 80 MB (Mesa) | 0 | |
| Heavy AS2 level, device | rss 771 + gpu 503 MB, avail 40, 117 MB zram, 30 fps (desktop Ruffle under Westonpack) | rss 222 + gpu 85, avail 526, no swap, 30 fps | |
| Fixed step level, device, no swap | rss 483 + gpu 148, then OOM killed, 10 to 25 game fps | rss 296 + gpu 135, avail 427 to 437, 30 game fps, 19 to 21 drawn | the two sources disagree on avail by 10 MB |
| Light AS2 level | rss 350 + gpu 174 | rss 204 + gpu 109 | |
| Heavy levels, contributor device without swap | OOM after about 30 s (281 MB heap + 511 MB Mali) and 25 s (369 + 430) | peak 227 and 302 MB at 30 fps, 5 min at 25.7 to 28.6 fps | |
| Long session, device | | rss 803 + gpu 450, 153 MB zram (a doc elsewhere says about 300 MB, a log shows 153), restart dropped 803 to 480 | |
| Key tap caught by a polling game (0013) | 2 of 6 | 8 of 8 | |
| Binary size | 32.4 to 33.6 MB desktop | 16.7 MB | |
| Release zip | 15.3 MB | 8.1 MB | |
| Benchmark noise, identical runs | 40.5 fps | 43.4 fps | |
| Upstream leak, desktop GPU | 2.0 GB | 3.7 GB after 13 cycles | |
| Upstream lazy mesh registration | OOM at 13 cycles | OOM at 49 cycles, about 1.8 GB plateau | |

## Pitfalls

* `RUFFLE_FPS_LOG=0` turns the log on. Unset it instead.
* The target filter must be in `RUST_LOG` or the output is silent: `ruffle_core::player::port_fps=info` for the fps log, `ruffle_sdl=info` for timing, `memlog=info`, `pmgpu=info`, `ruffle_core::avm2::function::as3prof=info`.
* A GPU side copy needs `flush_pending_gpu_work` first or textures are empty.
* Frame skip hurts clock timed games and makes the picture choppier. Lazy picking breaks games that need hover under a still pointer.
* Do not trust a single benchmark run. Repeat and order on, off, on.
* PC numbers say nothing about handheld speed. Software GL is far slower than the device GPU, and the PC CPU is far faster than a Cortex A53.
* Unlocking frame rate above 30 can slow or speed up game logic. Check the timing model first.
* Frame rate depends on the governor. Always record firmware and power mode with a result.
* An experiment environment variable (`PORT_EXP`) was in the early Stage3D patch but is removed by patch 0003 and is not part of the final series.

## See also

* `04-ruffle-sdl.md` for `--render-size`, `--gl-finish`
* `05-memory.md` for memory figures and `RUFFLE_MEMLOG`
* `02-shell-patching.md` for game side fixes (copyPixels, clocks)
* `10-testing.md`
* `12-dead-ends.md` for LTO, a smaller back buffer, the GPU thread
* `env-vars.md`

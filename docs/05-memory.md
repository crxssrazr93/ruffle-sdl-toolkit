# 05. Memory on a 1 GB device

## When you need this

Read this when a Flash or AIR game runs out of memory on a handheld (the process disappears, exit code 137, the screen goes black, or the kernel log says `Killed process`), when memory keeps growing during play, or when you need to measure where the memory goes. The device class here is 1 GB of RAM, often no swap, a GPU that shares system memory, and about 700 MB free after the firmware's front end is running.

## The strategy in one paragraph

Upstream Ruffle never frees a loaded movie's resources. Patch 0014 frees the movies that AVM1 loaded (`loadMovie`, `MovieClipLoader`) once nothing of them is alive, but the main movie and everything loaded through AVM2 (`Loader`) stay until the process exits, so for those the only complete release is still process exit. The toolkit therefore (1) restarts the process at every big content boundary (relaunch per sub movie), (2) makes each movie cheaper to hold (lazy shapes, no resident blank pixels, in place draws), (3) paces the garbage collector for a language runtime that does not count its buffers, and (4) gives you accounting (`RUFFLE_MEMLOG`) so you fix what is actually big instead of what you suspect.

Measure before you blame the content. In the case that drove this work, the game's own level bitmap cache was only about 31 MB. Ruffle's eager preparation of every shape in a world SWF dominated, and that only became visible through `RUFFLE_MEMLOG`.

## Relaunch per sub movie

**What it does.** When the shell is about to switch to a different sub game or world, it saves its state and calls `fscommand("relaunch", "<args>")`. `ruffle_sdl` prints one stdout line, `RUFFLE_RELAUNCH <args>`, flushes shared objects and exits. The wrapper script `run-ruffle` (written with bash builtins only) notices the marker line and starts `ruffle_sdl` again with new flashvars (`-Pgame=... -Plevel=... -Pdoor=...`). The shell's `preLoadGame` is made a no-op so the new process goes straight to the requested content. One world lives in memory per process, and each world gets the whole 1 GB.

**Wrapper behaviour** (`templates/port/MYPORT/tools/run-ruffle`, see [11](11-launcher-packaging.md)).
* It runs the binary and copies every stdout line to its own stdout (so the line also reaches `log.txt`). When a line starts with the marker, the words after it become the next arguments, and the binary is started again once the old one has exited.
* The marker prefix is `RUFFLE_RELAUNCH`. Override it with the `RELAUNCH_MARKER` environment variable if you changed the patch. `RELAUNCH_MAX` (default 500) limits the restarts of one run.
* It uses bash builtins only (`read`, `case`, parameter expansion). A library preloaded into every process can print its own banner, and `sed` or `tail` in the pipe then re-reads that banner as a target and loops.
* `-Pname=value` words in the marker line replace the same flashvar from the first command line, and a `.swf` word replaces the SWF to run.
* State crosses the boundary only through `SharedObject` saves and the boot flashvars.
* Expect a short black screen at each world change. Tell players that is Ruffle restarting to free memory.

**Why it works.** Every loaded SWF gets a `MovieLibrary` in Ruffle holding parsed characters, GPU bitmap handles and tessellated meshes for the life of the process (with 0014 only for AVM2 and the root movie, see below). The container is a `HashMap<SwfMovie, MovieLibrary>` in `core/src/library.rs` that only grows. `LoaderInfo::unload()` merely detaches the display object, a `BitmapCharacter` caches its GPU handle, and a revisited movie allocates a new library. On a shared memory GPU (Mali), that GPU memory is system RAM. This is upstream issue https://github.com/ruffle-rs/ruffle/issues/24864 (open). Upstream PR #23071, "Fix memory leaks by making MovieLibrary garbage-collectable", was still open and conflicting with a stalled branch when this was written. Do not wait for it. If it lands, re-evaluate whether you still need a relaunch.

Upstream measurements of the same leak: 2.0 to 3.7 GB of VRAM over 13 load and unload cycles on a 4 GB desktop GPU, then `wgpu error: Out of Memory`. Related reports: #22759, #19682, #16889, #10263, #24415 and discussion #24870.

**What relaunch does not fix.** One movie whose own preload is too big for the device. That is what the next sections address.

## Freeing movies loaded by AVM1 (0014)

**What it does.** Every loaded SWF gets a `MovieLibrary`. Upstream keeps it in a map that holds the movie weakly, but the library itself holds the movie strongly, so the entry never goes away (the cause of ruffle-rs/ruffle#24864). With 0014 a library is a garbage collected object (`MovieLibraryGc`). The registry holds it weakly, and every display object keeps the library of its own movie alive (set when the object gets a parent, and when a movie is loaded into a clip). When the last display object of a movie is gone, the next collections free the library: characters, bitmaps and their GPU textures, tessellated shapes and the SWF data.

**What it covers.** Only movies loaded by AVM1 (`loadMovie`, `loadMovieNum`, `MovieClipLoader`, including JPEG, PNG and GIF loads) and placeholder movies without data (an unloaded clip, the loading and error stand-ins). Their libraries are "unpinned". All other libraries are pinned, which is the old behaviour: the root movie, and everything loaded through AVM2 `Loader` (including AVM1 movies loaded by AVM2). An AS3 shell that loads AS2 worlds therefore still needs the relaunch per world, but levels and screens that the AS2 world itself loads and unloads are freed.

**Switch.** `RUFFLE_FREE_LOADED_MOVIES=0` pins every library again, as upstream.

**Measured.** Machinarium (AVM1, a SWF per scene, per hint book page and per animation) in one scene, the hint book opened and closed 20 times with the series and 0014 built from this toolkit (x86_64, Xvfb, Mesa llvmpipe): RSS 262 -> 265 MB, with `RUFFLE_FREE_LOADED_MOVIES=0` 297 -> 347 MB. The same loop on an RG Cube XX (Knulli, Mali-G31, aarch64 build of the same tree with `build-aarch64-native.sh`): RSS 276 to 298 MB over the 20 cycles with no trend. An earlier build without the change was out of memory killed there after about 4 minutes of play. Fancy Pants World 2 Level 1 and World 3 Level 4 (started directly by flashvars, 45 s with some running) on the PC: peak RSS 277 and 348 MB on, 287 and 346 MB off, the same pictures. Ruffle's own regression tests `avm1/`, `avm2/`, `import_assets/`, `fonts/` and `mixed_avm/` pass with and without 0014 (1962 tests, release build on the pinned commit with the series).

**Accounting.** With `RUFFLE_MEMLOG` the compressed library bitmaps and parsed shape records leave the `Library` category when their library is freed (they were counted as never freed before).

**Not freed.** Sounds of a freed movie stay registered in the audio backend (the mixer keeps its decoded sound data). Content loaded through AVM2 `Loader` stays pinned: `Loader.unload()` still frees nothing.

## Making one movie cheaper

All of these are on by default and have an off switch (see `env-vars.md`). The patches are by Knifethrower.

| Technique | Patch | Switch | Idea |
|-|-|-|-|
| Lazy shape tessellation | 0007 | `RUFFLE_LAZY_SHAPES` | A DefineShape gets no render handle at preload. It is tessellated at first render at the rendered scale, and its fill bitmaps are uploaded then. |
| Drop parsed shape records | 0007 | `RUFFLE_LAZY_SHAPE_RECORDS` | Keep the tag bytes as a slice, drop the parsed records, reparse on render, hit test or `readGraphicsData`. A parse error logs and yields an empty shape. |
| Draw in place | 0008 | `RUFFLE_DRAW_IN_PLACE`, `RUFFLE_DRAW_POOL_MB` | `BitmapData.draw` draws straight into the target texture when it has one sample per pixel and the commands do not sample the target. The offscreen pool is flushed after N MB (default 16). |
| Blank bitmaps without resident pixels | 0009 | `RUFFLE_ZEROED_PIXELS` | `new BitmapData(w,h,true,0)` uses a zeroed allocation (`calloc`), so untouched pages are never made resident. |
| Empty textures | 0009 | `RUFFLE_EMPTY_TEXTURES` | A blank bitmap's GPU texture is zero initialised on the GPU instead of uploading zeros (saves an RGBA copy and a staging buffer). |
| Stage3D deferred uploads | 0011 | `RUFFLE_S3D_DEFER_UPLOAD` | Texture uploads are queued as command buffers instead of two queue submits each. Mostly a speed feature, see `06-performance.md`. |
| Stage3D dispose | 0002, 0003 | none | `TextureBase.dispose()` actually frees the GPU memory immediately (it was a stub). On shared memory GPUs that is system RAM. |

**Lazy shapes in numbers.** One world SWF held 4,255 meshes (131 MB of vertex and index data), 44 fill textures (226 MB) and about 95 MB of parsed shape records, which was an out of memory on 1 GB before the first frame. Peak RSS on a PC went from 813 MB to 351 MB with the lazy patch (the PR text quotes 271 MB for the whole series, see the ranges in `06-performance.md`). The cost moves to the first time something is displayed, so a level may hitch the first time it is explored. After lazy shapes, memory grows as a level is explored and then levels off.

**Draw in place.** Building a 65 tile level cache held 76 MB of pooled frame buffers until the end of the frame. With draw in place plus the pool cap, peak went 546 to 473 MB and 351 to 326 MB on two test cases.

**Blank bitmaps.** Peak 326 to 275 MB and 473 to 346 MB on the same two cases. Only useful when a game allocates big transparent bitmaps that it then fills by GPU draws.

**Texture and cache resolution.** Half resolution Stage3D textures (ATF decoded at scale 0.5) save memory, see `07-textures-atf.md`. Another saving is to look for oversampled caches in the game: two sub games of the reference port pre rendered their level art at 1.5 times the 720x480 stage size and ran out of memory while loading a level. Changing the bitmap cache resolution variable from 1.5 to 1 in the shell (AS2 P-code `Push "bitRes", 1.5` became `1`) fixed that, and the picture was unchanged. Treat this as a generic lesson (search for a resolution multiplier on cache bitmaps), not a recipe. Going further to 0.5 was a dead end: about 75 MB and 3 fps saved but visibly blockier art (see `12-dead-ends.md`). Measure texels per art pixel before downscaling anything.

## Garbage collector pacing

Ruffle's collector (gc-arena) paces itself by the size of garbage collected objects only. Buffers owned by those objects (strings, arrays, XML, bitmap pixels) are not counted, so churn from a game that builds and drops large temporary data keeps hundreds of MB of garbage alive. Patch 0005 adds `Player::add_gc_work(fraction)` and `Player::collect_garbage_now()`, and the `ruffle_sdl` main loop (patch 0006) uses them:

* Each tick it calls `add_gc_work(RUFFLE_GC_STEP)` (default 0.01, a 1 percent push of a full cycle). Set it to 0 to turn off. Raise it if RSS creeps with buffer heavy churn, set it to 0 if GC shows in the tick share of `RUFFLE_SDL_TIMING`.
* A tick longer than `RUFFLE_GC_LONG_TICK` seconds (default 1.0, 0 off) is treated as a load. The loop logs `long tick: X s (a load; collecting after it)`, then runs a full collection and `malloc_trim(0)`. Lower it for games whose loads take 0.5 to 1 s.
* Otherwise it calls `malloc_trim(0)` every `RUFFLE_TRIM_SECS` seconds (default 2, 0 never), because glibc keeps freed memory otherwise. At debug level it prints `trim: rss A -> B MB`.

Measured on a PC with a game that parses every level's XML at start: heap 750+ MB went to about 560 MB with the 1 percent push, and a full collect after a long tick took 620 MB to 400 MB.

## RUFFLE_MEMLOG: accounting by category

`RUFFLE_MEMLOG=1` (patch 0010) makes every allocation of the interesting kinds add its size to a category while it is alive. A sampler thread reads `/proc/self/status` every `RUFFLE_MEMLOG_MS` (default 100 ms) for `VmRSS`, `RssAnon` and `RssFile`. Off, it costs one branch.

Categories: `CpuPixels` (BitmapData pixel buffers on the CPU), `BitmapTex` (BitmapData textures), `SwfBitmapTex` (embedded SWF bitmaps), `CabTex` (cacheAsBitmap textures), `PoolTex` (pooled render targets), `Mesh` (shape meshes while rendering the stage), `MeshDraw` (meshes first tessellated inside `BitmapData.draw`), `Sound` (mixer sounds), `Swf` (uncompressed SWF data), `Library` (parsed library characters, approximate). It also tracks GPU to CPU readbacks and, at load, prints `memlog: swf N bytes uncompressed (M compressed) <url>`.

**Turn it on.** Set `RUFFLE_MEMLOG=1` and make sure the log filter includes the target: `RUST_LOG=warn,memlog=info`. Without `memlog=info` you see nothing. Optionally set `RUFFLE_MEMLOG_PEAK=/path/in/the/port/folder/memlog_peak.txt` to get the peak report in a file, and `RUFFLE_MEMLOG_TOP=N` for how many items per category to list.

**How to read it.** Once a second you get one line:

```
t=123.4 rss 410 anon 330 file 80 MB malloc 290 MB (+35 MB free in heap) | <category totals MB/count> ...
```

* `rss` is what the process holds. `anon` is heap and textures, `file` is the mapped binary and libraries.
* `malloc` is the C heap in use, `+N MB free in heap` is memory glibc holds but could give back. A big free number means trimming (`RUFFLE_TRIM_SECS`, long tick collect) is not keeping up.
* The category list tells you where the bytes are. Compare the sum with `rss`. A big gap points at something not tracked (the Rust heap in strings and arrays, the AS2 or AS3 object graph, or GPU driver memory).

At each new RSS peak (more than 1 MB above the previous peak) a longer report is produced: RSS split, category totals, category peaks so far, and the biggest items in each category (shape sizes, bitmap dimensions). Put that file in your bug report. In the reference case this located about 800 MB of use in an afternoon.

## Mali GPU memory counts against RAM

On the Mali blob driver, GPU allocations (textures, render targets, buffers) come from system RAM but are not part of the process RSS. A process showing 771 MB RSS can also hold 503 MB of Mali memory, leaving MemAvailable at 40 MB. Always read both.

**How to measure (Mali blob, needs root and debugfs):**

```
awk 'NR==1{print int($2*4/1024)}' /sys/kernel/debug/mali0/gpu_memory
```

The first line is in 4 KB pages, so MB is pages times 4 divided by 1024. Panfrost (ROCKNIX) exposes this differently, and a failed allocation there looks like `PANFROST_CREATE_BO failed (err=12)` in the log before a kill.

A small monitor loop (every 3 s) that has been useful:

```
p=$(pidof ruffle_sdl)
rss=$(awk '/VmRSS/{print int($2/1024)}' /proc/$p/status)
gpu=$(awk 'NR==1{print int($2*4/1024)}' /sys/kernel/debug/mali0/gpu_memory)
avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
swap=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{print int((t-f)/1024)}' /proc/meminfo)
echo "rss=$rss gpu=$gpu avail=$avail swap=$swap"
```

Sort by the `rss=` field to find the peak, and check `dmesg` for `Killed process`. For a lighter sampler, `grep VmHWM /proc/$(pidof ruffle_sdl)/status` and `free -m` every 20 s are enough.

Other facts worth remembering: Mali render targets cost about 4.5 times their nominal size and were not returned to the system, so budget GPU memory separately from RSS. On another port, a single large transient render target moved GPU use from 250 to 450 MB and the blob never handed it back, so avoid large transient GPU allocations.

## zram and swap

Compressed RAM swap is the safety net for 1 GB devices. Ship the advice in every port README: turn on zram (or swap) on 1 GB devices.

* Knulli on the reference device ships `/dev/zram0` of about 486 MB at priority 1000.
* muOS defaults to zram off. The size in MB lives in `/opt/muos/config/settings/advanced/zramfile` (0 is off), and `/opt/muos/script/system/swap.sh` runs `zramctl`, `mkswap` and `swapon`. 512 survives a reboot.
* ROCKNIX and dArkOS often run zram off or small. AmberELEC and ROCKNIX were reported to have swap on by default by one source and off by default by another, so check on the device with `cat /proc/swaps`.
* Log `MemTotal`, `MemAvailable`, `SwapTotal` and `SwapFree` at launcher start and exit so bug reports show the swap state. Consider a launcher warning when a 1 GB device has no swap.

**The swapoff pitfall.** `swapoff -a; swapon -a` drops zram. `/proc/swaps` is empty afterwards and tests silently run without swap, which invalidated a claim once. Restore it with:

```
swapon -p 1000 /dev/zram0 || { mkswap /dev/zram0 && swapon -p 1000 /dev/zram0; }
```

**Out of memory signatures.** Exit 137 can be an OOM kill or a hotkey `SIGKILL` (the hotkey close ends with 143 or 137). Only the kernel log distinguishes them (`Killed process`). Zram being full shows `Write-error on swap-device (253:0:...)`. Orphaned processes from earlier test runs have held 250 MB of swap and caused the next run's OOM, so kill leftovers between runs.

## Remaining growth and honest expectations

Lazy shapes remove the up front cost but do not cap growth. A 465 s play session plateaued at RSS 666 to 700 MB with a peak of 803 MB RSS plus 450 MB GPU and 153 MB in zram. A restart at a world door dropped RSS from 803 to 480 MB. Work within a world still accumulates (levels loaded and unloaded inside one movie are not freed). Relaunch plus zram remain necessary on 1 GB devices, even for a light port which used about 600 MB.

Memory savings that visibly change the art get rejected. A fixed step test level on the reference device went from OOM killed at RSS 483 plus GPU 148 MB to RSS 296 plus GPU 135 MB, and a heavy AS2 level from RSS 771 plus GPU 503 MB (avail 40 MB) to RSS 222 plus GPU 85 MB (avail 526 MB). See the table in `06-performance.md`.

## Bisecting with the off switches

Turn each patch off by environment, without rebuilding:

```
RUFFLE_LAZY_SHAPES=0 RUFFLE_LAZY_SHAPE_RECORDS=0 RUFFLE_DRAW_IN_PLACE=0 \
RUFFLE_DRAW_POOL_MB=0 RUFFLE_ZEROED_PIXELS=0 RUFFLE_EMPTY_TEXTURES=0 \
RUFFLE_S3D_DEFER_UPLOAD=0 RUFFLE_S3D_MERGE_PASSES=0 ./ruffle_sdl ...
```

Running with everything off, then enabling one at a time, isolates a rendering difference to one patch. For repeatable A/B memory runs, start the game directly in a level through flashvars so both builds load the same content, and keep the same save files. Direct start into a Stage3D hub may show a white screen in both builds. That is not a regression.

For a PC test that mimics the device budget, cap memory with `systemd-run --user -p MemoryMax=700M` (careful: an uncapped harness has OOM killed the user's desktop scope).

An allocator budget note if you extend accounting: on backends with `Device::generate_allocator_report()` (Vulkan, DX12), budget on `total_allocated_bytes`, not `total_reserved_bytes` (reserved stays flat after frees). It is not available on the GL backend.

## Pitfalls

* RSS alone underestimates on Mali. Read `gpu_memory` as well.
* `RUFFLE_MEMLOG` prints nothing unless `RUST_LOG` includes `memlog=info`. Also, a separate SWF size log line is gated on the variable merely being set, so `RUFFLE_MEMLOG=0` still prints that one line.
* `swapoff -a; swapon -a` silently removes zram.
* Direct level start into some Stage3D hubs is white in every build.
* Lazy shapes shift cost to the first display of content. A hitch on first view is expected.
* A relaunch needs the game to persist its own state (SharedObject) before calling the fscommand.
* Hotkey exit (143, 137) and OOM kill (137) look alike. Use `dmesg`.
* Do not rely on `PR #23071`. Plan for relaunch until upstream proves otherwise, except for content that AVM1 loads and unloads, which 0014 frees.
* 0014 frees a library once no display object of its movie is alive. A script that keeps only a function of an unloaded movie and later attaches that movie's symbols finds them missing (the library is created again, empty, with a debug log line `library of ... created again after it was collected`). `RUFFLE_FREE_LOADED_MOVIES=0` rules this out.

## See also

* `04-ruffle-sdl.md` for the front end and `run-ruffle`
* `06-performance.md` for speed, profiling and the measurements table
* `07-textures-atf.md` for half resolution textures
* `11-launcher-packaging.md` for the launcher memory log and the wrapper
* `12-dead-ends.md`
* `env-vars.md`

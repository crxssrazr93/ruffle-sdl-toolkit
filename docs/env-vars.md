# Environment variables and switches

## When you need this

Read this when you need to turn a Ruffle patch feature on or off, tune it, or switch on logging and profiling, or when you want to know who owns a variable (the patch author or upstream). This is the one table for every switch. Defaults were checked against the patch code in `../ruffle/patches/` (the code is the authority if this page and an older note disagree).

## How the variables are read

Truthiness is not uniform, and the difference causes real mistakes. There are three styles in the patches.

| Style | Variables | Behaviour |
|-|-|-|
| Set means on (`var_os().is_some()`) | `RUFFLE_FPS_LOG`, `RUFFLE_AS3_PROF`, `RUFFLE_SDL_TIMING`, `PM_GPUSTAT` | Any value, including `0` and an empty string, turns it on. Unset it to turn it off. |
| Opt in, not empty and not `0` | `RUFFLE_LAZY_MOUSE_PICK`, `RUFFLE_FRAMESKIP`, `RUFFLE_MEMLOG` | Off when unset, empty or `0`. (One extra `RUFFLE_MEMLOG` log line, the SWF size line, is gated on the variable merely being set.) |
| Default on, `0` disables | `RUFFLE_LAZY_SHAPES`, `RUFFLE_LAZY_SHAPE_RECORDS`, `RUFFLE_DRAW_IN_PLACE`, `RUFFLE_ZEROED_PIXELS`, `RUFFLE_EMPTY_TEXTURES`, `RUFFLE_S3D_DEFER_UPLOAD`, `RUFFLE_S3D_MERGE_PASSES`, `RUFFLE_FREE_LOADED_MOVIES` | On unless the value is exactly `0`. |
| Numeric with default | `RUFFLE_GC_STEP`, `RUFFLE_TRIM_SECS`, `RUFFLE_GC_LONG_TICK`, `RUFFLE_DRAW_POOL_MB`, `RUFFLE_MIN_KEY_HOLD_MS`, `RUFFLE_MEMLOG_MS`, `RUFFLE_MEMLOG_TOP` | An unparsable value silently falls back to the default. `0` turns the feature off where the table says so. |

Values are read once at first use and cached for the life of the process. Change them before launching.

## Pitfall first: RUFFLE_FPS_LOG

`RUFFLE_FPS_LOG` is enabled by the variable existing. `RUFFLE_FPS_LOG=0` turns the log on. A launcher that wants it off must not export it at all. Do not pass a dummy like `RUFFLE_FPS_LOG_OFF=1`. That variable is read by nothing. Use `RUFFLE_FPS_LOG=1` or unset, never `0`. The same applies to `RUFFLE_AS3_PROF`, `RUFFLE_SDL_TIMING` and `PM_GPUSTAT`.

## The table

Owner means who wrote it: K is Knifethrower, C is crxssrazr93, U is upstream or a library (Ruffle, wgpu, SDL, Mesa), T is the toolkit's test harness.

### Memory and garbage collection

| Name | Default | Effect | When to change | Patch or source | Owner |
|-|-|-|-|-|-|
| `RUFFLE_GC_STEP` | `0.01` | Extra collector work per tick as a fraction of a full cycle. `0` off. | Raise if RSS creeps with buffer heavy churn. `0` if GC shows in the tick share. | 0006 (uses 0005), `sdl/src/main.rs` | K |
| `RUFFLE_TRIM_SECS` | `2` | `malloc_trim(0)` interval in seconds. `0` never. | `0` if trim stalls show. Lower for tighter RSS. | 0006 | K |
| `RUFFLE_GC_LONG_TICK` | `1.0` | A tick longer than this many seconds is a load: full collect plus trim after it. `0` off. | Lower for games whose loads take 0.5 to 1 s. | 0006 | K |
| `RUFFLE_LAZY_SHAPES` | on | Tessellate DefineShapes at first render, not at preload. `0` for eager. | `0` to compare, or if first display hitches matter more than memory. | 0007, `core/src/display_object/graphic.rs` | K |
| `RUFFLE_LAZY_SHAPE_RECORDS` | on | Drop parsed shape records, reparse on demand. `0` keeps them. | `0` to rule out reparse bugs. | 0007 | K |
| `RUFFLE_DRAW_IN_PLACE` | on | `BitmapData.draw` draws straight into the target texture when safe. | `0` to rule out rendering differences. | 0008, `render/wgpu/src/backend.rs` | K |
| `RUFFLE_DRAW_POOL_MB` | `16` | Submit and empty the offscreen pool after this many MB of pooled draws. `0` off. | Lower on tight memory. Higher if the extra submits cost fps. | 0008 | K |
| `RUFFLE_ZEROED_PIXELS` | on | Zeroed allocation (calloc) for blank BitmapData pixels. | `0` to compare. | 0009, `core/src/bitmap/bitmap_data.rs` | K |
| `RUFFLE_EMPTY_TEXTURES` | on | GPU zero init for blank bitmap textures, no zero upload. | `0` if a driver mishandles zero init. | 0009 | K |
| `RUFFLE_FREE_LOADED_MOVIES` | on | Free the library of a movie loaded by AVM1 (`loadMovie`, `MovieClipLoader`, images too) once none of its display objects is alive. `0` keeps every library for the life of the process, as upstream Ruffle does. | `0` to rule out a missing symbol after an unload, or to compare memory. | 0014, `core/src/library.rs` | K |
| `RUFFLE_MEMLOG` | off | Category accounting plus an RSS sampler thread. Needs `RUST_LOG=...memlog=info` to be visible. | Investigating an OOM. | 0010, `render/src/memlog.rs` | K |
| `RUFFLE_MEMLOG_MS` | `100` | RSS sample period in ms. | Finer or coarser. | 0010 | K |
| `RUFFLE_MEMLOG_TOP` | `8` | Items listed per category at each new peak. | Deeper dumps. | 0010 | K |
| `RUFFLE_MEMLOG_PEAK` | unset (peak report is logged) | File that receives the latest peak report. | Set a file in the port folder on a device. | 0010 | K |

### Rendering and speed

| Name | Default | Effect | When to change | Patch or source | Owner |
|-|-|-|-|-|-|
| `RUFFLE_LAZY_MOUSE_PICK` | off | Re-pick the hovered object only when the mouse moved or a button changed. | Large AVM1 levels, gamepad only games. Not for hover under a still pointer. | 0004, `core/src/player.rs` | C |
| `RUFFLE_FRAMESKIP` | off | At least 2 frames per tick when slow, so frame counted games keep speed. | Fixed step games that slow below target. Not for clock timed games. | 0004 | C |
| `RUFFLE_S3D_DEFER_UPLOAD` | on | Queue Stage3D upload command buffers instead of two submits each. | `0` to compare or to rule out ordering bugs. | 0011, `render/wgpu/src/backend.rs` | K |
| `RUFFLE_S3D_MERGE_PASSES` | on | Merge consecutive `drawTriangles` into one pass, with a 1 MB uniform ring. | `0` to compare. | 0011, `context3d/current_pipeline.rs` | K |
| `RUFFLE_MIN_KEY_HOLD_MS` | `100` | Hold back a key up that arrives sooner than this after its key down. `0` off. | `0` for event driven games. Raise for 20 fps games that poll. | 0013, `sdl/src/main.rs` | C |

### Logging and profiling

| Name | Default | Effect | When to change | Patch or source | Owner |
|-|-|-|-|-|-|
| `RUST_LOG` | `warn` (ruffle_sdl default filter) | tracing filter. Example: `warn,ruffle_core::player::port_fps=info,ruffle_sdl=info,memlog=info,pmgpu=info`. | Whenever a profiling variable should print. | 0006 (`EnvFilter::try_from_default_env`) | U |
| `RUFFLE_FPS_LOG` | off, but any value turns it on (even `0`) | `port_fps` line every 2 s: frames per second, ms logic, renders per second, ms render. Needs `ruffle_core::player::port_fps=info`. | Performance measurement. | 0002, `core/src/player.rs` | C |
| `RUFFLE_SDL_TIMING` | off, any value turns it on | Every 2 s: tick, render and swap share of wall time. Needs `ruffle_sdl=info`. | CPU against GPU bound profiling. | 0006 | K |
| `RUFFLE_AS3_PROF` | off, any value turns it on | Hottest AS3 methods every 5 s. Needs `ruffle_core::avm2::function::as3prof=info`. | Find game side hot spots to patch. | 0003, `core/src/avm2/function.rs` | C |
| `PM_GPUSTAT` | off, any value turns it on | GPU submit, pass and draw counters every 2 s (target `pmgpu`, needs `pmgpu=info`). | GPU submit profiling. | 0011, `render/wgpu/src/pmstat.rs` | K |
| `RUFFLE_RELAUNCH` (a line, not a variable) | not applicable | Stdout marker line `RUFFLE_RELAUNCH <args>` printed by the relaunch fscommand. | Never set. Wrapper reads it. | 0002 and 0006 | C |
| `RELAUNCH_MARKER` | `RUFFLE_RELAUNCH` | The wrapper's marker prefix override. | Only if you changed the marker in the patch. | `templates/port/MYPORT/tools/run-ruffle` | C |

### Drivers and SDL

| Name | Default | Effect | When to change | Patch or source | Owner |
|-|-|-|-|-|-|
| `WGPU_DISCARD_HAL_LABELS` | not needed in ruffle_sdl | Stops wgpu emitting GL debug labels, which crash the Mali blob in `glPushDebugGroup` (gfx-rs/wgpu#8937). ruffle_sdl sets the equivalent instance flag in code. | Set to `1` for stock desktop Ruffle (Westonpack path) on a Mali blob. | 0006 (flag), wgpu (env) | U |
| `WGPU_*` GL options | wgpu defaults | `GlBackendOptions::from_env_or_default` and instance flags read from the environment. | Driver workarounds. | 0006 | U |
| `SDL_VIDEO_X11_FORCE_EGL` | set to `1` by ruffle_sdl as an SDL hint | Mesa on X11 gives GLES contexts only through EGL. | You do not set it. PC testing only. Alone it does not help under qemu and Xvfb. | 0006 (`sdl2::hint::set`) | U, K |
| `SDL_VIDEODRIVER` | firmware default | SDL video driver. | `x11` under Xvfb for tests. | SDL | U |
| `SDL_AUDIODRIVER` | firmware default | SDL audio driver. | `dummy` to rule out audio in tests. | SDL | U |
| `LIBGL_ALWAYS_SOFTWARE` | unset | Mesa software rendering. | `1` for PC and qemu runs. | Mesa | U |
| `SDL_GAMECONTROLLERCONFIG` | firmware | Pad mapping used by gptokeyb and SDL. Not read by ruffle_sdl code. | Port launcher only. | gptokeyb, launcher | U |
| `XDG_RUNTIME_DIR` | firmware | Needed so ALSA can reach PipeWire. Westonpack replaced it, ruffle_sdl does not. | Test harnesses use a private one (see `10-testing.md`). | system | U |

### Launcher, template and config

| Name | Default | Effect | When to change | Patch or source | Owner |
|-|-|-|-|-|-|
| `VERBOSE_LOGS` | `1` in a testing template, `0` for release | Port cfg switch. When 1 the launcher exports `RUST_LOG`, `RUFFLE_FPS_LOG`, `RUFFLE_SDL_TIMING`, `RUFFLE_MEMLOG` (with `RUFFLE_MEMLOG_MS` and `RUFFLE_MEMLOG_PEAK`), `RUFFLE_AS3_PROF` and `PM_GPUSTAT`, and keeps `log.prev.txt`. | Set `0` for a release. | `templates/port/MYPORT/MYPORT.cfg` | C |

### Test only hooks

These exist only in a tree prepared by `tests/sdl_test_hooks.py` (which adds `sdl/src/test_hooks.rs`) and are not part of the shipped series. Never set them for players. `tests/pc_sdl_run.sh` and `tests/gamescope_headless.sh` set them for you.

| Name | Default | Effect | When to change | Patch or source | Owner |
|-|-|-|-|-|-|
| `RUFFLE_SDL_SHOT` | unset (no capture) | Where PNG captures go: a directory (`shot-001.png`, ...), a `%d` or `%03d` pattern, or a file name (later captures get `-N` before the extension). | PC automated tests. | `tests/sdl_test_hooks.py` | T (C) |
| `RUFFLE_SDL_SHOT_AT` | `60` when `RUFFLE_SDL_SHOT` is set | Comma separated capture points, render frame numbers or seconds with an `s` suffix (`60,2.5s,10s`). | Pick the moment to capture. | `tests/sdl_test_hooks.py` | T (C) |
| `RUFFLE_SDL_KEYS` | unset | File polled for new lines `down <key>`, `up <key>`, `tap <key>` (tap releases after 150 ms). Key names are SDL names, lowercase and `enter` or `esc` also work. | Scripted key input without a device. | `tests/sdl_test_hooks.py` | T (C) |
| `RUFFLE_SDL_EXIT_AFTER_SHOTS` | unset | `1` quits once every capture point has been saved. | Short capture runs. | `tests/sdl_test_hooks.py` | T (C) |

Variables of the harness scripts themselves (not read by the player): `RES` (default `640x480`), `SHOT_AT` (default `2s`), `EXIT_AFTER_SHOTS` (default `0`), `KEYS`, `MEM_MAX`, `DNUM` (first display number to try, default 90), `RUST_LOG` (default `warn,ruffle_sdl=info,avm_trace=info`), `VIEW`, `VNC_PORT` (default 5990) and `HOLD`. See [10 Testing](10-testing.md).

### Software cursor (optional patch 0100)

Not in the default series. These variables exist only when `ruffle/optional/0100-ruffle_sdl-software-cursor-overlay.patch` is applied (for example `WITH_OPTIONAL="0100" ruffle/fetch.sh`). The patch text is the authority. See `09-input.md` for all cursor options and `ruffle/optional/README.md` for the patch.

| Name | Default | Effect | When to change | Patch or source | Owner |
|-|-|-|-|-|-|
| `RUFFLE_SW_CURSOR` | `0` | `1` (also `true`, `yes`, `on`) draws a software cursor as a GL quad after Ruffle's frame. Shown after mouse motion, hidden after idle. Also `--sw-cursor` on the command line. | Games or menus that need a pointer. | optional patch 0100 | C |
| `RUFFLE_SW_CURSOR_IDLE_MS` | `2000` | Hide the cursor after this many ms without motion. | Shorter for less distraction. | optional patch 0100 | C |
| `RUFFLE_SW_CURSOR_SIZE` | `24` | Height of the built in arrow in pixels (8 to 256). For a PNG image: unset keeps the image size, set scales it to this height. | Bigger on high resolution screens. | optional patch 0100 | C |
| `RUFFLE_SW_CURSOR_IMAGE` | unset (built in arrow) | Path to a PNG used as the cursor image (up to 512 by 512, hotspot at the top left pixel). A file that fails to load falls back to the arrow with a warning. | Custom look. | optional patch 0100 | C |
| `RUFFLE_SDL_CURSOR` | `0` | `1` builds an SDL colour cursor (`SDL_CreateColorCursor`) from the same bitmap and shows it. Works only where the video driver draws cursors (X11, Wayland), not on fbdev or KMSDRM without a hardware cursor. | Drivers that show an SDL cursor. | optional patch 0100 | C |

### Experiments that are not shipped

| Name | Default | Effect | Status |
|-|-|-|-|
| `PORT_EXP` | `0` | Skipped Stage3D draws (`1`) or render passes (`2`) to bound GPU cost. | In the 0002 patch text but removed again by 0003. It is not in the final series. |
| `RUFFLE_GPU_THREAD` | on in the experiment | Ran submit and present on a worker thread. | Experiment only, a dead end on the Mali blob. See `12-dead-ends.md`. |
| `PORT_NO_POOL`, `PORT_BB_DIV` | unset, `1` | No staging belt pool, divide the Stage3D back buffer. | Experiments only, not in the series. |
| `RUFFLE_FPS_LOG_OFF` | none | A dummy placeholder an old launcher passed. Read by nothing. | Remove from launchers. |

## Choosing a profile

* Normal play, release: set nothing. Defaults are tuned for 1 GB devices. Add `RUFFLE_LAZY_MOUSE_PICK=1` or `RUFFLE_FRAMESKIP=1` only for a target that needs them, in the wrapper per world.
* Testing build: `VERBOSE_LOGS=1`.
* Memory bug: `RUFFLE_MEMLOG=1 RUST_LOG=warn,memlog=info RUFFLE_MEMLOG_PEAK=memlog_peak.txt`.
* Speed bug: `RUFFLE_FPS_LOG=1 RUFFLE_SDL_TIMING=1 RUST_LOG=warn,ruffle_core::player::port_fps=info,ruffle_sdl=info`, then `PM_GPUSTAT=1` with `pmgpu=info` or `RUFFLE_AS3_PROF=1` as needed.
* Rendering regression: set every `RUFFLE_*` default on switch to `0` and re enable one at a time (list in `05-memory.md`).

## Pitfalls

* Set means on. `RUFFLE_FPS_LOG=0`, `RUFFLE_AS3_PROF=0`, `RUFFLE_SDL_TIMING=0` and `PM_GPUSTAT=0` all turn their feature on.
* Default on switches treat only the exact value `0` as off. `false` or `off` leave them on.
* A target missing from `RUST_LOG` hides a variable's output. This is the most common "it does nothing" cause.
* Variables are cached at first use. Changing them in a running process does nothing.
* A wrapper that exports a variable with an empty value can still count as set for the first style.
* The cursor variables above are absent from stock builds. Setting them does nothing unless the optional patch is applied.
* `RUFFLE_GC_STEP`, `RUFFLE_TRIM_SECS` and `RUFFLE_GC_LONG_TICK` are read by the ruffle_sdl front end only, not by desktop Ruffle.

## See also

* `04-ruffle-sdl.md`, `05-memory.md`, `06-performance.md`
* `09-input.md` for the cursor options and key hold
* `10-testing.md` for the test hooks
* `11-launcher-packaging.md` for `VERBOSE_LOGS`
* `../ruffle/README.md` for the patch list

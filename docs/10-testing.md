# 10 Testing

## When you need this

Read this before you test a build, whether on the PC, in a headless GPU session, under qemu, or on a real handheld. It lists the harnesses, the capture methods that work, the ones that do not, and the traps that cost hours: stale logs, self matching `pkill -f`, patcher screens waiting for a button, stray windows on your desktop, and noisy benchmarks.

Tools named here live under `tests/` (see `tests/README.md` for the exact usage of each). Anything that touches a device is only run on purpose, with the host taken from the environment.

## Ground rules

1. Test on the PC first. Use the device only after the PC run is clean, and only with the owner's approval. Read only SSH inspection is fine. Never copy or install builds onto someone's device unasked.
2. Never open a window on the desktop (see "No desktop windows").
3. Cap memory when emulating a handheld: `systemd-run --user -p MemoryMax=700M ...`. A test run once exhausted the host and the kernel killed the desktop session. Keep parallelism low (at most 2 games at once).
4. Test the quit path with the real hotkey kill sequence, not only with the frontend's kill API (see Pitfalls).
5. Run every build and test script from a clean state before you publish it. Hand written scripts hid three bugs that only a clean run found.

## PC harness on Xvfb

`tests/pc_sdl_run.sh <ruffle_sdl> <port dir> <WxH> <game> <level> <seconds> <out prefix> [steps...]`

* Starts `Xvfb :NN -screen 0 WxHx24 +extension GLX` on a free private display (find one with `while [ -e /tmp/.X$D-lock ]`), waits for `xdpyinfo` (up to 20 s) and aborts if it never answers.
* Runs the front end with `env -u WAYLAND_DISPLAY SDL_VIDEODRIVER=x11 LIBGL_ALWAYS_SOFTWARE=1 SDL_AUDIODRIVER=dummy`.
* Steps: `shot` (capture a PNG), `s:N` (sleep N seconds), `tap:KEY` (tap an SDL key name, Start is `space`).
* Environment: `ASPECT` (default extend), `DNUM` (display number, so two runs can go in parallel).
* Ends every process with SIGKILL from a trap.

Use it for layout, aspect, input and logic. It uses llvmpipe, so it says nothing about speed. A direct level entry needs flashvars (`--stage-scale movie --quality low -Paspect=extend -Pgame=... -Plevel=...`). Flashvar names are per game; the approach is generic. A missing level SWF gives a white screen, and starting some AS3 hubs directly also shows white. Neither is a regression.

Build the x86_64 front end with `ruffle/build-x86_64.sh <src> <out>`, from the same patched tree, using your own `CARGO_TARGET_DIR`. Run cargo from inside the source tree. Running it from elsewhere builds into another target folder and you then test a stale binary.

Read ActionScript `trace` output with `RUST_LOG=warn,avm_trace=info`.

## The test only capture hook

External grabbers show black for the GL output (see the dead ends below). So the harness captures inside the process.

`tests/sdl_test_hooks.py <ruffle src dir>` patches `sdl/src/main.rs` with two test only features (revert with `git checkout -- sdl/src/main.rs` so it never ships):

* Capture: touching `<prefix>.ppm.req` makes the loop call `glReadPixels` on the window (read framebuffer 0) just before `gl_swap_window()` and write a P6 PPM, rows flipped. The runner waits about 1.5 s, then converts to PNG with ImageMagick.
* Keys: writing an SDL key name into `<prefix>.ppm.key` taps it, KeyDown now and KeyUp 150 ms later (through the minimum key hold queue).

The hook is gated by the environment variable `RUFFLE_SDL_SHOT=<prefix>.ppm`. It is not a Cargo feature, only a source patch.

Critical detail: before `glReadPixels`, save, reset and restore the GL pixel pack state. Levels that use `BitmapData.colorTransform` or brightness filters make wgpu read back through a pixel pack buffer and leave `PIXEL_PACK_BUFFER` bound and `PACK_ROW_LENGTH` set. Then:

* the capture lands in the buffer object and the picture is all zero, and
* unbinding only the buffer lets a stale row length write past the Vec (a SIGSEGV).

So read `PIXEL_PACK_BUFFER_BINDING`, `PACK_ALIGNMENT`, `PACK_ROW_LENGTH`, `PACK_SKIP_ROWS`, `PACK_SKIP_PIXELS` and the read framebuffer binding, set them to 0, 1, 0, 0, 0 and framebuffer 0, read, and restore all of them (wgpu tracks that state itself).

If a capture is black, suspect your capture first. An hour was lost blaming Mesa and a fade clip before the harness was the cause.

## Gamescope headless

For GPU accelerated offscreen runs (llvmpipe is too slow for long level walks), use gamescope with its headless backend and a private runtime directory:

```
export XDG_RUNTIME_DIR="$(mktemp -d)"
setsid gamescope --backend headless -W 720 -H 720 -w 720 -h 720 -- ./run_inside.sh &
# stop with: kill -9 -- -<pgid>
```

Notes: it renders on the real GPU, roughly five times faster or more than Xvfb software GL. It warns "No CAP_SYS_NICE", which is harmless. Inside it you get a `DISPLAY` and no `WAYLAND_DISPLAY`. The generic grabbers (import, x11grab) still do not work there, so use the capture hook. `tests/gamescope_headless.sh` wraps this.

## aarch64 under qemu

To test the exact device binary (glibc floor, library resolution, startup), run it under qemu user mode with an arm64 sysroot built from Docker (Debian with `dpkg --add-architecture arm64`, qemu-user-static and arm64 SDL2, EGL, GLES, Mesa and X11 client libraries). Call it as:

```
qemu-aarch64-static -L $SYSROOT $SYSROOT/lib/ld-linux-aarch64.so.1 \
  --library-path "$PORT/lib:$SYSROOT/usr/lib/aarch64-linux-gnu" ./ruffle_sdl ...
```

with `LIBGL_ALWAYS_SOFTWARE=1 SDL_AUDIODRIVER=dummy` inside a private Xvfb. It takes minutes to the first frame, so it validates startup, glibc and memory behaviour only. `tests/aarch64_qemu_run.sh` wraps it. A qemu run of `ruffle_sdl` itself has not been recorded yet; the recipe was proven on another SDL application. Treat the first run as an experiment.

Pitfalls specific to this path:

* If the binary exits silently, the sysroot interpreter symlink is dangling (the Debian `/lib` merge was not carried over). Fix the `lib/aarch64-linux-gnu` symlink and invoke `ld-linux-aarch64.so.1 --library-path` explicitly. Debug with `qemu-aarch64-static -strace` and `LD_DEBUG=libs`.
* SDL on X11 dlopens the desktop libGL even for a GLES context, so the sysroot needs Mesa GLX (`libgl1 libglx-mesa0 libopengl0`). `SDL_VIDEO_X11_FORCE_EGL=1` alone did not give a window in one test. This is a PC only issue. Devices use fbdev or KMSDRM EGL.
* Mesa on PC is not a stand in for Mali. Anything that passes on Mesa can still break on a Mali blob. After two failed guesses, add a probe instead of guessing again.

## Device testing

### Knulli and Batocera EmulationStation HTTP API (port 1234)

| Call | Use |
|-|-|
| `GET /systems/ports/games` | JSON list of ports with `path` |
| `GET /reloadgames` | Re-scan after you copied a launcher |
| `POST /launch` | Body is the plain path, not JSON |
| `GET /runningGame` | What is running now |
| `GET /emukill` | Stop the running game |

```
curl -X POST -d '/userdata/roms/ports/MYPORT.sh' http://127.0.0.1:1234/launch
```

Launch through ES, not from an SSH shell. Only that path runs the real emulatorlauncher wrapper, gptokeyb, power mode and the patcher screen the way a player gets them. Starting by hand misleads.

API pitfalls:

* After copying a new launcher call `/reloadgames`, wait about 10 s and confirm it appears in `/systems/ports/games`. Otherwise `/launch` fails silently.
* `/launch` with an unknown path starts the selected game. Always check `/runningGame`.
* ES can overwrite gamelist edits on reload when it is dirty. Verify through the API.
* Stray key presses after the game exits land in ES and can set a filter (a "No Entries Found" list). Restart ES to clear. Only inject while `/runningGame` names a game, and stop if a person is pressing buttons.
* Never `emukill` during setup tests. It left a stale patcher process behind. Kill by PID.
* Do not overwrite a running launcher or harness script. Bash reads scripts incrementally. Copy to a temporary name and `mv`, or stop the game first.

### Virtual keyboard from a FIFO (uinput)

`tests/keyd.py` creates a uinput keyboard and reads lines from a FIFO: `<KEY> <ms>` (hold that long) or `sleep <ms>`. It writes a pid file, so you never need `pgrep -f`. Because it bypasses gptokeyb, it separates "the game misses input" from "the gptokeyb mapping is wrong". It works with or without gptokeyb running. Use `KEY_ESC` (there is no `KEY_ESCAPE` in evdev).

Other injectors that worked:

* Writing EV_KEY and ABS_HAT events (then EV_SYN, SYN_REPORT, 0) to the real pad's `/dev/input/event*` node reaches every reader (evdev, joydev, SDL, gptokeyb). A HAT needs a hold (`hold dup 0.3`), not a press. Where `python-evdev` is missing, pack `struct.pack('qqHHi', sec, usec, type, code, value)`.
* Mouse motion works when written (EV_REL and BTN_LEFT) into gptokeyb's own virtual "Fake Keyboard" evdev node. A fresh uinput mouse created after launch was not seen by the game. Injecting the right stick into the real pad did not work.

### Framebuffer screenshots (device)

`fbgrab` shows white for GL output. Read the raw framebuffer instead, as BGRA, and crop at the pan offset:

```
dd if=/dev/fb0 bs=<stride> count=<rows> 2>/dev/null | magick -size WxH -depth 8 bgra:- -crop WxH+0+<pan> out.png
```

The virtual framebuffer is double buffered (for example 640x960 for a 640x480 screen). The page to crop is selected by `/sys/class/graphics/fb0/pan`. Detect `virtual_size` and `bits_per_pixel` from sysfs instead of hard coding them. A frame rate from the device can be derived by counting pan changes. A pixel probe (read one pixel after each injected press) tells you whether a pause overlay is up.

### Patcher screen waits for a button

The first launch and the first launch after a patch version bump show PortMaster's patcher screen, which waits for a button press when done (and sometimes at the start). While it waits, `/runningGame` still reports a game, `/launch` is ignored and the setup log looks stale. A test driver should press A when the log shows done, or send Enter through the virtual keyboard. If you need a new launch, `emukill` first. Take PATCHER_TIME from a measured device run.

Setup test matrix (run each): fresh copy, one PNG deleted, embedded asset deleted, ATF missing, ATF damaged, XML or `.orig` missing, level SWF missing, restored, interrupted run, game update. Delete the gamedata marker to force the patcher for a quick smoke test. After swapping stamped files for testing, regenerate the stamp.

### Logs and monitors

* Delete or rename logs before a run, and key waits on log content, not on mtime (exFAT and some firmwares have clocks hours off).
* Read the whole log, not the head. A status line after line five caused a false "patching broke X".
* A device memory sampler records player RSS, GPU driver pages (Mali memory is invisible in RSS), `MemAvailable` and swap every few seconds. Or sample `VmHWM` from `/proc/$PID/status`. A measurement budget on a 1 GB handheld is about 550 to 560 MB free with the frontend resident.
* Orphans after a kill can hold hundreds of MB of swap and fail the next run. Check `free -m` and `/proc/swaps` before memory runs. `swapoff -a` followed by `swapon -a` does not restore zram. Use `swapon -p 1000 /dev/zram0`.
* Exit codes from the firmware hotkey: 143 (SIGTERM) and 137 (SIGKILL after SIGTERM was ignored) are normal. An OOM kill is also 137, distinguishable only in the kernel log.
* `tests/device.sh` takes host, password file and launcher from environment variables, never from constants. It has subcommands for launch, stop, keyd, keys, shot, stat and waitfps. It never runs by default.

## Process and window hygiene

### No desktop windows

Test processes must never open a visible window on the user's desktop. Causes seen: a harness that fell back to the desktop under load, and a rootful Xwayland with decorations (it is an ordinary visible window).

* Use Xvfb on a private display, or gamescope headless with a private `XDG_RUNTIME_DIR`.
* With Xvfb set `SDL_VIDEODRIVER=x11` and `XDG_RUNTIME_DIR` to a private temporary directory. Otherwise a late Xvfb makes SDL fall back to `$XDG_RUNTIME_DIR/wayland-0` and the window appears on the real compositor.
* `env -u DISPLAY -u WAYLAND_DISPLAY` before setting your own, and abort the run if `xdpyinfo` fails on the test display.
* Never use rootful Xwayland.
* End test processes with SIGKILL from a trap. Crash dialogs from systemd-coredump still reach the desktop on a segfault at exit (and `ulimit -c 0` does not stop them), so check `coredumpctl list | tail` after runs. SIGKILL loses block buffered stdout, so log to stderr.
* A game pauses when it loses focus. If a PC run shows stale frames, refocus in a loop.

### pkill -f self matching

* `pkill -f` and `pgrep -f` match the shell that runs them (exit 144 locally, 255 over SSH). Use a pid file, `pidof`, `pgrep -x`, or kill saved PIDs from the harness.
* An empty pattern (`pgrep -f ''`) matches every process. A stop script run without arguments killed sshd on a device twice. Guard every kill loop against empty or short patterns.
* Put kill loops in their own script and kill from a separate ssh call.
* Do not `pkill -f "Xvfb :19"` in a command line that itself contains that text.

### gptokeyb's hotkey kill hits the logger

The quit hotkey makes gptokeyb run `pkill -f <name>`. If the kill name appears in the logger's command line (for example `tee /roms/ports/<name>/log.txt` where the folder equals the kill name), `tee` dies, the launcher dies on the broken pipe before `pm_finish`, the log is truncated, and some firmwares show "A general error has occurred". Fix: `cd` into the port folder and use a relative `tee log.txt`. For ports whose kill name is `ruffle_sdl` it does not trigger. This went unnoticed on one firmware because all tests ended games with the API kill. Test quitting with the real hotkey.

## Benchmarking rules

* Run every measurement at least twice. Two identical runs scored 40.5 and 43.4 fps, so a "win" of 2.5 fps was noise.
* Wait until loading finishes (presented frames above about 20 per second) before you measure.
* Set the governor and power mode explicitly, and note them. A high performance mode changed one result from 15.3 to 16.6 fps. A different firmware changed it again.
* Frame logs: `RUFFLE_SDL_TIMING=1` (tick, render and swap share every 2 s) and `RUFFLE_FPS_LOG=1` with `RUST_LOG` including `ruffle_core::player::port_fps=info`. Wait for N lines with `tests/device.sh waitfps N`.
* The profilers: `RUFFLE_AS3_PROF=1` for hot AS3 methods, `PM_GPUSTAT=1` for GPU submit counts, `RUFFLE_MEMLOG=1` for memory by category.
* Bisect without rebuilding: the memory patches have runtime switches (`RUFFLE_DRAW_IN_PLACE=0`, `RUFFLE_ZEROED_PIXELS=0` and others), `SDL_AUDIODRIVER=dummy` isolates audio, `RUST_LOG=warn,wgpu_hal=debug,wgpu_core=debug` counts shaders and programs. See [env-vars.md](env-vars.md).
* Verify a patched SWF numerically with a trace build (see [08](08-screen-aspect.md)) rather than by eye.
* Gdb sampling profiler on device: read the text mapping base from `/proc/PID/maps`, then repeatedly `gdb -p PID -batch -ex 'thread 1' -ex 'bt 60'`, and symbolise offline with `llvm-addr2line` against an unstripped build. If ptrace is restricted (Yama), LD_PRELOAD a small library that calls `prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY)`.

## Dead ends

* Screenshots with `import -window root`, `import -window <id>`, `ffmpeg -f x11grab` all show black for `ruffle_sdl` GL output on Xvfb (even with GLX and software GL) and in gamescope headless. They do work for desktop Ruffle layout checks. Use the in process hook.
* `xdotool` against the SDL window in Xvfb: focus errors and unreliable taps. Use the in process key tap.
* Stock desktop Ruffle does not reproduce the port's extend layout.

## Pitfalls

* Stale logs and screenshots make a wait loop pass on the previous run.
* A hung `sleep` from a sentinel like `SHOT_AT=999`. Use real timeouts.
* A tmpfs scratch directory fills up and truncates big copies silently. Use disk.
* SSH quirks: DHCP IPs change (use hostnames), first connect needs `StrictHostKeyChecking=accept-new`, `scp` to paths with spaces fails (use `ssh host "cat > 'path'" < file`), concatenated tars extract only the first, zsh and fish do not word split a variable holding a command. Put loops in bash scripts.
* Host kills that look like your test may be another application's cgroup limit. Check `journalctl` for the real reason.
* Do not copy the user's game files into a repo. Symlink them in test directories.

## See also

* [08 Screen and aspect](08-screen-aspect.md)
* [09 Input](09-input.md)
* [11 Launcher and packaging](11-launcher-packaging.md)
* [06 Performance](06-performance.md)
* [env-vars.md](env-vars.md)

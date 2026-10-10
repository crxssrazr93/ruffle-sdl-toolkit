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

```
tests/pc_sdl_run.sh [--headless | --visible[=auto|xephyr|vnc]] [--vnc-port N] [--hold SECS] \
    <ruffle_sdl> <swf> <out_dir> [seconds] [extra ruffle_sdl args]
RES=640x480 SHOT_AT=2s,4s KEYS="1:tap Space;3:down Left;4:up Left" MEM_MAX=700M \
    tests/pc_sdl_run.sh ./ruffle_sdl tests/fixtures/test_loop.swf /tmp/run1 6
```

* Positional arguments: the binary, the SWF, an output folder, an optional time limit in seconds (default 6) and then any extra arguments, which go to `ruffle_sdl` before the SWF path. Flashvars therefore use the normal `-P` option, for example `tests/pc_sdl_run.sh ./ruffle_sdl game.swf /tmp/run1 20 --stage-scale movie -Pkey=value`.
* It starts `Xvfb :NN +extension GLX` on a free private display (found with a lock file and socket check, first try `DNUM`, default 90), waits for `xdpyinfo` and aborts with exit 3 if the display never answers.
* It runs the binary with `SDL_VIDEODRIVER=x11`, `SDL_VIDEO_X11_FORCE_EGL=1`, `LIBGL_ALWAYS_SOFTWARE=1`, `SDL_AUDIODRIVER=dummy`, a private `XDG_RUNTIME_DIR` and the caller's `DISPLAY`, `WAYLAND_DISPLAY` and `XAUTHORITY` dropped. It passes `--width`, `--height` (from `RES`) and a `--save-directory` inside the output folder.
* It waits for the time limit or for the process to end by itself (quit, relaunch, `EXIT_AFTER_SHOTS`), then ends everything with SIGKILL from a trap.
* Output folder: `shot-001.png` and so on, `run.log` (stdout and stderr, so AS trace lines and the `RUFFLE_RELAUNCH` marker line are in it), `xvfb.log`, `keys.txt` (the key script as the hook saw it), `exit_code` (the exit status, or `killed` when the time ran out) and `saves/`.

Environment variables:

| Variable | Meaning |
| --- | --- |
| `RES=WxH` | screen and window size, default `640x480` |
| `SHOT_AT=<list>` | capture points, default `2s` (see the hook table below) |
| `EXIT_AFTER_SHOTS=1` | end the run once every capture is saved, default `0` |
| `KEYS="<s>:<line>;..."` | key script: seconds after start, then `down`, `up` or `tap` and a key name, items separated by semicolons |
| `MEM_MAX=700M` | wrap the run in `systemd-run --user --scope -p MemoryMax=...` |
| `DNUM` | first display number to try, so two runs can be started apart |
| `RUST_LOG` | default `warn,ruffle_sdl=info,avm_trace=info` |
| `VIEW`, `VNC_PORT`, `HOLD` | environment forms of `--visible`, `--vnc-port` and `--hold` |

Use it for layout, aspect, input and logic. It uses llvmpipe, so it says nothing about speed. Flashvar names are per game, the approach is generic. A missing level SWF gives a white screen, and starting some AS3 hubs directly also shows white. Neither is a regression.

A binary built without the hooks still runs (good for exit codes and the relaunch marker), it just takes no screenshots.

Build the x86_64 front end with `ruffle/build-x86_64.sh <src> <out>` from the same patched tree. Run cargo from inside the source tree. Running it from elsewhere builds into another target folder and you then test a stale binary.

Read ActionScript `trace` output with `RUST_LOG=warn,avm_trace=info` (already in the default).

### Watching a run: `--headless` and `--visible`

`--headless` is the default and is the only mode to use for automated runs, CI and anything unattended. Nothing is shown anywhere. The two viewing modes below are opt in, for a person who wants to watch a test, for example to see why a scripted key sequence does not do what it should. They never run by accident, and a test script must not pass them.

| Flag | What happens | When a human would use it | Status |
| --- | --- | --- | --- |
| `--visible=vnc` | the X server stays Xvfb (no window) and `x11vnc` serves it on `127.0.0.1` only, with a random password written to `<out_dir>/vnc.pass`. Connect with `vncviewer localhost:<port>` | the machine has no spare desktop, you are on a remote shell, or you want to watch without any window appearing on your own screen until you choose to connect | verified: the server starts, listens on localhost only and is cleaned up |
| `--visible=xephyr` | the X server is Xephyr, a nested window on your desktop. Only the Xephyr process sees your desktop, the test program only sees the nested display | the quickest way to see the game live on a local desktop | not verified, Xephyr is not installed on the author's machine |
| `--visible` (same as `--visible=auto`) | Xephyr if it is installed and a desktop display exists, otherwise vnc | when you do not care which | follows the two rows above |
| `--vnc-port N` | first port to try for vnc (default 5990), the next free port is used | only when 5990 is taken or must match a firewall rule | |
| `--hold SECS` | keep the display and the viewer up for SECS after the run ends | to look at the last frame before the display disappears | |

Notes: `x11vnc` refuses to start when it sees a Wayland session, even for a private X display, so the script runs it with `XDG_SESSION_TYPE=x11` and `WAYLAND_DISPLAY` unset. The VNC server is localhost only with a password, so it is not reachable from the network. In `--visible=xephyr` mode the desktop display is deliberately kept for the Xephyr process alone, which is the only exception to the no desktop window rule, and it applies only when you ask for it.

## The test only capture hook

External grabbers show black for the GL output (see the dead ends below). So the capture happens inside the process.

```
python3 tests/sdl_test_hooks.py <ruffle source dir>
```

The script patches `sdl/src/main.rs` of a tree that already has the `ruffle/patches` series and adds a new file `sdl/src/test_hooks.rs`. It is idempotent (a second run says "already applied"), fails with exit 1 if an anchor matches zero or several times, and is undone with `git checkout -- sdl/src/main.rs && rm sdl/src/test_hooks.rs`. Never ship a binary built from a hooked tree: build it in a scratch checkout. It is a source patch, not a Cargo feature.

The hooked binary reads these environment variables (all optional, `pc_sdl_run.sh` and `gamescope_headless.sh` set them for you from `SHOT_AT`, `KEYS` and `EXIT_AFTER_SHOTS`):

| Variable | Meaning |
| --- | --- |
| `RUFFLE_SDL_SHOT=<dir, file or pattern>` | where PNG captures go. A directory gets `shot-001.png`, `shot-002.png`. A `%d` or `%03d` pattern is substituted. A plain file name gets the first capture as is and later ones as `<stem>-N.<ext>`. Unset means no captures |
| `RUFFLE_SDL_SHOT_AT=<list>` | comma separated capture points. A plain integer is a render frame number (1 is the first rendered frame), a number with `s` is seconds since the first render (`60,2.5s,10s`). Default 60 when `RUFFLE_SDL_SHOT` is set |
| `RUFFLE_SDL_KEYS=<file>` | a file polled once per loop wake up. Each new line is `down <key>`, `up <key>` or `tap <key>` (down now, up 150 ms later). Key names are SDL names (`Space`, `Left`, `Return`, `A`, `Escape`), lowercase and the aliases `enter`, `esc` also work. Append with `echo "down Left" >> file` |
| `RUFFLE_SDL_EXIT_AFTER_SHOTS=1` | quit once every capture point has been saved |

* The capture is a `glReadPixels` of the window's default framebuffer, taken right after the frame is rendered and before the buffer swap.
* The PNG is written by a small built in encoder that uses stored deflate blocks, so files are large (about 0.9 MB at 640x480) but the sdl crate gains no dependency. Convert with ImageMagick if you want them small.
* A `tap` holds the key for 150 ms, which is long enough for games that poll `Key.isDown` (verified with `tests/fixtures/test_keys.swf`).

The pixel pack state fix is the critical detail. Levels that use `BitmapData.colorTransform` or brightness filters make wgpu read textures back through a pixel pack buffer and leave `PIXEL_PACK_BUFFER` bound and `PACK_ROW_LENGTH` set. Then:

* the capture lands in the buffer object and the picture is all zero, and
* unbinding only the buffer lets a stale row length write past the Vec (a SIGSEGV).

So the hook saves `PIXEL_PACK_BUFFER_BINDING`, `PACK_ALIGNMENT`, `PACK_ROW_LENGTH`, `PACK_SKIP_ROWS`, `PACK_SKIP_PIXELS` and the read framebuffer binding, sets them to a clean state (0, 1, 0, 0, 0 and framebuffer 0), reads, and restores all of them (wgpu tracks that state itself).

If a capture is black, suspect the capture first. An hour was lost blaming Mesa and a fade clip before the harness was the cause.

## Gamescope headless

For GPU accelerated offscreen runs (llvmpipe is too slow for long level walks), use `tests/gamescope_headless.sh`. It takes the same positional arguments, environment variables and output files as `pc_sdl_run.sh`, but the X server is the one inside `gamescope --backend headless`, with a private runtime directory:

```
tests/gamescope_headless.sh [--headless | --visible] [--hold SECS] <ruffle_sdl> <swf> <out_dir> [seconds] [extra args]
SHOT_AT=3s,10s tests/gamescope_headless.sh ./ruffle_sdl game.swf /tmp/run2 15 --stage-scale movie
```

Notes: it renders on the real GPU through Vulkan, roughly five times faster or more than Xvfb software GL. It warns "No CAP_SYS_NICE" and prints a PipeWire connection error, both harmless. Inside it you get a `DISPLAY` and no `WAYLAND_DISPLAY`. The generic grabbers (import, x11grab) still do not work there, so use the capture hook. The compositor and the player start under `setsid` and are killed as a group with SIGKILL. The output folder has `shot-NNN.png`, `run.log` (a copy of `gamescope.log`, because the player shares gamescope's output), `gamescope.log` and `exit_code`.

Viewing flags: `--headless` is the default and the mode for automated runs. `--visible` (env `VIEW=visible`) is opt in for a person watching a test: gamescope then runs with `--backend auto`, a nested window on your desktop session, and keeps your `DISPLAY`, `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR` because the compositor needs them, so the private runtime directory isolation does not apply in this mode. Use it when you want to see the real GPU rendering path live, for example to judge smoothness. `--hold SECS` (env `HOLD`) delays the cleanup after the run. The window closes with the run, so `--hold` does not keep it open for long. The visible mode is not verified, because checking it opens a window. The headless mode is verified.

## aarch64 under qemu

To test the exact device binary (glibc floor, library resolution, startup), run it under qemu user mode with an arm64 sysroot built from Docker (Debian with `dpkg --add-architecture arm64`, qemu-user-static and arm64 SDL2, EGL, GLES, Mesa and X11 client libraries). Call it as:

```
qemu-aarch64-static -L $SYSROOT $SYSROOT/lib/ld-linux-aarch64.so.1 \
  --library-path "$PORT/lib:$SYSROOT/usr/lib/aarch64-linux-gnu" ./ruffle_sdl ...
```

with `LIBGL_ALWAYS_SOFTWARE=1 SDL_AUDIODRIVER=dummy` inside a private Xvfb. It takes minutes to the first frame, so it validates startup, glibc and memory behaviour only.

```
tests/aarch64_qemu_run.sh --make-sysroot
tests/aarch64_qemu_run.sh <aarch64 ruffle_sdl> <swf> <out_dir> [seconds] [extra args]
```

`--make-sysroot` builds a Debian bookworm arm64 sysroot once with Docker (no root, no binfmt_misc, default folder `~/.cache/ruffle-sdl-toolkit/sysroot-arm64`, override with `SYSROOT`) and takes `qemu-aarch64-static` from the same container when the host has none. The run command calls `pc_sdl_run.sh` with a wrapper that starts the binary through the sysroot loader, so the same environment variables apply (default time limit 60 seconds), plus `SYSROOT`, `QEMU`, `EXTRA_LIBS`, `QEMU_EXTRA` and `GALLIUM_DRIVER`. It does not take the `--visible` flags. Status: verified for starting a real aarch64 `ruffle_sdl` on `test_quit.swf` and exiting with code 0 (Mesa llvmpipe, about 15 seconds). Screenshots under qemu were not run, they need an aarch64 build from a hooked tree.

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

`tests/keyd.py` creates a uinput keyboard and reads lines from a FIFO: `<KEY> <ms>` (hold that long), `down <KEY>`, `up <KEY>`, `sleep <ms>` or `quit`. It writes a pid file, so you never need `pgrep -f`. Because it bypasses gptokeyb, it separates "the game misses input" from "the gptokeyb mapping is wrong". It works with or without gptokeyb running. Use `esc` (there is no `KEY_ESCAPE` in evdev, the script accepts both names). It has not been run in this toolkit's checks (it needs uinput and would type into a desktop).

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
* `tests/device.sh` takes host, password file and launcher from environment variables, never from constants. Its subcommands are `es-games`, `es-reload`, `running`, `launch`, `emukill`, `stop`, `keyd`, `keys`, `fbinfo`, `shot`, `stat`, `log` and `waitlog`. It refuses to run without `DEVICE_OK=1` and has never been run in this toolkit's checks.

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
* Frame logs: `RUFFLE_SDL_TIMING=1` (tick, render and swap share every 2 s) and `RUFFLE_FPS_LOG=1` with `RUST_LOG` including `ruffle_core::player::port_fps=info`. Wait for a log line with `tests/device.sh waitlog <regex> [timeout]`.
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

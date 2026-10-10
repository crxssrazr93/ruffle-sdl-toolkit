# Test tooling

Everything here exists so a ruffle_sdl port can be tested on a PC without touching the
handheld and without ever opening a window on your desktop. Device only steps are separated
and guarded.

| Tool | Runs on | Purpose |
| --- | --- | --- |
| `sdl_test_hooks.py` | PC | patch script that adds test only screenshot and key hooks to a ruffle_sdl source tree |
| `pc_sdl_run.sh` | PC | run a PC ruffle_sdl on a SWF on a private Xvfb, capture screenshots, feed keys |
| `gamescope_headless.sh` | PC | the same on `gamescope --backend headless` (real GPU, much faster than software GL) |
| `aarch64_qemu_run.sh` | PC | run the real aarch64 binary under qemu user mode with a Debian arm64 sysroot, on a private Xvfb |
| `keyd.py` | device (or a test machine) | uinput virtual keyboard fed from a FIFO |
| `device.sh` | PC, talks to the device | drive the port through EmulationStation's HTTP API, framebuffer screenshots, logs. Refuses to run without `DEVICE_OK=1` |
| `fixtures/` | | tiny generated test movies, see `fixtures/README.md` |

## The no desktop window rules

These are not preferences. Test runs have opened alert popups and several windows on a working
desktop before.

1. Test processes run on a private X server: Xvfb on a display number found with a lock check
   and proven alive with `xdpyinfo`, or the X server inside `gamescope --backend headless`.
   Never rootful Xwayland (it is a visible window), never the desktop's own `DISPLAY`.
2. The caller's `DISPLAY`, `WAYLAND_DISPLAY` and `XAUTHORITY` are dropped, `SDL_VIDEODRIVER=x11`
   is forced, and a private `XDG_RUNTIME_DIR` (`mktemp -d`) is used, so a late X server cannot
   make SDL fall back to the desktop's Wayland socket.
3. If the private display does not come up, the scripts abort instead of continuing.
4. Everything is stopped with SIGKILL from a `trap`, by saved pid or process group. Never
   `pkill -f` with a short or empty pattern, it kills your own shell (or every process).
5. A segfault at exit can raise a desktop crash dialog through systemd-coredump even from
   Xvfb. After runs check `coredumpctl list | tail`.
6. Memory: cap runs with `MEM_MAX=700M` (systemd-run `MemoryMax`) and keep parallelism low,
   at most two games at once. An uncapped test has OOMed a desktop session.
7. The handheld is never touched by the PC runners. `device.sh` needs `DEVICE_OK=1`, and
   copying or installing builds on a device needs the owner's approval.

## sdl_test_hooks.py

```
python3 tests/sdl_test_hooks.py <ruffle source dir>
```

Applies to `sdl/src/main.rs` of a tree that already has the `ruffle/patches` series (and any
optional patch that changes the main loop), and adds `sdl/src/test_hooks.rs`. It is idempotent
(a second run says "already applied") and fails loudly with exit 1 if an anchor matches zero or
several times. Undo with `git checkout -- sdl/src/main.rs && rm sdl/src/test_hooks.rs`. Never
ship a binary built from a hooked tree, build the hooked binary in a scratch checkout.

Environment variables of the hooked binary:

| Variable | Meaning |
| --- | --- |
| `RUFFLE_SDL_SHOT=<dir or file or pattern>` | where to write PNG captures. A directory gets `shot-001.png`, `shot-002.png`. A `%d` or `%03d` pattern is substituted. A plain file name gets the first capture as is and later ones as `<stem>-N.<ext>`. Unset means no captures |
| `RUFFLE_SDL_SHOT_AT=<list>` | comma separated capture points: a plain integer is a render frame number, a number with `s` is seconds since the first render (`60,2.5s,10s`). Default 60 when `RUFFLE_SDL_SHOT` is set |
| `RUFFLE_SDL_KEYS=<file>` | a file polled once per loop wake up. New lines `down <key>`, `up <key>` or `tap <key>` (down now, up 150 ms later) become key events. Key names are SDL names (`Space`, `Left`, `Return`, `A`, `Escape`), lowercase and `enter`, `esc` also work. Appending with `echo "down Left" >> file` is the intended use |
| `RUFFLE_SDL_EXIT_AFTER_SHOTS=1` | quit once every capture point has been saved |

Captures are PNG written by a tiny built in encoder (stored deflate blocks, so it is large:
about 0.9 MB at 640x480, and the sdl crate gains no dependency). Convert with ImageMagick if
you want them small.

Why a hook at all: external grabbers (`import -window root`, `ffmpeg -f x11grab`, `xwd`) return
all black frames for this GL output on Xvfb and in gamescope headless, even with GLX and
software GL. The hook reads the window's framebuffer with `glReadPixels` right after the frame
is rendered and before the buffer swap.

Pitfall inside the hook: wgpu leaves the GL pixel pack state set after a texture readback
(BitmapData colour transforms and filters trigger one). With a pixel pack buffer still bound
the capture is all black, and with only the stale row length left `glReadPixels` writes past the
end of the buffer and crashes. The hook therefore saves `PIXEL_PACK_BUFFER` binding,
`PACK_ALIGNMENT`, `PACK_ROW_LENGTH`, `PACK_SKIP_ROWS`, `PACK_SKIP_PIXELS` and the read
framebuffer, sets them to a clean state for its own read, and restores all of them. A black
capture is much more often a bug in the capture than in the player: suspect the harness first.

## pc_sdl_run.sh

```
tests/pc_sdl_run.sh <ruffle_sdl> <swf> <out_dir> [seconds] [extra ruffle_sdl args]
RES=640x480 SHOT_AT=2s,4s KEYS="1:tap Space;3:down Left;4:up Left" MEM_MAX=700M \
  tests/pc_sdl_run.sh ./ruffle_sdl tests/fixtures/test_loop.swf /tmp/run1 6
```

Starts Xvfb with GLX on a free display number, runs the binary with `SDL_VIDEO_X11_FORCE_EGL=1`,
`LIBGL_ALWAYS_SOFTWARE=1` (Mesa software GL), `SDL_AUDIODRIVER=dummy`, `--width`, `--height` and
a save directory inside the output folder, waits `seconds` (default 6) or for the process to end
by itself, then kills it with SIGKILL. The output folder gets `shot-NNN.png`, `run.log` (stdout
and stderr, so trace output and the relaunch marker line are in it), `xvfb.log`, `exit_code`
(the exit status, or `killed` when the time ran out) and `saves/`. Extra arguments go to
ruffle_sdl before the SWF path, for example `--stage-scale movie --quality low -Pkey=value`.
`KEYS` is `<seconds after start>:<line>` items separated by semicolons.
`EXIT_AFTER_SHOTS=1` ends the run as soon as the captures are saved.

A binary without the hooks still runs (useful for exit code and relaunch marker tests), it just
produces no screenshots.

## gamescope_headless.sh

Same arguments, environment and outputs as `pc_sdl_run.sh`, but the X server is the one inside
`gamescope --backend headless` with a private `XDG_RUNTIME_DIR`. It renders on the real GPU
through Vulkan, which was five times or more faster than Xvfb software GL for GL heavy movies
(Xvfb got through 3 of 15 test rooms per run). The compositor and the player are started
under `setsid` and killed as a group. gamescope prints "No CAP_SYS_NICE" and a PipeWire
connection error in headless mode, both harmless. External grabbers do not work here either
(`import` fails with "missing an image filename"), use the hook.

## aarch64_qemu_run.sh

```
tests/aarch64_qemu_run.sh --make-sysroot
tests/aarch64_qemu_run.sh <aarch64 ruffle_sdl> <swf> <out_dir> [seconds] [extra args]
```

Runs the exact binary that ships to handhelds, so the glibc floor, linked libraries and startup
are tested, not just the PC build. The sysroot is a Debian bookworm arm64 userland built once
with Docker, without root and without binfmt_misc (default
`~/.cache/ruffle-sdl-toolkit/sysroot-arm64`, override with `SYSROOT`). The same container
provides `qemu-aarch64-static` when the host has none. The script then calls `pc_sdl_run.sh`
with a wrapper that starts the binary through the sysroot's loader:

```
qemu-aarch64-static -L SYSROOT SYSROOT/lib/ld-linux-aarch64.so.1 --library-path LIBS BINARY
```

Things learned the hard way:

* Exec'ing the binary directly exits silently when the loader symlink dangles (Debian's
  `/lib` to `/usr/lib` merge is not preserved by a copy). Always go through `ld-linux-aarch64.so.1`
  with `--library-path`, and keep the `lib/aarch64-linux-gnu` and `lib/ld-linux-aarch64.so.1`
  symlinks in the sysroot. Debug with `QEMU_EXTRA=-strace` and `LD_DEBUG=libs`.
* SDL on X11 loads desktop GLX `libGL` before creating a GLES context, even for a GLES only
  app. The sysroot needs Mesa GLX (`libgl1 libglx-mesa0 libopengl0`) plus EGL, GLES and the Mesa
  DRI drivers. `SDL_VIDEO_X11_FORCE_EGL=1` alone did not produce a window under Xvfb.
* Emulated software GL takes minutes to the first frame. Use it for behaviour, startup and
  memory, never for speed. If llvmpipe's JIT misbehaves under qemu try `GALLIUM_DRIVER=softpipe`.
* Mesa on the PC is not a stand in for the handheld GPU driver. Paths that depend on the vendor
  string, shader comment placement or button order have passed on Mesa and broken on Mali.
* To take screenshots the aarch64 build must come from a tree patched with `sdl_test_hooks.py`.
  Do not ship that binary.

Status: verified, see "What has been verified" below.

## keyd.py

```
python3 keyd.py [--fifo /tmp/keyd/keys] [--name keyd-test-keys]
echo "right 2000" > /tmp/keyd/keys        # hold Right for 2 seconds
printf 'sleep 500\nenter 200\n' > /tmp/keyd/keys
```

A virtual keyboard created with uinput and fed from a FIFO, for the device (or a dedicated test
machine). It separates "the game ignores the key" from "the gamepad mapper is wrong": the events
come in as a real keyboard, with or without the mapper running. Lines are `<KEY> <ms>` (hold),
`down <KEY>`, `up <KEY>`, `sleep <ms>` and `quit`. It needs python-evdev and `/dev/uinput`. It writes a pid
file next to the FIFO, stop it with `kill $(cat /tmp/keyd/keyd.pid)`.

uinput devices are machine global. Do not run keyd on your desktop during tests, it would type
into whatever has focus. For headless PC runs use `RUFFLE_SDL_KEYS` (in process, no devices).
Evdev has no `KEY_ESCAPE`, the name is `esc` (the script accepts both).

## device.sh

```
DEVICE_OK=1 DEVICE_HOST=handheld DEVICE_LAUNCHER=/userdata/roms/ports/MYGAME.sh \
  DEVICE_DIR=/userdata/roms/ports/mygame tests/device.sh launch
```

Subcommands: `es-games`, `es-reload`, `running`, `launch`, `emukill`, `stop`, `keyd`, `keys`,
`fbinfo`, `shot <name>`, `stat`, `log`, `waitlog <regex> [timeout]`. Settings all come from
`DEVICE_*` variables (host, user, password file, launcher path, port folder, ES URL, framebuffer
name), none are hard coded. It never runs unless `DEVICE_OK=1` is set and it is never executed
by the toolkit's own checks. The header of the script lists the pitfalls, summarised here:

* ES serves a JSON game list at `/systems/ports/games`, takes `GET /reloadgames`,
  `POST /launch` with the plain launcher path as the body, `GET /runningGame` and
  `GET /emukill`, on port 1234.
* ES caches its game list: reload after adding a launcher, wait about 10 seconds and check
  the list. A `/launch` for a path ES does not list starts the currently selected game instead,
  so `launch` checks the list first. Paths with spaces travel through stdin to avoid shell
  quoting (`DEVICE_LAUNCH_ENCODE=1` percent encodes the body if a firmware wants that).
* Launch through ES, not an ssh shell, so the same wrapper, gamepad mapper, power mode and
  patcher screen run as for a player. The patcher waits for a key press at the start and at
  its closing dialogue, and while it waits a new launch is ignored.
* Stale logs and screenshots are the classic false pass. `launch` records the log's line count,
  `waitlog` only reads later lines, `shot` deletes the old file first. Do not trust mtimes
  on exFAT.
* `pkill -f` and `pgrep -f` match their own shell and the ssh command line. Use `pidof`, pid
  files and exact names, and guard any kill loop against an empty pattern.
* Framebuffer screenshot: fbgrab shows white for GL output. The script reads the raw device,
  detects `virtual_size`, `bits_per_pixel`, `stride`, the visible mode and the pan offset from
  `/sys/class/graphics/fb0`, and crops the visible page of the double buffered framebuffer
  (BGRA for 32 bits).
* Key presses after the game exits land in ES and can set a filter. Only inject while
  `running` names a game.
* Do not overwrite a running launcher script (bash reads scripts incrementally), and test the
  real exit path (firmware hotkey, exit codes 143 and 137), not only `emukill`.

## What has been verified

On the author's PC (Linux, Mesa, Xvfb, gamescope 3.16):

* `sdl_test_hooks.py` applied to a tree with the series, a second run reports already applied,
  an invalid tree fails with exit 1, and `cargo check -p ruffle_sdl` passes.
* `pc_sdl_run.sh` and `gamescope_headless.sh` ran the fixtures: the start trace is logged,
  `test_quit.swf` exits with code 0 by itself, `test_relaunch.swf` prints the relaunch marker
  line, `test_loop.swf` is stopped by the time limit, no stray processes or lock files remain.
* `aarch64_qemu_run.sh` built the sysroot with Docker (no root, no binfmt, qemu 7.2 taken from the
  container since the host had none) and ran a real aarch64 ruffle_sdl on `test_quit.swf`: Mesa 22.3
  llvmpipe came up, the trace lines appeared and the player quit with code 0 in about 15 seconds.
  Screenshots under qemu were not run (that needs an aarch64 build from a hooked tree).
* Hook features on x86_64 Xvfb and gamescope: PNG captures by frame number and by seconds
  (colours and orientation checked by eye), `EXIT_AFTER_SHOTS`, key injection (`down`, `up` and
  `tap` seen by the movie through `Key.isDown` with `test_keys.swf`).
* `shellcheck -S warning` (Docker image) is clean for the four shell scripts.
* `bash -n` on every shell script, `py_compile` on every Python file.

Not run here: `device.sh` and `keyd.py` (they need a device and uinput, and keyd would type into
the desktop). Their syntax is checked only.

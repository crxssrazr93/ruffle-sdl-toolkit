# 12. Dead ends

## When you need this

Read this before you spend time on an idea that already failed. Every entry says what was tried, the evidence, and what to try instead. Entries are grouped by area. Where a topic has a full explanation in another document, the entry is short and points there.

## Performance and build

### Fat LTO

* Tried: link time optimisation for the aarch64 `ruffle_sdl` build.
* Evidence: no measurable speed gain and no size gain, with much longer builds. The build script comment reads "LTO measured no gain".
* Instead: keep the default release profile with `target-cpu=cortex-a53`. Spend the time on the batching and script side work in `06-performance.md`.

### Capping drawWithQuality at the stage quality

* Tried: forcing `BitmapData.drawWithQuality` to use the stage quality instead of the quality the game asked for, to save GPU work.
* Evidence: slower, 13.7 fps against 15.5 fps. The Mali GPU handles multisampling cheaply, and the cap added work elsewhere.
* Instead: leave the game's quality alone. Reduce fill rate with `--render-size`, and reduce submits and passes (patches 0002 and 0011).

### A smaller Stage3D back buffer

* Tried: dividing the Stage3D back buffer size (an experiment variable, `PORT_BB_DIV`).
* Evidence: no gain. The cost was in submits, draws and scripts, not in pixels.
* Instead: measure with `RUFFLE_SDL_TIMING` first. If render share is high, look at passes and draws (`PM_GPUSTAT`), not resolution of the back buffer.

### A GPU submission thread on the Mali blob

* Tried: a worker thread that does `finish`, `submit`, `present` and acquires the next swap chain texture, while the main thread runs scripts. The experiment was a 10 file, 837 line diff plus a 126 line worker. Queue touching code had to drain the worker first, `wait_for_gpu` polled `device.poll(PollType::Poll)` every 500 microseconds, and a panicking job aborted the process.
* Evidence: it halved main thread time on desktop Mesa, but on the Mali blob (under Westonpack and under ruffle_sdl) it failed in three ways:
  1. `glClientWaitSync` returns 0 immediately, so fence waits fail. wgpu reports a `GpuWaitTimeout` on `Surface::configure`. The workaround `GlFenceBehavior::AutoFinish` (`--gl-finish`) does not make the threaded design safe.
  2. Creating the window surface renderbuffer on the second thread fails.
  3. Buffers created on the main thread while the worker is submitting come out invalid (shape vertex buffers), even with wgpu-hal's context mutex.
* Instead: keep submit, present and configure single threaded and on the main thread. That is the only reliable path with an external SDL GL context. If you want more parallelism, reduce the work (batching, deferred uploads) or look at a record and replay GL thread of the kind another native port used on fbdev EGL (it recorded commands into an 8 MB ring, a different stack and design). Do not retry the wgpu worker without a new idea.

### Shrinking the level cache bitmaps to 0.5x

* Tried: halving the game's own bitmap cache resolution to save memory.
* Evidence: about 75 MB and 3 fps saved, but the level art was visibly blockier. The right fix was 1.5x down to 1x (not 0.5x) where a game oversampled.
* Instead: measure texels per art pixel first, only remove oversampling, and keep fidelity. See `05-memory.md`.

### Waiting for upstream memory fixes

* Tried or considered: relying on upstream PR #23071 (garbage collectable movie libraries) instead of relaunching.
* Evidence: the PR was open, conflicting, large (+1144 and -693 lines over 51 files) and idle for months. Issue #24864 is open.
* Instead: relaunch per sub movie plus the memory patches. Re-evaluate if upstream lands a fix. See `05-memory.md`.

## Delivery and launcher

### Weston based compositor path (Westonpack)

* Tried: desktop Ruffle inside a Weston and X11 compositor wrapper.
* Evidence: a runtime squashfs download, extra memory, `XDG_RUNTIME_DIR` replaced (ALSA lost PipeWire), a preload banner that corrupts pipes, evaluation of `VAR=value` arguments, control files sourced again so exported variables were overwritten, and an exit code that is always 0. It also ran out of memory on 1 GB devices in heavy levels.
* Instead: `ruffle_sdl` (see `04-ruffle-sdl.md`).

### Version only prepared stamp

* Tried: a marker that stores only the patch version.
* Evidence: it does not notice a changed or replaced game file. On firmware without `stat` an empty stamp equalled an empty stamp, so patching was skipped.
* Instead: version plus size and modification time lines made with `ls -lnL` and `date -r`. See `11-launcher-packaging.md`.

### Fallback patcher when PortMaster's patcher is missing

* Tried: the launcher falling back to its own patch step.
* Instead: use PortMaster's standard patcher. See `11-launcher-packaging.md`.

### Launcher killing gptokeyb after the patcher

* Tried: an extra `kill -9` of gptokeyb after patching. It was removed in review as non standard. Note that another port's standard patcher block does include such a line, so check the current standard when you write a launcher.

### Custom log helper and log rotation in a release launcher

* Tried: a bespoke logger and rotating logs.
* Evidence: non standard, removed in review for the release. A testing build with `VERBOSE_LOGS=1` keeps `log.txt` and `log.prev.txt` (see `11-launcher-packaging.md`).

### Forcing NO_PANFROST_BYPASS off the standard path

* Instead: stay on the standard path. See `11-launcher-packaging.md`.

### Stable symlink path to make saves firmware independent

* Evidence: Ruffle canonicalizes symlinks, so the saves directory changed with the real path anyway. See `11-launcher-packaging.md`.

### Wrapper reading Ruffle output through sed or tail

* Evidence: a preloaded library's banner was re-read as a relaunch target and caused a respawn loop. Instead: bash builtins only in the wrapper (see `05-memory.md`).

## Input

### Mouse driven overlay menu without a visible cursor

* Tried: a menu opened on mouse motion, with the pointer driven by gamepad mouse emulation.
* Evidence: ruffle_sdl hides the system cursor, so nothing was visible. Replaced by L1 and L2 volume steps.
* Instead: one of the software cursor options in `09-input.md` (the optional front end overlay patch 0100, an SDL colour cursor, or a shell side overlay).

### Mouse emulation in the gptk file with no visible cursor

* Evidence: same cause. Dropped. See `09-input.md`.

### Mapping a quality key (Q) when the game uses Q to quit a paused level

* Evidence: soft lock. Check every game key before mapping. See `09-input.md`.

### Comment only gptk files and firmware specific A/B swap blocks

* Instead: see `09-input.md` for the working layout (buttons by SDL position).

## Screen and aspect

### Stock desktop Ruffle for extend testing

* Evidence: it did not reproduce `--stage-scale movie`. Build an x86 `ruffle_sdl`. See `08-screen-aspect.md`.

### Capping extend at 4:3 or fit as a workaround for a death bug at 1:1

* Evidence: the root cause was a constant in the shell. Fix the cause. See `08-screen-aspect.md`.

### Shell quality and Window buttons (fullScreenSourceRect) under Ruffle

* Evidence: they do nothing useful under Ruffle. See `08-screen-aspect.md`.

### Desktop Ruffle `--letterbox on` for black bars, and a black stage backdrop

* Evidence: the bars were the stage colour, and a black backdrop hid a black character. See `08-screen-aspect.md`.

## Testing

All of these are explained in `10-testing.md`. The short list:

* Pixel diff to prove a quality toggle (idle noise equals the effect, 100 to 270 pixels). Use a log line or a static scene.
* Analog stick injection into the real pad (the driver overwrites the axis on the next poll), and a new uinput mouse made after launch (the game does not see it). Use gptokeyb's fake keyboard node.
* External screen grabbers (`import`, ffmpeg `x11grab`) on Xvfb or gamescope for GL output come out black. Use an in process `glReadPixels` hook.
* `xdotool` focus and keys against the SDL window in Xvfb.
* Blaming Mesa or the game for black captures (it was the capture hook's pixel pack state).
* Ending tests with the `emukill` helper (hides hotkey kill bugs). Use the real hotkey.
* Screenshot brightness or HUD heuristics as readiness waits. Wait for a log line.
* `pkill -f` or `pgrep -f` in remote test scripts, with a short pattern (kills the shell running the script).
* `parecord` for audio capture on Knulli (0 bytes).
* Rootful Xwayland for offscreen tests (shows a window on the desktop), and `ulimit -c 0` to suppress core dump popups.
* Running the aarch64 binary directly under qemu (it exits silently). Invoke the sysroot's `ld-linux-aarch64.so.1`.
* `SDL_VIDEO_X11_FORCE_EGL=1` alone under qemu and Xvfb (another SDL app needed Mesa GLX in the sysroot). Untested for ruffle_sdl itself.
* Reading only the head of a log.

## Pitfalls

* Several of these were dead ends only in one environment (the GPU thread is the clearest). The entry says exactly what failed so you can tell whether your device differs.
* Do not retry a dead end by changing a parameter. If you retry, change the assumption (the GPU thread entry gives the failing assumptions: fence waits work, surfaces can be made off the main thread, buffers can be created during a submit).
* Record any new dead end here with the evidence and the alternative.

## See also

* `04-ruffle-sdl.md`, `05-memory.md`, `06-performance.md`
* `08-screen-aspect.md`, `09-input.md`, `10-testing.md`, `11-launcher-packaging.md`
* `env-vars.md`

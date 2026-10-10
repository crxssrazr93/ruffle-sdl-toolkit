# 04. ruffle_sdl: Ruffle on the firmware's SDL2 and GLES 3

## When you need this

Read this when you are about to build, run, debug or ship the `ruffle_sdl` binary: the Ruffle front end that talks straight to the SDL2 library and the GLES 3 driver already present on a handheld Linux firmware. It covers what the binary is, how it draws, its command line, how to build it for aarch64 against an old glibc, how to run it on a PC, what the device must provide, and the older desktop Ruffle plus Weston path (Westonpack) that it replaced.

## What ruffle_sdl is

`ruffle_sdl` is a new workspace crate (`sdl/`) added to Ruffle by patch 0006. It replaces the combination of "desktop Ruffle inside a Weston/X11 compositor wrapper" with one small native binary.

* It links only `libSDL2`, `libasound` and glibc (plus libdl, libgcc_s, libpthread, libm). No X11, no Wayland, no Weston, no OpenSSL, no fontconfig, no OpenH264.
* The stripped aarch64 binary is about 16.7 MB (the desktop build it replaced was 32 to 34 MB). The glibc floor is 2.30 (see below).
* It uses the SDL2 and GLES 3.0 the firmware already ships. Knulli ships SDL 2.32.8, muOS 2601 ships SDL 2.28.5, and the supported floor is SDL 2.0.10.
* Source layout: `sdl/src/main.rs` (window, GL, loop, input, CLI), `keys.rs` (SDL scancode and keycode to Ruffle key, with left, right and numpad locations), `audio.rs` (SDL audio with fallbacks).
* Saves use the same storage code as desktop Ruffle (`saves/localhost/<name>.sol`), so switching front ends keeps progress.

Credit: the front end (patch 0006) and its SDL 2.0.10 fix (0012) are by Knifethrower. See `../CREDITS.md`.

### How the video path works

Ruffle renders with wgpu. A normal wgpu GL backend would open its own EGL display and context, which on Mesa costs about 80 MB and is not what we want on a 1 GB device. Instead:

1. SDL creates the window and the GLES 3.0 context (attributes: GLES 3.0, RGB 8/8/8, no alpha, no depth, no stencil, double buffered, swap interval 1). The system cursor is hidden.
2. `glow::Context::from_loader_function` wraps `SDL_GL_GetProcAddress`.
3. wgpu is created with `Backends::empty()` (no backend of its own), and `wgpu_hal::gles::Adapter::new_external` plus `create_adapter_from_hal` turn SDL's context into a wgpu adapter. There is no EGL or surface code of our own.
4. Ruffle draws into one texture. `submit()` calls `queue.submit` and then `glBlitFramebuffer` to the default framebuffer, flipped in Y, aspect fitted (NEAREST at 1:1, LINEAR otherwise), with the bars cleared to black.
5. Everything runs on the main thread, because an external GL context is bound to it.

If the driver cannot do this the binary prints `wgpu could not use the GLES context (needs GLES 3.0)`.

The startup log proves which driver is in use. A healthy device line looks like `GL: Mali-G31 / OpenGL ES 3.2 v1.r20p0` followed by a wgpu adapter line naming the same GPU. A software renderer name there means you are not on the vendor GLES path.

Known good dependency set on Ruffle commit `dcc85a1b`: `sdl2` 0.37, `glow` 0.17, `wgpu-hal` 30.0.1 (gles). Bump them together, because the wgpu-hal and glow types must match.

### Mali blob crash and WGPU_DISCARD_HAL_LABELS

Mali blob drivers crash inside `glPushDebugGroup` when wgpu emits debug labels (wgpu issue gfx-rs/wgpu#8937). `ruffle_sdl` sets `InstanceFlags::DISCARD_HAL_LABELS` in code, so you do not need to export anything. The environment variable `WGPU_DISCARD_HAL_LABELS=1` is the same switch for stock desktop Ruffle, which is why the Westonpack launcher exported it. ruffle_sdl also builds its instance with wgpu's own `from_env` helpers, so other `WGPU_*` options (GL backend options) are still honoured.

### --gl-finish

Some drivers return from `glClientWaitSync` without waiting (the Mali blob returns 0 immediately). `--gl-finish` sets `GlFenceBehavior::AutoFinish`, replacing fence waits with `glFinish`. Try it if you see wgpu GPU wait timeouts or tearing of stale frames. It is off by default.

### SDL 2.0.10 stub (patch 0012)

The `sdl2` crate 0.37 references `SDL_Metal_DestroyView`, which exists only from SDL 2.0.12. With immediate symbol binding that single missing symbol (one of about 26 SDL imports) stops the binary on Ubuntu 20.04 era firmware with SDL 2.0.10. The fix is a local no-op definition:

```rust
#[unsafe(no_mangle)]
pub extern "C" fn SDL_Metal_DestroyView(_: *mut c_void) {}
```

To find this kind of problem for any SDL binary, list its undefined SDL symbols and compare them with the exports of the oldest `libSDL2` you support (`nm -D --undefined-only` against `nm -D --defined-only`).

### Audio, loading and backends

* Audio tries SDL first (44100 Hz, 2 channels, 1024 samples, i16, Ruffle's mixer in the SDL callback, so it follows whatever output the firmware configured), then cpal on ALSA, then a null backend with the log line `No audio: SDL: ...; ALSA: ...`.
* Loading uses a null navigator with a base path (local files relative to the SWF folder only). `Loader`, `URLLoader` and `loadMovie` work for local files. There is no network stack (no reqwest, tokio or OpenSSL).
* Video is the software backend. There is no script timeout (`max_execution_duration` is unlimited). The movie autoplays fullscreen.
* The main loop waits for events with a timeout until the next frame (no busy loop) and renders only when the player says it needs a render.
* `fscommand("quit")` ends the loop. `fscommand("relaunch", args)` prints `RUFFLE_RELAUNCH <args>` on stdout, flushes and quits, so a wrapper can restart the binary. See `05-memory.md`.
* Printable keys are passed as the unshifted key character with shift and caps lock applied, so `Key.getCode` and `Key.keyCode` match desktop Ruffle.
* Patch 0013 adds a minimum key hold (default 100 ms): a key release that arrives sooner than that after its press is held back. gptokeyb sends some buttons as a press and release about 16 ms apart, and a game polling `Key.isDown` once per frame would miss them. See `09-input.md` and `env-vars.md` (`RUFFLE_MIN_KEY_HOLD_MS`).

## Command line

```
ruffle_sdl <swf>
    --save-directory DIR          required, where shared objects are written
    [--width W --height H]        windowed; without --width it is fullscreen_desktop
    [-q | --quality low]          low (default), medium, high, best
    [--player-runtime air]        air (default) or flash_player
    [-Pkey=value ...]             flashvars, repeatable
    [--render-size WxH]           draw at this size and scale up (see below)
    [--gl-finish]                 glFinish instead of fence waits
    [--stage-scale fit|movie]     fit is the default
```

* `--render-size 640x480` draws the movie at that resolution and blits it scaled, letterboxed in the centre. Mouse coordinates are mapped back through the same transform. It cuts fill rate on weak GPUs and is the first thing to try when the GPU is the bottleneck.
* `--stage-scale fit` forces letterbox on, ShowAll scaling and the default alignment over whatever the movie asks for. Desktop games that request top left and no scaling would otherwise sit in a corner. `--stage-scale movie` keeps the movie's own scale mode and alignment, for a shell that lays itself out (use this when the SWF does its own resize handling). See `08-screen-aspect.md`.
* `-q low` (no anti aliasing) is the default and what handhelds want.
* Equivalents of old desktop Ruffle flags: `--player-runtime air` is the default, `--letterbox off` is `--stage-scale movie`, `--quality <q>` carries over, `--filesystem-access-mode allow` is implicit (local files are always allowed), network is always denied, and flashvars become `-Pkey=value`.

The environment variables the binary reads are listed in `env-vars.md`. The PC only hint `SDL_VIDEO_X11_FORCE_EGL=1` is set by the binary itself, because Mesa on X11 hands out GLES contexts only through EGL.

## Building for aarch64

All scripts live in `ruffle/` (see `../ruffle/README.md`).

1. `ruffle/fetch.sh <dir>` clones Ruffle, checks out the commit in `ruffle/PIN` (`dcc85a1b`, "Release 0.7.0-nightly.2026.10.4") and applies the series with `git am`. Set `RUFFLE_REPO` to clone from a mirror. Set `WITH_OPTIONAL="0100"` to also apply optional patches such as the software cursor.
2. `ruffle/build-aarch64.sh <src> <out>` builds inside Docker and prints the maximum `GLIBC_` symbol and the `NEEDED` libraries.
3. `ruffle/build-aarch64-native.sh <src> <out>` is the Docker free variant (clang, lld and a Debian bullseye arm64 sysroot made with debootstrap and holding `libsdl2-dev` and `libasound2-dev`).
4. `ruffle/build-x86_64.sh <src> <out>` builds a PC binary for the Xvfb harness.

### The Docker cross toolchain

The image is `ubuntu:20.04` (glibc 2.31) with amd64 plus arm64 multiarch, `gcc-aarch64-linux-gnu`, `libc6-dev-arm64-cross`, `libasound2-dev:arm64`, `libudev-dev:arm64`, `libsdl2-dev:arm64`, clang, cmake, nasm and a minimal rustup with the aarch64 target. The build command is:

```
cargo build --release -p ruffle_sdl --target aarch64-unknown-linux-gnu --features lzma
```

with `RUSTFLAGS="-C target-cpu=cortex-a53 -L native=/usr/lib/aarch64-linux-gnu"`. The `-L` is needed because `sdl2-sys` emits `-lSDL2` without pkg-config. The result is stripped with `aarch64-linux-gnu-strip`. `--features lzma` is required for LZMA compressed (ZWS) SWFs. A clean build takes roughly 5 to 9 minutes depending on the cargo cache.

`target-cpu=cortex-a53` matches the reference hardware (Allwinner H700, four Cortex A53 cores at up to 1.5 GHz, Mali G31, 1 GB RAM). Change it if you target another core.

### The glibc floor

The build environment has glibc 2.31, but the shipped binary needs at most `GLIBC_2.30`, and the PortMaster metadata says `min_glibc "2.30"`. Two sources call this a "2.31 floor". Treat 2.31 as the build image version and 2.30 as the measured symbol floor. The build script should fail when the maximum symbol exceeds 2.30. Check it yourself with:

```
objdump -T ruffle_sdl | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1
readelf -d ruffle_sdl | grep NEEDED
```

Expected NEEDED: `libasound.so.2`, `libSDL2-2.0.so.0`, `libdl.so.2`, `libgcc_s.so.1`, `libpthread.so.0`, `libm.so.6`, `libc.so.6`. Anything else (libstdc++, OpenSSL, GL, fontconfig, freetype) means the build picked up the wrong dependency or feature set.

`mallinfo2` does not exist before glibc 2.33, so the memory accounting resolves it at runtime with `dlsym` and falls back to `mallinfo`.

The official Ruffle nightly aarch64 build is not usable on these devices. It needs `GLIBC_2.39` and links `libfreetype`, `libssl.so.3` and `libcrypto.so.3`, so you must build against an old glibc yourself.

## Running on a PC

* Build with `ruffle/build-x86_64.sh`. Use a dedicated `CARGO_TARGET_DIR` and build from inside the Ruffle tree. Running `cargo` from another directory silently builds into a different target folder, and you then test a stale binary.
* A PC build is for behaviour, layout and memory, not speed.
* Under Xvfb use `SDL_VIDEODRIVER=x11`, and a software GL such as `LIBGL_ALWAYS_SOFTWARE=1`. `SDL_VIDEO_X11_FORCE_EGL=1` is set by the binary. Use `SDL_AUDIODRIVER=dummy` to rule out audio.
* To run the real aarch64 binary on a PC, use qemu user mode with an arm64 Debian sysroot (see `10-testing.md`). Invoke it through the sysroot's `ld-linux-aarch64.so.1` explicitly, otherwise it exits silently. This tests the glibc floor, linked libraries and startup, but takes minutes to reach a first frame.
* Never test with a window on your desktop. See `10-testing.md` for the Xvfb and headless gamescope harnesses.

## Runtime requirements on the device

* aarch64, GLES 3.0 or newer, SDL2 2.0.10 or newer, glibc 2.30 or newer, ALSA.
* Why GLES and not Vulkan: the H700 `libmali` r20p0 exports no `vk*` symbols even though its ICD json claims Vulkan 1.0, PanVK is not conformant on G31, and ROCKNIX on that SoC ships Panfrost GL only. Mali also has no BC or S3TC texture compression.
* Tested firmware matrix: Knulli and muOS (Mali blob), ROCKNIX (Panfrost and libmali), AmberELEC and dArkOS. Screens from 480x320 up to about 720x720 were tested. 1080p was never measured on real hardware.
* Memory budget: about 973 MB total on a 1 GB H700, around 720 MB available after boot on Knulli with the front end running. Plan for far less. See `05-memory.md`.

## The earlier Westonpack path (documented fallback)

Before `ruffle_sdl` the port ran desktop Ruffle inside the PortMaster Weston wrapper ("Westonpack"). Keep this only as a fallback or a reference.

Build: `cargo build --release -p ruffle_desktop --target aarch64-unknown-linux-gnu --no-default-features --features software_video,lzma`, with `target-cpu=cortex-a53`. The desktop crate was slimmed: `ruffle_frontend_utils` without default features and with `cpal`, `fs`, `navigator` and `rustls-tls` (rustls instead of OpenSSL, so no `libssl.so.N` mismatch across firmwares), no fontconfig or freetype, no OpenH264 download. The result is 32 to 34 MB stripped with NEEDED limited to libdl, libasound, libudev, libgcc_s, libpthread, libm, libc and GLIBC 2.30. Do the `Cargo.toml` change as a committed patch or a `--config` override, not by editing the tree with sed in a build script.

Launch: mount the `weston_pkg` squashfs (harbourmaster `runtime_check` if missing), run `westonwrap.sh headless noop kiosk $GL_LIBRARY`, with `WGPU_DISCARD_HAL_LABELS=1`, `WAYLAND_DISPLAY=` empty so it uses X11 through crusty, `CRUSTY_BLOCK_INPUT=1` (gptokeyb already provides keys), the real `XDG_RUNTIME_DIR` passed through so ALSA can reach PipeWire, and on ROCKNIX Panfrost a `libcrusty.so` preload with GL mode `system` if the screen stays black. Desktop flags: `--no-gui --fullscreen -g gl -p low --gamemode off --player-runtime air --filesystem-access-mode allow --letterbox off --width W --height H`.

Why it was replaced: on a 1 GB device with no swap it was OOM killed in heavy AS2 levels (281 MB heap plus 511 MB Mali, 369 plus 430), while `ruffle_sdl` with the memory patches peaked at 227 and 302 MB at 30 fps. It also needed a 33 MB binary, a squashfs runtime download and an extra compositor process.

## Credits

The `ruffle_sdl` front end, the SDL 2.0.10 fix and the memory patches are by Knifethrower. The batching, texture, mouse pick, key hold and relaunch work, the shell tooling and these docs are by crxssrazr93. Ruffle is MIT or Apache 2.0.

## Pitfalls

* Stale binary on PC: build from inside the Ruffle tree with an explicit `CARGO_TARGET_DIR`.
* Root owned Docker output: `chown -R $(id -u):$(id -g)` the output, and never share a root owned `CARGO_TARGET_DIR` with a host build (cargo fails with permission denied on `.cargo-build-lock`).
* Missing `--features lzma` makes ZWS SWFs fail to load.
* A binary that shows `GLIBC_2.31` or higher will not start on older firmware. Gate the build.
* The relaunch wrapper does not change the process name. gptokeyb's hotkey runs `pkill -f ruffle_sdl`, which also matches the wrapper (it has `ruffle_sdl` in its arguments) and so ends the relaunch loop. That is desired, but keep the kill name out of your log path.
* ruffle_sdl hides the system cursor, so a menu that needs a visible mouse pointer is unusable. See the software cursor options in `09-input.md`.
* Westonpack: `westonwrap` evaluates its arguments (a `VAR=value` with spaces breaks, replace spaces with dots) and always exits 0, so detect failures by reading its log. A library preloaded into every process can print a banner that corrupts a piped wrapper.
* Harmless build noise: `VERGEN_GIT_* set to default` when the source has no `.git`, unused imports, Docker legacy builder notice.

## See also

* `05-memory.md` for relaunch and memory patches
* `06-performance.md` for profiling and speed
* `08-screen-aspect.md` for `--stage-scale` and `--render-size`
* `09-input.md` for key hold and the software cursor
* `10-testing.md` for Xvfb, qemu and device harnesses
* `env-vars.md` for every switch
* `12-dead-ends.md`
* `../ruffle/README.md` for the patch series

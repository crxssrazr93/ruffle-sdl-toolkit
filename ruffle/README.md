# Ruffle patch series

Patches that turn upstream Ruffle into `ruffle_sdl`, a small SDL2 and GLES 3 front end with the speed and memory work needed to run Flash/AIR games on low end ARM handhelds. The series applies with `git am` on the upstream commit named in `PIN` (a Ruffle nightly, release 0.7.0-nightly.2026.10.4).

Ruffle itself is MIT OR Apache-2.0. The patches stay under that license with each patch's original author kept.

## Files

| File | Purpose |
|-|-|
| `PIN` | Full 40 character upstream commit the series applies to |
| `series` | Patch file names in apply order (`#` comments allowed) |
| `patches/` | The default series, 0001 to 0014 |
| `optional/` | Patches that are not in the default series (for example 0100, the software cursor overlay) |
| `fetch.sh [dir]` | Clone the pin and `git am` the series. `RUFFLE_REPO` overrides the clone source, `WITH_OPTIONAL="0100"` adds optional patches |
| `build-aarch64.sh <src> <out>` | Docker cross build, glibc 2.30 floor (ubuntu:20.04). Prints the max GLIBC version and NEEDED libraries |
| `build-aarch64-native.sh <src> <out>` | The same build with host clang, lld and a Debian arm64 sysroot, no Docker |
| `build-x86_64.sh <src> <out>` | Native PC build for the Xvfb test harness. Needs `libsdl2-dev` (and `libasound2-dev`) installed |
| `Dockerfile` | Build image used by `build-aarch64.sh` |
| `make_licenses.py <src> <out>` | Writes a license file for the crates linked into `ruffle_sdl` (needs cargo) |

Typical use:

```
ruffle/fetch.sh work/ruffle-src
ruffle/build-aarch64.sh work/ruffle-src work/out
# or on the PC:
ruffle/build-x86_64.sh work/ruffle-src work/out-pc
```

`ruffle_sdl` is built with `cargo build --release -p ruffle_sdl --features lzma`. The aarch64 builds target `cortex-a53` by default (set `CPU=generic` to change). Link time optimization was measured and gave no gain.

## The patches

Credit: patches 0001 to 0004, 0013 and 0014 are by crxssrazr93. The `ruffle_sdl` front end (0006) and the memory patches 0005 and 0007 to 0012 are by Knifethrower (contributed as GitHub PR #1 on the example port repo), and carry the author line `port <port@localhost>` from the original export. Do not rewrite those author lines.

Env vars are read at run time. "Generic" means the patch has no game specific behaviour.

| # | Title | Author | Env vars (default) | Generic |
|-|-|-|-|-|
| 0001 | avm2: implement Graphics.readGraphicsData | crxssrazr93 | none | Yes, upstreamable |
| 0002 | Stage3D batching, pipeline and bind group caches, TextureBase.dispose, relaunch fscommand, FPS log | crxssrazr93 | RUFFLE_FPS_LOG (off, any value turns it on, needs RUST_LOG including ruffle_core::player::port_fps=info) | Yes. Its relaunch marker is renamed by 0014 |
| 0003 | Keep Stage3D texture uploads on the GPU, texture dispose, AS3 profiler | crxssrazr93 | RUFFLE_AS3_PROF (off, any value turns it on) | Yes |
| 0004 | Lazy mouse picking and frame skipping for frame based AVM1 games | crxssrazr93 | RUFFLE_LAZY_MOUSE_PICK (off), RUFFLE_FRAMESKIP (off) | Yes, opt in |
| 0005 | core: Player::add_gc_work and Player::collect_garbage_now | Knifethrower | none | Yes, upstreamable |
| 0006 | ruffle_sdl: Ruffle on SDL2 and GLES 3 for handhelds | Knifethrower | RUFFLE_GC_STEP (0.01), RUFFLE_TRIM_SECS (2), RUFFLE_GC_LONG_TICK (1.0), RUFFLE_SDL_TIMING (off), RUST_LOG (warn), WGPU_* options | Yes. Its relaunch marker is renamed by 0014 |
| 0007 | core: tessellate DefineShapes on first render, parse shape records on demand | Knifethrower | RUFFLE_LAZY_SHAPES (on), RUFFLE_LAZY_SHAPE_RECORDS (on) | Yes, upstream candidate |
| 0008 | wgpu: draw BitmapData.draw in place when it can, cap the offscreen pool | Knifethrower | RUFFLE_DRAW_IN_PLACE (on), RUFFLE_DRAW_POOL_MB (16, 0 off) | Yes |
| 0009 | core: blank BitmapData without resident pixels or zero uploads | Knifethrower | RUFFLE_ZEROED_PIXELS (on), RUFFLE_EMPTY_TEXTURES (on) | Yes |
| 0010 | Memory accounting by category (RUFFLE_MEMLOG), sampled by ruffle_sdl | Knifethrower | RUFFLE_MEMLOG (off), RUFFLE_MEMLOG_MS (100), RUFFLE_MEMLOG_TOP (8), RUFFLE_MEMLOG_PEAK (unset) | Yes, diagnostic |
| 0011 | Stage3D uploads without a submit, consecutive draws in one render pass | Knifethrower | RUFFLE_S3D_DEFER_UPLOAD (on), RUFFLE_S3D_MERGE_PASSES (on), PM_GPUSTAT (off) | Yes. PM_GPUSTAT has a port prefix in its name |
| 0012 | ruffle_sdl: run with SDL 2.0.10 | Knifethrower | none | Yes |
| 0013 | ruffle_sdl: minimum key hold, so games that poll keys see short taps | crxssrazr93 | RUFFLE_MIN_KEY_HOLD_MS (100, 0 off) | Yes |
| 0014 | ruffle_sdl, desktop: generic RUFFLE_RELAUNCH marker, drop PORT_EXP experiment | crxssrazr93 | none | Yes |

Notes on 0014: the relaunch fscommand now prints `RUFFLE_RELAUNCH <args>` on stdout (in `ruffle_sdl` and in the desktop player) and exits, so a launch script can restart the binary with new arguments. The temporary PORT_EXP draw skipping experiment that the older inventory listed is already removed by patch 0003, so there was nothing left to delete.

The full table of env vars, with when to change each, is in `docs/env-vars.md`.

## Verification done on this series

The series applies cleanly with `git am` on the pinned commit, and `cargo check -p ruffle_sdl --features lzma` passes on the resulting tree.

## How to add a patch

1. Get a tree: `ruffle/fetch.sh work/ruffle-src` (add `WITH_OPTIONAL="0100"` if you want an optional patch on top).
2. Make your change in that tree and commit it with a clear subject and a body that explains why. Use your own author identity (`git commit --author=` if needed). Keep the subject generic: no game names, no device names in the subject.
3. Export it: `git -C work/ruffle-src format-patch -1 --no-signature -o /tmp/out`. Copy the file into `ruffle/patches/` and name it with the next free number, for example `0015-core-short-title.patch`. Keep file names short and ASCII.
4. Add the file name as a new line at the end of `ruffle/series`. Order matters, because later patches are applied on top of earlier ones.
5. Prove the whole series still applies: run `ruffle/fetch.sh` into an empty directory (the same `RUFFLE_REPO` mirror you use is fine), then `cargo check -p ruffle_sdl --features lzma` in it.
6. Add the patch to the table above (author, env vars with defaults, generic or not) and to `docs/env-vars.md` if it adds an env var.
7. Patches that are experiments or only wanted by some ports go in `ruffle/optional/` with a number from 0100 up and are not listed in `series`. Apply them with `WITH_OPTIONAL`.

To move to a newer Ruffle, change `PIN`, run `fetch.sh`, fix the patches that no longer apply (`git am --show-current-patch`, resolve, `git am --continue`), and re-export the whole series with `git format-patch` so the files match the tree.

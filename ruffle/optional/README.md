# Optional patches

Patches here are not part of the default series in `../series`. Apply them after the series with
`WITH_OPTIONAL`, which takes the space separated numbers:

```
WITH_OPTIONAL="0100" ruffle/fetch.sh [dir]
```

fetch.sh applies them with `git am` after the series, so they keep their author line. They are
made with `git format-patch` from a tree that already has the whole series, so a new Ruffle pin
may need them regenerated.

| Number | Title | Author | Environment variables (default) | Flag |
| --- | --- | --- | --- | --- |
| 0100 | ruffle_sdl: software mouse cursor overlay and SDL colour cursor | crxssrazr93 | `RUFFLE_SW_CURSOR` (0), `RUFFLE_SW_CURSOR_IDLE_MS` (2000), `RUFFLE_SW_CURSOR_SIZE` (24), `RUFFLE_SW_CURSOR_IMAGE` (unset, built in arrow), `RUFFLE_SDL_CURSOR` (0) | `--sw-cursor` |
| 0101 | ruffle_sdl: the software cursor follows the movie (Mouse.hide, hand over buttons). Needs 0100: `WITH_OPTIONAL="0100 0101"` | Knifethrower | `RUFFLE_SW_CURSOR_FOLLOW_MOVIE` (1, 0 off) | none |

## 0100 software cursor

`ruffle_sdl` hides the system cursor, so a gamepad driven mouse (the gptokeyb right stick mouse is a
uinput mouse that reaches SDL as `MouseMotion`) is invisible. This patch adds `sdl/src/cursor.rs`
and a few anchored hooks in `sdl/src/main.rs`, and one `png` dependency line in `sdl/Cargo.toml`
(`png` is already in Ruffle's lockfile, so no new crate is downloaded).

* The software cursor (`RUFFLE_SW_CURSOR=1` or `--sw-cursor`) is a small arrow drawn as one GLES 3.0
  quad on the window framebuffer, after the movie was blitted and before the buffer swap, in window
  pixels, so it works with `--render-size` and letterboxing. It is shown after mouse motion and
  hidden after `RUFFLE_SW_CURSOR_IDLE_MS` without motion. While hidden it costs nothing. All GL
  state it touches (program, vertex array, texture and sampler of unit 0, unpack state, blend,
  viewport, scissor, depth, stencil, cull, colour mask, draw framebuffer) is saved and restored,
  because wgpu owns the context. When only the cursor changed the frame is rendered again so it moves
  on a still picture.
* `RUFFLE_SW_CURSOR_SIZE` is the height of the built in arrow in pixels. `RUFFLE_SW_CURSOR_IMAGE`
  loads a PNG instead (any 8 or 16 bit gray, gray alpha, RGB, RGBA or palette PNG up to 512 by 512,
  hotspot at the top left pixel). The image keeps its own size unless the size variable is set, then
  it is scaled to that height.
* `RUFFLE_SDL_CURSOR=1` builds an SDL colour cursor from the same bitmap (`SDL_CreateColorCursor`) and
  shows it. This only works where the video driver draws cursors (X11, Wayland), not on fbdev or
  KMSDRM without a hardware cursor.

Test it headless with `tests/cursor_test.sh`, see `docs/09-input.md` and `tests/README.md`. The test
hooks of `tests/sdl_test_hooks.py` apply on top of this patch (the capture sees the cursor, because it
is drawn inside the blit, before the capture point).

## 0101 the cursor follows the movie

On top of 0100. The Flash Player's cursor follows the movie, and with this patch the software cursor
does too:

* `Mouse.hide()` hides it and `Mouse.show()` brings it back. Games that draw their own pointer call
  `Mouse.hide()`; with 0100 alone they show two pointers.
* Over buttons and links (the player's hand cursor, `MouseCursor::Hand` and `Grab`) the built in
  arrow turns into a pointing hand of the same height, made the same way (box filtered, white with
  a black outline, fingertip on the pointer). A `RUFFLE_SW_CURSOR_IMAGE` stays as it is.

`ruffle_sdl` gets a small UI backend that records these two requests instead of the
`NullUiBackend`; everything else is passed to the null backend. `RUFFLE_SW_CURSOR_FOLLOW_MOVIE=0`
gives the cursor of 0100 unchanged. The SDL colour cursor (`RUFFLE_SDL_CURSOR`) does not follow.

Test: `tests/cursor_test.sh` cases `movie_hide`, `movie_hide_ignored` and `button_hand`, with the
fixtures `test_hide.swf` (calls `Mouse.hide()`) and `test_button.swf` (a button under the pointer).

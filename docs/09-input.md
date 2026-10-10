# 09 Input

## When you need this

Read this when you map a handheld gamepad to a Flash game, when buttons seem to be missed, when the game needs a mouse cursor, or when you plan volume or quality controls that the original showed as mouse UI.

## The basic model

Ruffle never reads the gamepad. The standard PortMaster pattern for Flash ports is:

1. `gptokeyb` turns pad buttons into keyboard (and optionally mouse) events through a `.gptk` file.
2. `ruffle_sdl` receives them as SDL keyboard events and maps SDL keycodes to Ruffle key descriptors (`sdl/src/keys.rs`, with left, right and numpad locations).
3. Printable keys arrive as the unshifted key character with shift and caps lock applied.

Flash is keyboard and mouse only, so a gptk keymap is required. This differs from games that read the pad themselves, where `gptokeyb` runs without a gptk and only provides the exit hotkey, because any extra key or mouse event can flip such a game into keyboard mode.

Always pass the real process name to gptokeyb (`ruffle_sdl`) so the hotkey kill and the lifetime follow the game.

## A keyboard gptk for a Flash game

A starting template (letters change per game, so read the game's own key handling first):

```
back =
guide =
start = space
a = s
b = a
x = d
y = shift
l1 = m
l2 = n
up = up
down = down
left = left
right = right
left_analog_up = up
left_analog_down = down
left_analog_left = left
left_analog_right = right
deadzone_mode = scaled_radial
deadzone = 4096
```

Rules that cost time to learn:

* Verify the game's real key handling in the decompiled shell before mapping. A title screen may advertise keys that a later release removed. A key that quits a paused level (a soft lock) must not be mapped. Shells often relay keys to AS2 sub SWFs over LocalConnection, so check both sides.
* Keep only keys the game uses. A comment only gptk still sends the defaults, which double presses in a game that also reads the pad.
* Generate README key tables from the gptk, or keep one source of truth, or the docs drift away from the file.
* Audit controls per scene, with at least four presses each, and check by screenshot. Do not trust the gptk to describe what the game does.

### Positional face buttons and the swap pitfall

Document buttons by SDL position (A is the bottom button, which is labelled B on Anbernic style pads), not by the label printed on a device. Do not rewrite `SDL_GAMECONTROLLERCONFIG` with sed to swap A and B or X and Y in a launcher. On devices whose bottom button is labelled A, and with Knulli's per game layout (long press X in the ports list), such a swap flips wrong or twice. Leave the layout to the firmware. When you inject test input, remember it is positional too: the pad code for the bottom button is SDL button b, and a "cannot jump" report was once a test script pressing the attack button.

### gptokeyb2 on muOS

gptokeyb (v1) was unresponsive on muOS. Use gptokeyb2 there, with the same v1 syntax gptk:

```
if [ "$CFW_NAME" = "muOS" ] && [ -n "$GPTOKEYB2" ]; then
  $GPTOKEYB2 "ruffle_sdl" -c "$GAMEDIR/MYPORT.gptk" &
else
  $GPTOKEYB "ruffle_sdl" -c "$GAMEDIR/MYPORT.gptk" &
fi
```

PortMaster's `control.txt` defines `GPTOKEYB2` (with an LD_PRELOAD interpose library). A virtual Xbox pad (`gptokeyb2 -x`) is a fallback only: it merges all pads into one player. `get_controls` sets `$sdl_controllerconfig`, not `SDL_GAMECONTROLLERCONFIG`, so export it yourself for a game that reads the pad.

## Short taps and Key.isDown polling

`Start` is part of gptokeyb's Select plus Start hotkey, so gptokeyb v1 delays it and sends the press and release about 16 ms apart on button release. Code that polls `Key.isDown` once per frame (typical AS2) misses most such taps (3 of 8 and 2 of 6 caught in tests), while held keys always work. A uinput test keyboard confirmed it: 150 ms taps toggled every time, 16 ms taps did not.

The fix belongs in the runtime, not in telling players to hold Start. Patch 0013 (crxssrazr93) adds a minimum key hold to `ruffle_sdl`. The event loop remembers when each key went down. A KeyUp that arrives sooner than the minimum is deferred, due releases are flushed at the top of the loop, the wait timeout includes the next due release, and a new KeyDown of a still held key releases it first.

| Variable | Default | Meaning |
|-|-|-|
| `RUFFLE_MIN_KEY_HOLD_MS` | 100 | Minimum hold in ms. 0 turns the feature off. |

Result in tests: Start reliable (8 of 8, was 2 of 6), movement unaffected. Set 0 for purely event driven games, raise it for games that run at about 20 fps. To check tap length on a device, run `evtest` on gptokeyb's virtual "Fake Keyboard" device.

## Volume and quality keys implemented in the shell

When the original used mouse UI (sliders, a quality button) that has no cursor, map it to buttons inside the shell patch:

* Map two shoulder buttons to two spare letter keys in the gptk.
* In the shell's key handler, step the value (for example 1, 0.5, 0, back to 1), save it like the slider does, update slider knobs, and show a short note (a stage TextField that fades after some frames).
* Never send exactly 0 to a sub SWF. In one case `setMusic(0)` paused music without setting the volume, so raising it later never resumed it. Send `Math.max(value, 0.001)`. Check every zero special case in the same way.

This pattern, "give mouse only functions a button", is general. It was chosen over a software cursor in the example port. See [02 Shell patching](02-shell-patching.md) for patching the key handler.

## Mouse

`ruffle_sdl` hides the system cursor right after creating the GL context (`show_cursor(false)`). Mouse input itself works: motion and buttons are mapped through the same stage transform as the blit. But nothing draws a cursor, so a game or overlay menu that needs one is unusable unless you add a cursor.

Right stick as mouse through gptokeyb, tuned to be usable on 640x480 without drift:

```
right_analog_up = mouse_movement_up
right_analog_down = mouse_movement_down
right_analog_left = mouse_movement_left
right_analog_right = mouse_movement_right
r1 = mouse_left
r2 = mouse_left
deadzone_mode = scaled_radial
deadzone = 4096
deadzone_scale = 8
deadzone_delay = 16
mouse_scale = 1024
mouse_delay = 6
```

The template `templates/port/MYPORT/MYPORT.gptk` has these lines commented out, keeps the dead zone settings active, and maps R1 to a left click and R2 to a right click. R1 and R2 as clicks let mouse only menus work, but only if a cursor is visible. A mouse mapping with no cursor is confusing and useless. Verify the stick to mouse mapping with `evtest` per device: on one device the right stick axes (ABS_Z, ABS_RZ) produced key events and REL events in an unexpected order.

## Software cursor: every implementation

Five approaches exist or are planned. They can be combined. Each has a status line that is kept up to date by the toolkit maintainers.

### 1. Front end overlay (optional patch 0100)

A GL quad drawn by `ruffle_sdl` after Ruffle's frame. Shown after mouse motion, hidden after an idle time.

* Patch: `ruffle/optional/0100-ruffle_sdl-software-cursor-overlay.patch` (applied with `WITH_OPTIONAL="0100" ruffle/fetch.sh`).
* Switches: `RUFFLE_SW_CURSOR` (default 0, 1 enables), `RUFFLE_SW_CURSOR_IDLE_MS` (default 2000), `RUFFLE_SW_CURSOR_SIZE` (pixels, default 24), `RUFFLE_SW_CURSOR_IMAGE` (optional PNG path), and the `--sw-cursor` CLI flag.
* Works for every movie, needs no shell patch, not tied to the AVM version.

Status: planned (not yet verified here)

### 2. SDL colour cursor

`SDL_CreateColorCursor` as a fallback inside the same patch, enabled with `RUFFLE_SDL_CURSOR=1`. It only works where the video driver draws cursors (X11, Wayland, some DRM stacks). On a bare framebuffer or KMSDRM EGL setup it normally shows nothing.

Status: planned (not yet verified here)

### 3. Shell side AS3 overlay

A Sprite added at the top of the display list that follows the stage mouse and hides after idle. Snippet: `tools/swf/snippets/cursor_overlay.as3.txt`, applied through the shell patch step (see [02](02-shell-patching.md)).

Status: planned (not yet verified here)

### 4. Shell side AS2 variant

The same idea in AS2, written to be P-code friendly: a movie clip at a high depth with `onMouseMove`, hidden by a frame counter. Snippet: `tools/swf/snippets/cursor_overlay.as2.txt`.

Status: planned (not yet verified here)

### 5. gptokeyb pointer source

Right stick to `mouse_movement_*` plus R1 and R2 as clicks (above). This only produces pointer motion. It needs one of 1 to 4 to be visible. It is the one piece that every other approach depends on when the user has no touch screen or mouse.

Status: mapping known to inject REL events into gptokeyb's virtual device (verified by a test harness); no end to end run with a visible cursor yet

### Trade offs

| Approach | Needs shell patch | Works for AS2 and AS3 | Visible on bare framebuffer | Cost | Main risk |
|-|-|-|-|-|-|
| 1 Front end overlay | No | Yes | Yes (drawn into the GL frame) | One optional Ruffle patch | Must be re-checked on each Ruffle pin and against SDL 2.0.10 |
| 2 SDL colour cursor | No | Yes | Usually no | Same patch | Driver dependent, silent no op |
| 3 AS3 overlay | Yes | AS3 shell only | Yes | Small shell patch | Only the movie that carries it shows it, covered by content loaded above |
| 4 AS2 overlay | Yes (P-code) | AS2 movies only | Yes | Small P-code patch per SWF | Per SWF patching and depth conflicts |
| 5 gptokeyb pointer | No | Yes | n/a (input only) | A gptk edit | Useless alone, drift without correct deadzones |

Recommendation until tested: pick 1 plus 5 for a generic port, 3 or 4 when you already patch the shell and want no Ruffle patch. Keep 2 only as a convenience for PC runs.

## SDL 2.0.10 compatibility

Handhelds ship old SDLs (Knulli 2.32.8, muOS 2601 about 2.28.5, and a floor of 2.0.10). The Rust `sdl2` crate imports `SDL_Metal_DestroyView` (SDL 2.0.12 and later). It is the one missing symbol of 26 SDL imports on 2.0.10, and patch 0012 (Knifethrower) defines a local no op stub:

```
#[unsafe(no_mangle)]
pub extern "C" fn SDL_Metal_DestroyView(_view: *mut std::ffi::c_void) {}
```

Rules for new front end features (a cursor, for example):

* List the binary's undefined SDL symbols and compare them with the exports of the oldest libSDL2 you support.
* Prefer plain GL calls over newer SDL helpers.
* `ruffle_sdl` needs SDL 2.0.10 or later with GLES 3, and glibc 2.30.

## Controller facts worth knowing

* Pad button codes are positional (A bottom is BTN_SOUTH 304 on one H700 device). D-pad is ABS_HAT0X and ABS_HAT0Y.
* Some pads report Z, RX, RY and RZ instead of X and Y, so engines that read only ABS_X and ABS_Y ignore the stick. Mapping the left stick to arrow keys in the gptk avoids this.
* On muOS the pad shows up as a gpio-keys device with a different mapping name. Log the key and abs bitmaps in bug reports.
* If both gptokeyb and another layer forward the pad, input doubles. Make sure only one does.

## Pitfalls

* Missing Start taps in polled games: raise `RUFFLE_MIN_KEY_HOLD_MS`, do not ask players to hold.
* A mouse mapping with no visible cursor is worse than no mapping.
* Swap blocks for A and B in a launcher break on firmwares that already swap.
* Volume 0 can break a sub SWF. Send 0.001.
* Docs drift from the gptk. Generate or review them together.
* A gptk that is only comments still sends gptokeyb defaults.
* Do not inject test input into the real firmware UI when the game has exited (see [10](10-testing.md)).

## See also

* [02 Shell patching](02-shell-patching.md)
* [04 ruffle_sdl](04-ruffle-sdl.md)
* [10 Testing](10-testing.md) (virtual keyboard, evdev injection)
* [11 Launcher and packaging](11-launcher-packaging.md)
* [env-vars.md](env-vars.md)

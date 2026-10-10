# 08 Screen and aspect

## When you need this

Read this when your Flash or AIR game was authored for one fixed stage size (for example 3:2 or 4:3) and has to run on handhelds with 4:3, 16:9 and 1:1 screens, or on an HDMI output up to 1920x1080. It explains how the front end hands the screen to the game, what the shell has to do, and which hard coded numbers in game code break when the view gets taller or wider than the original.

## How the pieces fit

Ruffle renders the movie into one texture. `ruffle_sdl` then blits that texture to the default framebuffer, flipped on Y, aspect fitted, with NEAREST filtering at exactly 1:1 and LINEAR otherwise. Bars are cleared black.

Two front end options decide who owns the layout:

| Option | Meaning |
|-|-|
| `--stage-scale fit` (default) | Ruffle letterboxes with ShowAll. The game never sees the real screen shape. |
| `--stage-scale movie` | The movie keeps its own scale mode and align, with no letterbox. The shell does the fitting. |
| `--width W --height H` | Window size. Default is the full desktop size (fullscreen desktop). |
| `--render-size WxH` | Render at a smaller size and scale up. A cheap speed lever on weak GPUs. |

For ports that need real aspect handling, run with `--stage-scale movie` and let the patched shell set the stage to NO_SCALE and fit itself. Mouse motion and buttons go through the same transform as the blit, so pointer coordinates stay correct in every mode.

## The three modes

Expose one cfg setting (for example `ASPECT`) and pass it to the shell as a flashvar (`-Paspect=extend`).

| Mode | What the game sees | Result |
|-|-|-|
| extend (default) | The real screen size and ratio | Content fills the screen. Wide screens show more to the right, tall screens show more vertically. |
| fit | The original stage size | Original ratio kept, black bars. The shell must draw the bars itself (see Pitfalls). |
| fill | The original stage size, scaled up | Original ratio kept, the overflow is cropped. HUD at the edges can be cut. |

Only extend passes the real ratio into the game's own `setDimensions` style call. Fit and fill keep the original width and height.

Choose a default by playing each mode in real gameplay, not in menus. Install two builds side by side with separate saves if you want to compare on a device. Document per game which mode clips the UI (fill usually does on 4:3).

### Shell implementation outline

1. Stage scale mode NO_SCALE, stage align top left.
2. Compute `scale = min(stageW / origW, stageH / origH)` for fit and extend, and `max(...)` for fill.
3. Position: centre horizontally for fit and fill. For extend set x to 0 so a screen wider than the game extends sideways and the view height stays at the original height.
4. Vertical centring only in fit.
5. Re-run the same code from the stage resize handler.

The aspect code is a small patch to the shell's resize handler. See [02 Shell patching](02-shell-patching.md) for how to patch, and `tools/swf/anchor.py` for the anchored patch helper.

### Real screen size to the game

Report `stage.stageWidth` and `stage.stageHeight` where the shell used `Capabilities.screenResolutionX/Y`. Under Xvfb or a compositor those capabilities need not match the window. AIR shells that call `Stage.fullScreenSourceRect` get nothing from Ruffle (the setter and getter are stubs), so do the aspect handling yourself and ignore AIR fullscreen and window options. A quality toggle in the shell that changes a raw stage height used with `fullScreenSourceRect` does nothing visible. Leave it unmapped.

### Backdrop and bars

* Keep the original stage background colour. A black backdrop added at stage index 0 makes black characters invisible in rooms without background art. Draw a backdrop with the movie's own background colour (a Shape at index 0), and black only outside the game rectangle in fit mode.
* In fit mode, add a black frame Shape on the stage above the game, built from two `drawRect` calls (outside rectangle minus inside). Flash does not clip level art to the stage rectangle, so without the frame art spills over the bars.
* White bars in fit mode came from the stage colour, not from the letterbox. Ruffle's `--letterbox on` does not turn them black. The backdrop does.

## Fixed numbers that assume the base view height

Extend changes the view height on every screen that is not the original ratio. Every constant that quietly assumed the original height must be audited. Typical offenders:

* Fall or death lines, for example a check like `_y > -MinY + 700` where `MinY` is derived from the scaled stage height. At the original height the line sits a fixed distance below the level. On a square view it can land above the level bottom, which kills the player every time.
* Camera bounds (min and max Y) that were clamped for the original height. Extra height then hangs below the level art, or the camera clamp flips top and bottom.
* Pause overlays and dim layers that cover only the original height, leaving a gap.
* Fixed backdrops, scroll rects, mask rectangles, HUD anchors with literal pixel values.

Method that worked:

1. Grep the decompiled shell and every sub SWF for literals near the original height (480, 540, 700 and so on) and for scroll rect and bounds code.
2. Trace where each bound comes from per SWF. Some read fixed level data, others a computed value. Do not assume every SWF has the same bug.
3. Express each constant relative to the stage, for example `scaledStageHeight + 220` instead of `700` (equal at the original height).
4. Prove it numerically with a trace build. Insert a dup and trace in the P-code at the comparison, then run at several resolutions on the PC and compare numbers. This beats trying to script the player into a pit.
5. For extra height, prefer "taller view, no gap": the camera never goes below the level bottom, extra space shows above, short rooms align to their floor. Fill any remaining area under pause overlays (a black or dim rectangle drawn only when the stage is taller than the original).

On the toolkit's side, `tools/swf/anchor.py` and `tools/swf/ffdec.sh` give anchored exact match patching for both AS3 and P-code, with loud failure when an anchor matches the wrong number of times.

## Resolution checklist

Test these sizes, in extend, and fit at both 4:3 and 16:9. Fill at 1920x1080 at least.

| Size | Why |
|-|-|
| 640x480 | The common 4:3 handheld. The base case for screenshots in a port submission. |
| 720x720 | Square screens. The hardest case for taller views. |
| 960x544 | A 16:9 class handheld. |
| 1024x768 | Larger 4:3. |
| 1280x720 | 16:9 and the usual HDMI size. Catches centring bugs on wide views. |
| 1920x1080 | Large devices and HDMI. Frame rate here has never been measured on real hardware, so treat it as a layout check only. |

Small extras (480x320) are optional for a submission but cheap to run on the PC.

## Testing each resolution headless

Never open a window on your desktop. Use Xvfb with a private display, or `gamescope --backend headless`. Details and the capture hook are in [10 Testing](10-testing.md). The short version:

```
tests/pc_sdl_run.sh <ruffle_sdl> <port dir> 720x720 <game> <level> 20 out/gp_extend shot
```

The runner starts Xvfb at the given size, passes `--width` and `--height` to match, sets the aspect flashvar from the `ASPECT` environment variable, and writes a PNG per `shot` step. Loop over the sizes and the three aspect values, then build a labelled comparison sheet and check:

* the player and HUD are fully visible,
* no strip of stage colour on the wrong side,
* bars are black in fit and nothing spills over them,
* pause overlays cover the whole view,
* the numbers from your trace build match the expected relative values.

Stock desktop Ruffle does not reproduce the port's extend layout (it drew the bottom half black in one case). Build `ruffle_sdl` for x86_64 from the same tree (`ruffle/build-x86_64.sh`) and test with that.

## Pitfalls

* Centring in extend on screens wider than the game pushes the world right and cuts the right edge. In extend set x to 0.
* Fit without drawn bars lets art spill outside the game rectangle.
* A tall view with an unchanged camera clamp leaves a gap below the level and under the pause overlay.
* A square screen is the worst case for fall lines. Always run 720x720 and 1920x1080 before declaring extend done.
* Per SWF differences: one SWF having the bug does not mean all do. Check each.
* Capturing from the wrong place gives black images (see 10). Do not blame the aspect code for a black capture.
* Bump the patch version every time the SWF patches change, so installs re-patch (see [11](11-launcher-packaging.md)).

## See also

* [02 Shell patching](02-shell-patching.md)
* [04 ruffle_sdl](04-ruffle-sdl.md)
* [10 Testing](10-testing.md)
* [11 Launcher and packaging](11-launcher-packaging.md)
* [env-vars.md](env-vars.md)

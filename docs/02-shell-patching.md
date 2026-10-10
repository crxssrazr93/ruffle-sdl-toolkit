# 02 Shell and SWF patching

## When you need this

Read this when you have decided the port is feasible (doc 01) and now have to make the shell and the sub movies run without AIR. It covers the decompile and recompile workflow with JPEXS ffdec, how to write patches that fail loudly on the wrong game version, which AIR calls to remove and what to put in their place, how to patch AS2 through P-code, and the layout, clock and quality fixes that every port ends up needing. A generic worked example is at the end.

## 1. Principles

1. Never commit decompiled source or patched SWFs. Patch scripts regenerate the patch from the user's own SWF at build time. A public repo carries scripts, not game code.
2. Every substitution is anchored and counted. A different game version must fail, not silently produce a half patched SWF.
3. Replace only the classes you change. ffdec recompiles some decompiled AS3 slightly wrong, so the fewer classes you replace, the fewer surprises.
4. Test the patched SWF on the PC under Xvfb before it goes near a device (doc 10).

## 2. ffdec workflow

JPEXS Free Flash Decompiler (ffdec) 26.3.0 was the version used. It needs a JRE (OpenJDK 21 worked). Get it from the jindrapetrik/jpexs-decompiler releases (`ffdec_26.3.0.zip`), and point the toolkit at it:

```
export FFDEC=/path/to/ffdec/ffdec        # wrapper script, or run: java -jar ffdec.jar
tools/swf/ffdec.sh as3    shell.swf work/shell_src                 # all AS3 scripts
tools/swf/ffdec.sh as3    shell.swf work/shell_src MainClass       # one class
tools/swf/ffdec.sh pcode  world.swf work/world_pcode              # AS2 P-code
tools/swf/ffdec.sh replace-as3   shell.swf out.swf MainClass work/shell_src/scripts/MainClass.as
tools/swf/ffdec.sh replace-pcode world.swf out.swf /frame_1/DoAction work/world_pcode/scripts/frame_1/DoAction.pcode
```

Under the hood these are ffdec commands:

- Export scripts: `-export script <dir> <swf>`. One class: `-selectclass <Class> -export script <dir> <swf>`.
- P-code instead of source: `-format script:pcode -export script <dir> <swf>`.
- Binary tags (embedded ATF and others): `-export binaryData <dir> <swf>`.
- Replace: `-replace <in.swf> <out.swf> <ClassOrScriptName> <file> [<name2> <file2> ...]`. Several in one call. ffdec prints `Warning: This feature is EXPERIMENTAL`. That is normal.
- `-air` as a pre option compiles against airglobal.swc instead of playerglobal.swc. The port took the strip route instead of using it, because Ruffle only stubs AIR anyway.

Export layout you will meet:

- AS3 sources land in `<dir>/scripts/<package>/<Class>.as`.
- AS2 P-code lands in `scripts/frame_N/DoAction.pcode`, `scripts/__Packages/<Class>.pcode`, `scripts/DefineSprite_<id>_<name>/frame_N/DoAction.pcode`, and button handlers in `scripts/DefineButton2_N/"BUTTONCONDACTION on(press).pcode"`.
- Embedded binaries extract as `<id>_<Class>_atf_<Name>.bin`.

A shell with 18 scripts and a Starling hub with 580 decompile in seconds.

## 3. Anchored replacements

Use `tools/swf/anchor.py`, an importable library. The core is a `Patch` object over the text of one source file:

```python
import sys
sys.path.insert(0, "tools/swf")
from anchor import Patch

p = Patch.load("work/shell_src/scripts/Main.as")

p.sub('NativeApplication.nativeApplication.exit();', 'fscommand("quit");', count=2)
p.sub('var w:int = nativeWindow.width;', 'var w:int = stage.stageWidth;')   # count defaults to 1
p.drop_method("onGameInputDeviceAdded")        # removes the method by brace matching
p.forbid(["Steamworks", "nativeWindow", "NativeApplication", "GameInput", "File."])
p.save("work/shell_patched/Main.as")
p.report()                                     # prints the patched OK summary
```

What these do:

- `sub(old, new, count=1)` counts the matches first and exits with `patch anchor matched Nx (expected M)` if the count differs. On a first run this caught a real miscount: `patch anchor matched 2x (expected 3): 'NativeApplication.nativeApplication.exit();'`.
- `drop_method(name)` deletes a whole method with brace matching. Use it for controller setup, window moving, close handlers and Steam response handlers.
- `forbid(list)` scans for leftover identifiers at the end. If any remain it fails and lists them. This is the guard that keeps AIR code from slipping through.

`tools/swf/example_patch.py` is a documented template that uses the library. Copy it and replace the anchors.

Rules for anchors:

- Make them long enough to be unique but short enough to survive whitespace differences. Prefer a distinctive statement over a whole block.
- Put the expected count on every `sub`. Never rely on the default when the text can appear twice.
- When an anchor is a P-code block (AS2), match literal multi line text.

## 4. Replace only the changed AS3 classes

The hub patch of a Starling game replaced three classes (the main class, a backgrounds class and `starling.textures.ConcretePotTexture`). The shell patch replaced only the shell main class. Recompiling more risks hitting decompiler artifacts in classes you never needed to touch.

## 5. Decompiler artifacts and how to fix them

| Symptom | Cause | Fix |
|---|---|---|
| `new Sprite()` or `Texture.fromEmbeddedAsset` compiles to the `flash.*` class when both `flash.display.*` and `starling.display.*` are imported | Unqualified names with two wildcard imports | Fully qualify injected code: `new starling.display.Sprite()` |
| `Event` ambiguous between `flash.events` and `starling.events` | Same | Use `flash.events.Event`, `flash.display.Loader`, `flash.net.URLRequest` in injected code |
| `ReferenceError: Error #1037: Cannot assign to a method scrollEngine on Main.` | ffdec renders `var f:Function = function():*{}` as an empty method | Regex: find empty `function X():*{}` that is assigned elsewhere (`.X = `) and rewrite as `var X:Function = function():*{};` |
| Compile error on undefined names such as `removeEventListener(Event.ENTER_FRAME, menuEnterFrame)` or `sendSettingsWaitN = 0` | Dead references left by the decompiler | Delete those statements before recompiling |
| `Error #1069: Property textureOptions not found on starling.utils.AssetManager` | Injected call uses a newer library API than the bundled Starling version | Read the decompiled library class first. This version used `scaleFactor` |
| Type errors at startup that abort init and hide an unrelated path bug | A type error stops the constructor before later assignments such as `whereAt` | Fix type errors first, then re test paths |

Always check the version of a bundled library class (Starling, greensock) in the decompiled tree before you inject calls against it.

## 6. AS2 patching through P-code

AS2 is not recompiled from source. Export P-code, edit it, and replace the script by name.

```
tools/swf/ffdec.sh pcode world.swf work/world_pcode
grep -l 'Push "width", "scaledStageWidth"' work/world_pcode/scripts/frame_*/DoAction.pcode
# edit, then
tools/swf/ffdec.sh replace-pcode world.swf world_patched.swf /frame_1/DoAction work/world_pcode/scripts/frame_1/DoAction.pcode
```

Script names for `-replace`:

- `/frame_N/DoAction`
- `/__Packages/<Class>`
- `/DefineSprite_<id>_<name>/frame_4/DoAction`

Only the leading slash form works. `frame_1/DoAction` and `\frame_1\DoAction` both failed. A patcher that only loops over `scripts/frame_*/DoAction.pcode` has to be extended to `__Packages` and `DefineSprite_*` paths.

P-code patch style:

- Anchors are literal multi line P-code, for example `Push "ScrollRect"\nGetVariable\nPush "width", "scaledStageWidth"...`.
- New branches use their own labels (`If locporty` ... `locporty:`). Reuse the existing end label by capturing it with a regex from the function header (`DefineFunction2 "setBounds"`).
- Print the scripts to replace as `name<TAB>file` and feed them to one `-replace` call.
- Find scripts by content, not frame number, and guard each patch by a marker string or the existence of a sprite. One patch script then serves several AS2 SWFs, and a patch that does not apply to a given SWF is skipped on purpose (print which patches hit per SWF in a dry run).
- Prove numeric fixes with a trace build: insert `PushDuplicate` plus `Trace` at the comparison and read the Ruffle log, instead of steering the player into a pit.

Example OLD and NEW pair (a hard coded camera or death line made to follow the view height):

```
OLD
Push 0.0, register2, "MinY"
GetMember
Subtract
Push 700
Add2
Greater

NEW
Push 0.0, register2, "MinY"
GetMember
Subtract
Push register2, "scaledStageHeight"
GetMember
Add2
Push 220
Add2
Greater
```

## 7. Removing AIR APIs and what replaces them

Strip imports of `flash.desktop.*`, `flash.filesystem.*` and the ANE packages, and every use. Then run the forbid check. Replacement table:

| AIR or ANE use | Replacement |
|---|---|
| `NativeApplication.nativeApplication.exit()` | `fscommand("quit")` |
| Steam init block (app id check, exit on mismatch), Steam listeners, Steam relaunch handlers | Delete the block and the handler methods |
| Steam Cloud style `fileWrite` and `fileRead` | `SharedObject.getLocal("<name>", "/")` with `so.data[fileName]` plus `flush()` |
| `stage.nativeWindow.width` and `height` | `stage.stageWidth`, `stage.stageHeight` |
| `Capabilities.screenResolutionX` and `Y` | `stage.stageWidth`, `stage.stageHeight` |
| Window move and resize on mouse down | Delete |
| `GameInput` controller setup (device added and removed, gamepad setup) | Delete. Controllers arrive as keyboard keys through gptokeyb (doc 09) |
| `NativeApplication` KEY_DOWN back button and CLOSING handler | Delete |
| Fullscreen toggles and quality toggles tied to `fullScreenSourceRect` | Force fullscreen true in saved data, drop the toggle |
| Directory listing with `File` | Static manifest (section 9) |
| Dev only writers (`SavePNG`, `SaveXML`) | Empty bodies |

### Saves

Ruffle keys saves by the SWF URL path, which differs between firmwares, and it canonicalizes symlinks, so a symlink trick does not help. `SharedObject.getLocal(name, "/")` is path independent. Route all worlds through the shell for saving, and launch with `--save-directory "$GAMEDIR/saves"`. Files appear as `saves/localhost/<name>.sol`. The same storage code is used by desktop Ruffle and ruffle_sdl, so switching front end keeps progress.

### Quit

`fscommand("quit")` closes the player in Ruffle. Use it wherever `exit()` was called (the original had it in more than one place, count them with the anchor).

### Boot flashvars through `-P`

Let the shell read `loaderInfo.parameters` and pass the parameters on the command line. This enables deterministic tests and the relaunch mechanism.

```
ruffle_sdl ... -Pgame=<world> -Plevel=<level> -Pdoor=0 -Paspect=extend -Pworldfps=30 <shell>.swf
```

Quoting: a value with spaces passed as one argument made Ruffle try to load `<world>%20<menu>%20-1/...swf` (FetchError). If the wrapper `eval`s its arguments (westonwrap does), escape the quotes. Prefer parameters without spaces.

### Relaunch per sub movie

Because Ruffle never frees unloaded movies (doc 01, doc 05), the shell restarts the player when it needs to enter a world it has not loaded yet:

1. Shell `LoadGame` saves, then calls `fscommand("relaunch", game + " " + level + " " + door)`.
2. `preLoadGame` (preloading the next world) returns immediately.
3. `ruffle_sdl` prints `RUFFLE_RELAUNCH <args>` on stdout and exits.
4. `run-ruffle` (the wrapper) restarts the binary with `-Pgame ... -Plevel ... -Pdoor ...`.

Result: about 300 MB free on entering a world instead of 93 MB, at the cost of a short black screen.

### Manifest instead of directory listing

`AssetManager.enqueue(File dir)` and `File.resolvePath` do not work in Ruffle. Generate a static file table at build time (for example PNG names derived from the `.atf` file names plus the matching `.xml`), then enqueue relative URLs one by one. Remaining `appDir.resolvePath(` calls become plain relative URLs (an anchor with an explicit `count=`). `tools/delivery/make_manifest.sh` produces the file list, see doc 03.

### Mouse only options

If a settings screen is mouse only, give the shell button driven alternatives. For example, map L1 and L2 (through gptokeyb to keys `m` and `n`) to cycle music and sound volume 100%, 50%, 0%, save the value like the overlay sliders do, and show a short fading note on the stage. Check zero special cases when you drive a game setting from the shell: in one world `setMusic(0)` paused the music without setting the volume, so raising it later never resumed. Send `Math.max(v, 0.001)` instead of 0.

## 8. Relative path differences

Ruffle resolves a relative URL against the root movie, AIR resolved against the loading SWF. A world in a subfolder that loaded `<sub>/char.swf` found it next to the world SWF in AIR but at the root in Ruffle. The fix in the example port was to move the folder to the game root at setup. Use `rm -rf dest && mv src dest` so a fresh copy wins over a stale one (doc 03). This was found only by playing every world, so test each one in gameplay (doc 10).

A related case: an AS3 world derived its own path from its URL. A type error that aborted startup left that value unset and the world looked for its files at the root. Fixing the type errors fixed the path. Do not patch paths before the type errors are gone.

## 9. Backdrop colour and screen fitting

The original often rendered at the screen aspect through `stage.fullScreenSourceRect`, which Ruffle lacks. The shell patch therefore:

- Sets `StageScaleMode.NO_SCALE` and scales the game itself to `min(stageW/origW, stageH/origH)` (fit) or `max(...)` (fill).
- Fills the stage with the SWF's `backgroundColor`, not black. A black backdrop placed at depth 0 made a black character invisible in rooms without background art.
- Draws black only outside the game rectangle in fit mode, and draws a black frame above the game so art that spills past the content area does not cover the bars.
- Centres vertically in fit mode only. In extend mode on wide screens, anchor at x = 0, do not centre (centring shifted the world right and cut the HUD).
- White bars in fit mode came from the stage colour. `--letterbox on` did not help.

See doc 08 for the aspect modes in full.

## 10. Taller or wider views in AS2 worlds

AS2 worlds computed `scaledStageHeight` but only widened `ScrollRect.width`. The P-code fix adds `ScrollRect.height = scaledStageHeight + 10`, and `setBounds()` (which centred narrow rooms only horizontally) gets the same logic for Y. Pitfall: after you extend the camera, grep every use of the view height in fall and death checks. A kill line written as `_y > -MinY + 700` fired 20 px above the level bottom at 720x720. Changing `Push 700` to `scaledStageHeight + 220` made the kill line the same at 640x480, 720x720, 1024x768, 1280x720 and 1920x1080. Check each SWF separately, because in other worlds the bound came from level data. A pause overlay drawn for 480 tall needs an injected black fill past that height when the view is taller.

## 11. Game clock and quality constants

- A world ticked 0.5 or 1.0 by a 25 ms threshold (0.65x to 1.3x speed near 60 fps). Another hard coded a `timeDelta` of 0.5 (0.67x speed at 40 fps). Replace with a `getTimer()` based step. Read the SWF frame rate (doc 01) and check whether logic is per frame or per time before trusting any fps setting.
- Quality multipliers cause out of memory: AS2 worlds pre rendered levels at `bitRes 1.5`. Patching `Push "bitRes", 1.5` to `1` (a `DefineLocal` in one world, a `SetVariable` in another) fixed OOM on 1 GB. Going to 0.5 saved about 75 MB and 3 fps but looked blocky, so it was rejected. Memory savings that visibly change the art get rejected.
- Starling padding: `ConcretePotTexture` pads non power of two bitmaps with `buffer.copyPixels(data, data.rect, sOrigin)`, which in Ruffle read a GPU drawn bitmap back each frame. Patch it to `buffer.draw(data)`.

## 12. ATF in the Starling SWF

Embedded atlases that load with `Texture.fromAtfData(..., scale, ...)` are replaced by a `Loader` of the extracted PNG plus `Texture.fromBitmapData(bmp, false, false, scale * downscale)`. Atlas XML attributes are multiplied at runtime by an AS3 regex helper (use single quoted AS3 strings: quote escaping got lost between Python and AS3 and caused an XML parse error). See doc 07.

## 13. Debug trace injection

A debug variant of a patched class can print state from the Ruffle log, for example once per second with `if (getTimer() % 1000 < 17) trace("[dbg] x=" + x + " y=" + y)`. Compare your own marker lines such as `[port] FAILED to load` (put one in IO_ERROR handlers).

## 14. Worked generic example

Goal: take an AIR shell `Shell.swf` (AS3) and an AS2 world `World1.swf`, and produce `Shell-port.swf` and `World1.swf` patched.

```python
# patch_shell.py  (run by tools/swf/ffdec.sh helpers, anchors are examples)
import sys
sys.path.insert(0, "tools/swf")
from anchor import Patch

src, dst = sys.argv[1], sys.argv[2]
p = Patch.load(src + "/scripts/Main.as")

# 1. imports
p.sub("import com.vendor.steam.*;\n", "", count=1)
p.sub("import flash.desktop.*;\n", "", count=1)
p.sub("import flash.filesystem.*;\n", "", count=1)

# 2. AIR calls
p.sub("NativeApplication.nativeApplication.exit();", 'fscommand("quit");', count=2)
p.drop_method("setupGameInput")
p.drop_method("onWindowMove")

# 3. saves: replace Steam style file access by a SharedObject
p.sub("steam.fileWrite(name, data);",
      'var so:SharedObject = SharedObject.getLocal("mygame", "/"); so.data[name] = data; so.flush();',
      count=1)

# 4. boot flashvars
p.sub("var game:String = 'menu';",
      "var game:String = loaderInfo.parameters.game || 'menu';", count=1)

# 5. relaunch before entering an unloaded world
p.sub("function LoadGame(g:String, l:int) {",
      "function LoadGame(g:String, l:int) { SaveGameData(); "
      "fscommand('relaunch', g + ' ' + l + ' 0'); return; }", count=1)

p.forbid(["Steamworks", "nativeWindow", "NativeApplication", "GameInput", "File."])
p.save(dst + "/Main.as")
p.report()
```

Build and test:

```
tools/swf/ffdec.sh as3 Shell.swf work/shell_src Main
python3 patch_shell.py work/shell_src work/shell_out
tools/swf/ffdec.sh replace-as3 Shell.swf Shell-port.swf Main work/shell_out/Main.as
python3 tools/swf/swf_info.py Shell-port.swf
# run under Xvfb on the PC with the patched ruffle_sdl, see doc 10
```

AS2 world: export P-code, find the script by content, apply a literal OLD to NEW substitution with a count, replace by script name, then dry run to see which patches hit which SWF.

When it works, bump the patch version, build deltas (doc 03), and test the full device path.

## Pitfalls

- Decompiling and recompiling every class. Replace only what you change.
- Anchors without counts, or counts that were never checked against a second game version.
- Wildcard imports with unqualified types in injected code.
- Using a newer library API than the one the SWF bundles.
- Forgetting that AS2 P-code script names need the leading slash.
- Patching a path before fixing the startup type error that caused it.
- Black backdrop, white bars, or centring in extend mode.
- Hard coded view heights in death checks after extending the camera.
- A volume setter that special cases zero.
- Not testing every world in gameplay. The subfolder path bug appeared only there.
- Naming an emulator folder in a setup script. Build patches from a clean store download.
- Quoting flashvars with spaces.

## See also

- 01 Feasibility (what Ruffle lacks).
- 03 Delivery (deltas, markers, patcher).
- 05 Memory (relaunch reasoning).
- 07 Textures and ATF.
- 08 Screen and aspect.
- 09 Input (gptokeyb keys and software cursor).
- 10 Testing.
- `tools/swf/README.md`, `tools/swf/anchor.py`, `tools/swf/example_patch.py`, `tools/swf/snippets/`.

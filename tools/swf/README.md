# tools/swf: SWF inspection and patching

Small, dependency free helpers for turning an AIR or desktop Flash game into something
Ruffle can run, by patching the game's SWF files from a script instead of shipping a
modified copy. The idea is always the same: decompile the few classes you must change,
apply anchored edits that fail loudly, recompile only those classes, then ship the
difference as a binary delta (see ../delivery).

| File | Purpose |
| --- | --- |
| swf_inflate.py | CWS (zlib) and ZWS (LZMA) to FWS (uncompressed). FWS is copied unchanged. |
| swf_info.py | Version, compression, stage size, frame rate, frames, AVM1 or AVM2, DefineBinaryData and ATF count. |
| anchor.py | Importable library for exact match source patching. |
| ffdec.sh | Wrapper around JPEXS ffdec: decompile and replace AS3 classes or AS1/AS2 P-code. |
| example_patch.py | Documented template that strips AIR APIs from an AS3 shell. |
| snippets/ | Reusable AS2 and AS3 code fragments (not game specific). |
| tests/test_swf_tools.py | Unit tests for inflate, info and anchor. |

Run the tests with `python3 tools/swf/tests/test_swf_tools.py`. Python 3.8 or newer, no packages.

## swf_inflate.py

    python3 swf_inflate.py <in.swf> <out.swf>

Exit codes: 0 ok, 1 usage, 2 input unreadable, 3 not a SWF or corrupt data.

Why inflate: a delta against a compressed stream is useless, because one changed byte
changes everything after it. Patch and diff the uncompressed form, and inflate the
original on the device before applying the delta.

ZWS layout (SWF 13 and newer may use LZMA):

    offset  size  meaning
    0       3     'ZWS'
    3       1     version
    4       4     uncompressed file length, little endian, including the 8 byte header
    8       4     compressed length (ignored here, writers disagree about it)
    12      5     LZMA properties: one byte lc/lp/pb, then a 4 byte dictionary size
    17      ...   raw LZMA data, no end marker length

This is not a standard .lzma file. A .lzma "alone" header is props (5 bytes) followed by the
uncompressed size (8 bytes), then data. The script rebuilds that header from the SWF fields
(props from bytes 12 to 16, size from bytes 4 to 7 minus 8) and uses Python's
`lzma.FORMAT_ALONE`. CWS is simply `zlib.decompress` of everything after byte 8. The
output keeps the version and length field and replaces the signature with 'FWS'.

## swf_info.py

    python3 swf_info.py game.swf [more.swf ...]

Prints version, compression, uncompressed length, stage size in pixels, frame rate, frame
count, whether the SWF has DoABC tags (AVM2, ActionScript 3) or only DoAction tags (AVM1,
ActionScript 1 or 2), the number of DefineBinaryData tags and how many of those start with
the ATF signature (embedded GPU textures, see docs/07). Only top level tags are read.

Use it first on every SWF of a game: the AVM1 or AVM2 answer decides the patch route.

## anchor.py

    from anchor import Patch
    p = Patch.load("dec/scripts/Main.as")
    p.sub("old text", "new text")                    # must match exactly once
    p.sub("NativeApplication.nativeApplication.exit();", 'fscommand("quit");', count=3)
    p.sub_regex(r"var\s+x\s*:\s*File\s*=[^;]*;\n", "")
    p.drop_method("initSteam")                       # brace matching, skips strings and comments
    p.insert_after("super();\n", "         boot();\n")
    p.insert_before("public function quit()", "// note\n")
    p.forbid(["Steamworks", "NativeApplication", "nativeWindow"])
    p.save("out/Main.as")
    p.summary()                                      # per step counts, then "patched OK"

Every anchor has an expected count (default 1). A different count aborts with

    patch anchor matched 2x (expected 3): 'NativeApplication.nativeApplication.exit();'

which is how a different build of the game is caught: the patch refuses to half apply.
`forbid` ends with `leftover forbidden references: ...` and line numbers when any listed
identifier is still present, so removed APIs cannot survive by accident. Self test:
`python3 anchor.py --selftest`. For tests use `Patch(text, raise_errors=True)` to get a
`PatchError` instead of `SystemExit`.

## ffdec.sh

JPEXS Free Flash Decompiler 26.3.0 was used and verified. ffdec is located through `FFDEC`
(launcher script or ffdec.jar), then `FFDEC_JAR`, then `ffdec` on PATH. No path is built in.
Java runs headless. Extra pre options such as `-air` go in `FFDEC_OPTS`.

    ffdec.sh as3 game.swf work/dec Main            # one class, any number of names
    ffdec.sh as3 game.swf work/dec 'com.example.+' # a whole package
    ffdec.sh pcode game.swf work/pc                # AS1/AS2 (or AS3) as P-code
    ffdec.sh replace-as3 game.swf out.swf Main work/patched/Main.as
    ffdec.sh replace-pcode game.swf out.swf /frame_1/DoAction work/frame_1.pcode
    ffdec.sh raw -help                             # straight pass through

The commands map to the real ffdec flags: `-selectclass <names> -export script <dir> <swf>`,
`-format script:pcode -export script <dir> <swf>` and
`-replace <in> <out> <ClassOrScriptName> <file> [...]`. Several replacements can go in one
call, which is faster and avoids stacking experimental rewrites. `-replace` prints
"This feature is EXPERIMENTAL"; always test the result. AS3 sources land in
`<dir>/scripts/<package>/<Class>.as`, AS2 P-code in `<dir>/scripts/frame_N/DoAction.pcode`,
`scripts/__Packages/<Class>.pcode` and `scripts/DefineSprite_<id>_<name>/frame_N/DoAction.pcode`.

### Known pitfalls

1. Replace only the AS3 classes you changed. JPEXS recompiles decompiled source slightly
   wrong in places, so each extra class is extra risk. A shell patch that replaces the one
   shell class and a hub patch that replaces three classes are typical.
2. `var f:Function = function():*{}` decompiles as an empty method. A later assignment
   then fails at runtime with `Error #1037: Cannot assign to a method f on Main`. Find empty
   `function X():*{}` methods that are assigned elsewhere (`.X = `) and turn them back into
   `var X:Function = function():*{};`.
3. Unqualified types with overlapping wildcard imports. With both `flash.display.*` and a
   framework such as `starling.display.*` imported, a bare `Sprite` or `Event` can recompile
   to the wrong package. Fully qualify every type in code you inject
   (`new starling.display.Sprite()`, `flash.events.Event`, `flash.net.URLRequest`).
4. AS3 recompiles against playerglobal, which has no AIR classes. Strip the AIR imports
   (`flash.desktop.*`, `flash.filesystem.*`, native extension packages) and every use, then
   run `forbid` for leftovers. The `-air` pre option compiles against airglobal instead, but
   Ruffle only stubs those classes anyway, so stripping is the reliable route.
5. Dead references appear after decompiling, for example listeners for functions that no
   longer exist. Delete them before recompiling, the compiler rejects undefined names.
6. Check the version of a bundled library before injecting calls. A call that exists in the
   upstream release may be named differently in the copy the game ships (a property that
   is `scale` in one version was `scaleFactor` in another). Read the decompiled library class.
7. AS2 P-code script names need a leading slash and forward slashes:
   `/frame_1/DoAction`, `/__Packages/MyClass`, `/DefineSprite_12_Name/frame_4/DoAction`.
   Forms without the slash or with backslashes were rejected. `ffdec.sh replace-pcode`
   refuses names that do not start with `/`. A patcher that only loops over
   `scripts/frame_*/DoAction.pcode` misses `__Packages` and sprite scripts.
8. AS2 is patched as P-code and not recompiled. Use literal multi line anchors copied from
   the export, give new branches their own labels, and reuse an existing end label captured
   by regex from the surrounding function.

## example_patch.py

A documented template, not a patch for any real game. It takes a decompiled directory and
strips AIR for the Ruffle runtime:

    tools/swf/ffdec.sh as3 game.swf work/dec Main
    python3 tools/swf/example_patch.py work/dec Main       # writes work/patched/Main.as
    tools/swf/ffdec.sh replace-as3 game.swf out.swf Main work/patched/Main.as

It shows: removing AIR imports, `NativeApplication.nativeApplication.exit()` to
`fscommand("quit")`, dropping `nativeWindow` code, a SharedObject save replacement,
flashvar boot through `loaderInfo.parameters`, and the forbidden identifier list. Copy it,
read your own decompiled class, and change every anchor and count.

## snippets

Plain text fragments to paste into the inserted text of a patch. They are not compiled
as is. Read the comments first, each lists the imports it needs.

| Snippet | What it gives you |
| --- | --- |
| fscommand_relaunch.as3.txt, .as2.txt | `fscommand("relaunch", args)`: one process per sub movie, because Ruffle never frees unloaded movie libraries. The front end prints `RUFFLE_RELAUNCH <args>`, run-ruffle restarts it. |
| flashvar_boot.as3.txt | Read `game`, `level`, `door`, `aspect` from `loaderInfo.parameters`. |
| sharedobject_save.as3.txt | `SharedObject.getLocal(name, "/")`, path independent saves, plus fileRead and fileWrite shaped helpers. |
| aspect_fit_fill_extend.as3.txt, .as2.txt | NO_SCALE, scale and centre math for fit, fill and extend, the black bars frame drawn above the content, the backdrop colour rule, and the AS2 checklist. |
| stage_size_report.as3.txt | Report `stage.stageWidth` and `stageHeight` (with a minimum) instead of screen resolution or nativeWindow size. |
| volume_step.as3.txt | Step volume 100, 50, 0 percent on two buttons, never sending exactly 0. |
| manifest_directory_listing.as3.txt | Replace directory listings by a table generated at build time. |

Aspect notes in short: run the front end with `--stage-scale movie` so the shell fits
itself. `fit` keeps the design ratio with black bars (draw the bars above the content, art
spills over otherwise), `fill` covers and crops, `extend` gives the game the real screen
size. Extend needs an audit of every constant that assumed the original stage height. Keep
the SWF's own stage colour in the game rectangle, because levels may rely on it, and paint
black only outside it.

## Software cursor snippets

ruffle_sdl hides the system cursor, so a gamepad driven mouse is invisible. Two snippets draw an
arrow from inside the shell, with no front end patch: `snippets/cursor_overlay.as3.txt` (a Sprite
added topmost on the stage, shown on `MOUSE_MOVE`, hidden after an idle timer, `mouseEnabled` false)
and `snippets/cursor_overlay.as2.txt` (a movie clip at a very high depth, `Mouse.addListener`,
hidden after an idle time). Both are generic. The status of each (tested or not) is the second line
of its header and is repeated here: both were compiled with ffdec into small test movies and
verified headless with `tests/cursor_test.sh` (arrow under the pointer after motion, gone after the
idle time, pixel comparison). Neither was tried on a real game shell or on a device.

Adding them: AS3, put the members into the shell's document class and call `installCursorOverlay()`
once the stage exists, using `anchor.py` for the insertion and `ffdec.sh replace-as3` to recompile
that one class. AS2, paste the script into the first frame of the root timeline as source
(`ffdec.sh raw -replace in.swf out.swf /frame_1/DoAction overlay.as`, ffdec compiles small AS1/2
sources) or as P-code with `replace-pcode` (see pitfall 7 and 8 above).

One Ruffle detail at this pin matters for both: inside a mouse move handler `_xmouse` (AS2) and
`stage.mouseX` (AS3) still hold the position of the previous event, so the arrow would lag one
event behind. The snippets read `e.stageX` (AS3) and follow the pointer every frame (AS2) instead.

The other implementations (front end overlay, SDL colour cursor, pointer emulation) are described
in docs/09-input.md.

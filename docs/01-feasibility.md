# 01 Feasibility and anatomy

## When you need this

Read this before you commit weeks to a port. It tells you what a Flash (SWF) or Adobe AIR game is made of, what Ruffle can and cannot run on an ARM handheld, and how to classify each SWF so you know where the work will be. It ends with a decision checklist and a first check you can run on a PC in minutes. If the answer is "no go", stop early and delete the work folder. A cheap no is a good result.

## 1. Anatomy of an AIR game

A desktop AIR release usually looks like this:

| Item | What it is | Fate on a handheld |
|---|---|---|
| `*.swf` | The game. Often one entry SWF (the shell) that loads several sub movies | Kept, patched |
| `META-INF/` and `META-INF/AIR/application.xml` | AIR descriptor (app id, window settings, native extensions list) | Deleted after patching |
| `mimetype` | AIR package marker | Deleted |
| `Adobe AIR/` | The captive AIR runtime for Windows | Deleted (useless on ARM Linux) |
| `*.exe`, `*.dll` | Windows launcher and runtime pieces | Deleted |
| `*.ane` or classes under `com.<vendor>.*` | Native extensions (for example a Steamworks wrapper) | Removed from the code |

There is no AIR runtime for ARM Linux. The only route is to run the SWFs inside Ruffle and patch the shell so it no longer needs AIR. Ruffle plays the role that an engine reimplementation plays for other PortMaster ports: it is already native ARM code.

A typical collection has this shape:

- An AS3 shell SWF that owns saves, settings, input, window handling and a loader for the rest.
- Several world or level SWFs, each either AS2 (Flash 8 era, timeline code) or AS3.
- Optionally one AS3 world built on Starling (a 2D framework on top of Stage3D) with ATF textures.

Typical AIR surface in the shell, which you will have to inventory:

- `flash.desktop.*` (`NativeApplication`, `applicationDescriptor`).
- `flash.filesystem.*` (`File`, `FileStream`, `applicationDirectory`, `resolvePath`).
- `stage.nativeWindow` size, move and resize calls.
- `GameInput` (controller API).
- `Capabilities.screenResolutionX` and `screenResolutionY`.
- `LocalConnection` between shell and worlds (paired channel names). This works in Ruffle unchanged.
- Library loaders such as greensock `SWFLoader`. These also work unchanged.
- Native extensions (Steam, achievements, cloud saves).

## 2. AS2 versus AS3 in Ruffle

Ruffle has two virtual machines. AVM1 runs AS2 (and older) movies, AVM2 runs AS3 movies.

| Script type | Typical content | Ruffle outlook |
|---|---|---|
| AS2 (AVM1) | Flash 8 era levels, timeline code | Runs very well. Needs small fixes (clock, camera bounds, quality constants) |
| AS3 plain 2D | Display list games | Runs well enough |
| AS3 with Stage3D and Starling | GPU 2D frameworks, ATF textures | Probably good but the riskiest. Needs the wgpu renderer and several fixes |
| AS3 shell with AIR and an ANE | The launcher or hub | Does not work unpatched. Strip the AIR parts |

That prediction held in practice: AS2 worlds needed small fixes, and the AS3 Stage3D world needed the most work (texture decoding, graphics data, memory).

Use `tools/swf/swf_info.py` to read the compression, version, frame rate, stage size and a script type guess (AVM1 or AVM2) per file:

```
python3 tools/swf/swf_info.py MYGAME/*.swf
```

It prints, per file, the version, compression (none, zlib CWS or LZMA ZWS), uncompressed length, stage size, frame rate, frame count, `AVM2` when DoABC tags exist or `AVM1 only` when only DoAction tags do, and the number of DefineBinaryData tags and how many of them start with the ATF signature. The script type is a heuristic: only the top level tags are read, so code that lives only inside sprite frames is not seen. Confirm the answer with the decompiler before you plan around it. Exit codes: 0 ok, 1 usage, 2 unreadable, 3 not a SWF.

The SWF frame rate matters for reasoning about game clocks. On an inflated SWF (first byte `F`), the rate is stored right after the stage rectangle. If you need it by hand: `nbits = d[8] >> 3; rb = (5 + 4*nbits + 7) // 8; fps = d[8+rb+1] + d[8+rb]/256`.

## 3. The AIR runtime flag

Ruffle only exposes AIR classes when started with `--player-runtime air`. Without it, loading a shell that touches `File` fails with:

```
Could not resolve class Multiname { ns: ... "flash.filesystem" ... name: Some("File") ... }
```

With the flag, Ruffle stubs most AIR APIs and logs lines like `Encountered stub: AVM2 flash.filesystem.File.applicationDirectory getter`. A stub returns nothing useful, so the shell still has to be patched. The flag only gets you far enough to see the next problem.

## 4. What Ruffle lacks (checked October 2026)

Each item below either became a Ruffle patch, a game patch or an offline conversion in the finished port.

| Gap | Detail |
|---|---|
| `Graphics.readGraphicsData` | Stub that returns an empty Vector (upstream #18103, a fix PR was closed). Code that reads vector shapes for collision sees nothing |
| `NativeApplication.exit()` | No op. Use `fscommand("quit")` |
| `File` and `FileStream` | Stubs (PR #14178 unmerged). Directory listing does not work |
| Native extensions (ANE) | Never supported (#20954). Remove them in the decompiled source |
| Lossy ATF (0x0C and 0x0D) | Not decoded. Only 0x04 CompressedAlpha and JPEG XR RGB or RGBA work. Error text: `Unsupported ATF format: CompressedLossyAlpha` |
| Compressed ATF | Stubbed (#16139). ATF loader crash (#22841) |
| `Stage.fullScreenSourceRect` | Unimplemented (#9765). Falls back to SHOW_ALL. Any AIR "fullscreen quality" option tied to it does nothing |
| `TextureBase.dispose`, `Context3D.driverInfo`, `maxBackBufferWidth` | Stubs |
| Movie library memory | Ruffle never frees a movie's library after unload (upstream #24864). See doc 05 |
| Shape preparation | Ruffle prepares every shape of a SWF at load, so a large AS2 level can use hundreds of MB. See doc 05 |

Stubs you will see when you grep a PC log (`Encountered stub`): `Stage.fullScreenSourceRect` setter and getter, `Loader.load ... addChild at the correct time`, `Dictionary` weak keys, `Capabilities.isDebugger`, `LocalConnection.allowDomain`, `Context3D.maxBackBufferWidth`, `driverInfo`, `NativeApplication.applicationDescriptor`, `Transform.matrix3D`, `LoaderInfo.childAllowsParent`, `DisplayObject.z` setter, `VertexBuffer3D.dispose`, `IndexBuffer3D.dispose`, `System.disposeXML`, `Loader.unloadAndStop`, `Loader.close`, `File` constructor, `url`, `resolvePath`, `exists`, `NativeWindow` x and y, `Stage.nativeWindow`. Counts of 30 to 70 are normal for a shell and a Starling world. A benign AVM1 line, `Tried to instantiate a non-registered character <name>`, only means the game probed an optional linkage name.

## 5. Stage3D, Starling and ATF

Starling draws through `Context3D` (Stage3D). Ruffle implements Stage3D only in its wgpu renderer. Handheld forks of Ruffle that use a custom GLES2 renderer return Unimplemented from `create_context3d`, so they cannot run a Starling world at all. That is why this toolkit builds on the wgpu renderer with an SDL front end (see doc 04).

ATF (Adobe Texture Format) is the container Starling projects use for GPU textures. A game ships ATF files loose per level, or embedded in a SWF as binary data. Lossy ATF holds DXT data (JPEG XR endpoints plus LZMA index bits). Ruffle cannot decode it, and Mali GPUs cannot sample DXT anyway. The practical answer is to convert ATF to PNG once, on the device, at first start. See doc 07 for the format and the converter.

Before choosing a strategy, take an ATF census: count the files, their format byte (0x0C or 0x0D), their sizes (1024 to 4096 square is common) and which are embedded versus loose. This decides first run time and memory.

## 6. Other engines and routes

- Other Ruffle handheld forks (SDL based, ruffle4consoles derived) are fine for AS2 or simple AS3, but cannot run Stage3D. Some need `SDL_VIDEODRIVER=mali` on H700 muOS and lose saves in a `/tmp` session dir.
- Batocera and Knulli's own flash system uses Lightspark on ARM (Ruffle is x86_64 only there). Lightspark implements `readGraphicsData`, Stage3D with ATF and an `--air` mode. It is a possible second engine that this toolkit never tried.
- Official Ruffle aarch64 releases exist, but the nightly binary needs GLIBC_2.39 plus `libfreetype.so.6`, `libssl.so.3` and `libcrypto.so.3`, so it does not run on most handhelds. A self built binary has a GLIBC_2.30 floor and no ssl or freetype dependency. See `ruffle/build-aarch64.sh`.
- Native rewrite (Haxe or OpenFL plus Haxe Starling) is a dead end: weeks of work for tens of thousands of decompiled lines, AS2 logic scattered across timelines with no translation path, and a decompiled port cannot be shared legally.
- Building Ruffle on the device is a dead end: it needs several GB of RAM, Rust and Java, and hours. Ship a reproducible cross build instead.

## 7. Memory and CFW facts that shape feasibility

- Target class: 1 GB handhelds (H700 and similar). The Mali blob's GPU memory counts against the same 1 GB.
- Typical glibc: ArkOS 2.30, AmberELEC 2.36, muOS 2.38 and newer, Knulli 2.40, dArkOS 2.41, ROCKNIX 2.44. Build for the lowest.
- No Vulkan on muOS, Knulli or ROCKNIX for H700. libmali exposes GLES 3.2 only. So the wgpu GLES backend is the one that matters.
- zram and swap are off by default on most firmwares. PortMaster only reports `DEVICE_HAS_SWAP` and `DEVICE_HAS_ZRAM`.
- `libudev.so.1` is present (gilrs needs it).
- Ruffle holds every loaded sub movie resident. A shell that keeps worlds loaded and preloads the next one runs out of memory on 1 GB after a world or two. The fix is to restart the player per sub movie (relaunch, see doc 02 and doc 05).
- Quality or resolution multipliers inside the game (a level pre rendered at 1.5x) can be the difference between fitting and not fitting. They are plain constants in the code. See doc 02.

## 8. Legal model

Bring your own files, ship code only. The port package holds no game data and no GPU blob (the system libmali is used). For SWF ports, ship binary deltas and patch on the device (doc 03). Never ship decompiled source. Build patches from a clean store download of the exact release and drop emulator traces from setup scripts: PortMaster treats Steam emulator tooling as a hard no.

## 9. Decision checklist

Answer these per SWF, then for the whole game.

| Question | Go signal | No go or high risk signal |
|---|---|---|
| Script type of each SWF (`swf_info.py`) | AS2, or plain AS3 | AS3 shell with ANE (needs patching), Stage3D (needs ATF work) |
| Native extensions in the descriptor or code | None, or only one removable (Steam) | Extension that supplies core gameplay |
| Directory listing at runtime (`File.getDirectoryListing`, `AssetManager.enqueue(File)`) | Not used, or replaceable by a manifest | Level content discovered dynamically with no fixed list |
| `fullScreenSourceRect` or native window sizing | Only in the shell, replaceable by stage scaling | Deep in gameplay code |
| `readGraphicsData` use | None, or only for debug | Used for collision |
| ATF formats | 0x02, 0x04 (RGB or RGBA) or none | 0x0C or 0x0D, many 4096 files (convert at first run, plan time) |
| Biggest AS2 level memory in a PC run | Under about 300 MB peak | Over 800 MB peak with no memory patches |
| Frame rate target | SWF at 30, or 60 with simple scenes | 60 fps with heavy vector scenes (budget for 13 to 16 fps on H700 class) |
| Quality multiplier constants | Findable in P-code or source | Baked into assets |
| Controller story | Keyboard mappable (gptokeyb) | Mouse only UI that needs a pointer (add a software cursor, doc 09) |
| Legal and distribution | Delta based, store build identifiable (MD5) | Needs shipped assets |
| Engine alternatives | Not needed | Unity IL2CPP with D3D11 only shaders (shelve) |

Verdict rule: if every row is in the left column or has a known fix, go. If a row depends on a missing Ruffle feature in core gameplay (collision from `readGraphicsData`, ANE gameplay) and you cannot patch it, no go. If the decision depends on feel, port one world end to end first and judge the frame rate on the device before touching the rest.

## 10. Triage per SWF

1. Export one line of facts per SWF: version, compression, stage size, frame rate, script type, size.
2. Decompile each (see doc 02) and grep for the AIR surface in section 1. Write the count per file.
3. Run each one in desktop Ruffle (section 11). Note which ones show a blank white stage. AS2 worlds that wait for the shell handshake (LocalConnection) are normal: they need the shell.
4. List ATF files and formats if the game uses Starling.
5. Rank the files by expected work: AS2 world (small patches), plain AS3 (moderate), shell (large), Stage3D world (largest).

Verify the game's real key handling in the decompiled code before you map controls. A title screen may advertise keys that a release removed, a key may quit a paused level (a soft lock if mapped), and the shell may relay keys to AS2 worlds over LocalConnection.

## 11. Headless PC first check

Run every SWF on a PC, without opening a window on your desktop. Use a private Xvfb display and turn Wayland off for the process:

```
Xvfb :77 -screen 0 1280x720x24 &
XV=$!
trap 'kill -9 $XV' EXIT
DISPLAY=:77 WAYLAND_DISPLAY= ruffle --player-runtime air MYGAME/<shell>.swf &
sleep 10
import -window :77 shot.png    # ImageMagick, desktop Ruffle only
```

Notes:

- `import -window root` works with desktop Ruffle. For `ruffle_sdl` (GL output) it gives black, so use the test hooks in `tests/` (see doc 10).
- Do not use `--base` with a plain path. It fails with `invalid value '/.../<world>' for '--base <BASE>': relative URL without a base`. Pass a file URL or leave `--base` out.
- Read the log for `Encountered stub` and for `Could not resolve class`. Those two tell you most of the story in minutes.
- Boot through the shell. Opening an AS2 world alone shows a blank white stage because it waits for the shell (`ConfirmShell`, `setDimensions`). That is not a regression.
- A directly booted world may lack a given level (white screen). Check the level exists before suspecting your patch.

If a PC run reaches gameplay in at least one AS2 world and the shell reaches a menu with the AIR parts stubbed, the port is feasible. Then continue with doc 02.

## Pitfalls

- Trusting the store build. Patches are valid only for the exact release you built them from. Pin it with MD5 checks (doc 03).
- Using the official nightly aarch64 binary. It needs GLIBC_2.39 and shared libraries most handhelds lack.
- Waiting for upstream to free movie libraries (#24864, PR #23071 is open and conflicting). Pin a Ruffle commit and relaunch per sub movie.
- Assuming an AIR window or fullscreen option works. Anything tied to `fullScreenSourceRect` or `nativeWindow` is dead in Ruffle.
- Booting a world without the shell and calling the white screen a bug.
- Ignoring the memory cost of large AS2 levels until the device kills the process. Measure the peak on the PC first.
- Choosing a native rewrite or an on device Ruffle build.
- Forgetting one firmware has no Vulkan. Test the GLES path.

## See also

- 02 Shell patching (removing AIR APIs, P-code, backdrop).
- 03 Delivery (deltas, patcher, markers).
- 04 ruffle_sdl (front end and Stage3D renderer).
- 05 Memory (library retention, lazy shapes, relaunch).
- 07 Textures and ATF (decode lossy ATF).
- 10 Testing (Xvfb and in process capture).
- `tools/swf/README.md`, `tools/swf/swf_info.py`.

# 07 Textures and ATF

## When you need this

Read this when the game contains a Starling or other Stage3D world with ATF textures (files ending in `.atf`, or binary data embedded in a SWF whose payload starts with `ATF`). Ruffle cannot decode lossy ATF and Mali GPUs cannot sample DXT, so the port converts ATF to PNG once, on the device, at first start, usually at reduced resolution. This doc describes the format, the converter `atftool`, how to patch the SWF to load PNGs, and how to scale atlas coordinates to match.

## 1. Why convert, and why offline

- Ruffle's `render/src/atf.rs` parses the ATF container but counts lossy (0x0C and 0x0D) records without decoding them. Only 0x04 CompressedAlpha and JPEG XR RGB or RGBA are supported. A lossy file raises `Unsupported ATF format: CompressedLossyAlpha`.
- Mali has no BC or S3TC texture support. The H700 libmali (r20p0) is GLES 3.2 with EGL fbdev and no `vk*` symbols, and ROCKNIX H700 ships Panfrost GL only. Even a decoder that kept DXT would have nothing to upload it to.
- So: decode the ATF to PNG at first start, load the PNG from code. No game content is shipped, the user's own files are converted.

An ATF census before you pick a strategy is cheap. Read the header and count `(version, format, width, height)`. In the example there were 23 files: 5 of format 0x0C and 18 of 0x0D, 1024 to 4096 square, only 2 embedded in the hub SWF and the rest loose per level. Lighting and normal maps were off by default and need no conversion.

## 2. ATF v3 format notes

Header:

| Offset | Size | Meaning |
|---|---|---|
| 0 | 3 | `ATF` |
| 3 | 3 | Total length of the file, u24 big endian |
| 6 | 1 | `0xFF` marker. It means the file has a version byte (version 1 and later). If this byte is anything else the header is the legacy one (see below) |
| 7 | 1 | Version (3 for the lossy formats) |
| 8 | 4 | Length of the rest of the file, u32 big endian |
| 12 | 1 | Format. Low 7 bits are the format, bit 7 is the cubemap flag |
| 13 | 1 | log2 width |
| 14 | 1 | log2 height |
| 15 | 1 | Mip count |

In the legacy header (byte 6 is not `0xFF`) the format byte is already at offset 6, followed by log2 width, log2 height and the mip count, and the texture data starts at offset 10. `atftool` treats that as version 0.

Per mip the data is a list of records, each a length followed by the payload. The length is u32 big endian for version 1 and later and u24 big endian for the legacy header, and the converter handles both.

Formats and record counts per mip:

| Format byte | Name | Records per mip |
|---|---|---|
| 0x02 | Compressed (DXT1, not lossy) | 11 |
| 0x04 | CompressedAlpha (DXT5, not lossy) | 16 |
| 0x0C | CompressedLossy | 12 |
| 0x0D | CompressedLossyAlpha | 17 |

The records after the ones you need hold PVRTC, ETC1 and ETC2 data and are empty in these files. Lower mips are empty too. The decoder uses the first mip of the first face only.

How lossy ATF encodes DXT:

- 0x0C (DXT1 colour):
  - record 0 is LZMA (5 byte props, no size field) holding 4 bytes per block of DXT1 index bits.
  - record 1 is a JPEG XR image, 16 bits per pixel BGR565, of size (w/4) by (h/2). The top half holds colour0 of every block, the bottom half holds colour1.
- 0x0D (DXT5 colour plus alpha):
  - record 0 is LZMA with 6 bytes per block of DXT5 alpha index bits.
  - record 1 is a JPEG XR 8 bit gray image holding alpha0 and alpha1.
  - record 2 is LZMA with 4 bytes per block of colour index bits.
  - record 3 is JPEG XR BGR565 holding the colour endpoints.

So "lossy ATF stores JPEG XR that the runtime transcodes" is only half right: the JPEG XR holds only the endpoint colours and alphas, the index bits are LZMA. The loss is in the endpoints.

Black areas in a decoded 0x0C image are power of two padding, not a decode bug.

The authoritative source for the layout is Adobe's `dds2atf` encoder (MIT licensed: `pvr2atfcore.cpp`, functions `write_dxt1` and `write_dxt5`, plus `atf.h`). It is not shipped here, credit Adobe.

### Raw LZMA details

The LZMA blobs are raw streams, not `.lzma` files. Props byte `p`: `lc = p % 9`, `lp = (p / 9) % 5`, `pb = p / 45`. The dictionary size is a u32 little endian in bytes 1 to 4. Data starts at byte 5. In Python:

```python
dec = lzma.LZMADecompressor(
    lzma.FORMAT_RAW,
    filters=[{"id": lzma.FILTER_LZMA1, "lc": lc, "lp": lp, "pb": pb,
              "dict_size": max(ds, 4096)}])
out = dec.decompress(blob[5:], max_length=expected)   # expected = blocks * 4 (or * 6)
assert len(out) == expected
```

The converter injects a u64 size before the data when it uses a library that wants one.

### Discover the layout before writing a decoder

Dump each file's header (version, format, size, mip count) and each record's length and kind. A record is LZMA if its first byte is `0x5d`, JPEG XR if it starts with `WMPH`, otherwise hex dump. That survey is what showed the format was not what the first guess said.

## 3. The converter: `atftool`

`tools/atf` is a Rust crate that produces a small static ARM binary (about 650 KB, GLIBC_2.30 max, only libc, libm, libpthread, libgcc_s and ld-linux needed), so the device needs no Python. It reuses the crates Ruffle itself uses: `jpegxr`, `lzma-rs`, `texture2ddecoder`, `image` (png only), `flate2`.

Subcommands:

```
atftool atf  <scale> <out_dir> <file.atf>...     # convert loose ATF files to PNG
atftool swf  <scale> <out_dir> <file.swf>        # extract and convert embedded ATF
atftool inflate <in.swf> <out.swf>               # CWS and ZWS to FWS (FWS is copied)
atftool atlasxml <factor> <in.xml> <out.xml>     # scale atlas coordinates
atftool info <file.atf>                          # print version, format, size, mips, record sizes
```

Decoded formats are 0x02, 0x04, 0x0C and 0x0D (first mip of the first face). The uncompressed formats 0x00, 0x01 and the raw formats 0x03 and 0x05 are rejected with `unsupported ATF format`, and cubemaps decode only their first face. See `tools/atf/README.md`.

Behaviour:

- `<scale>` is a factor such as `1.0` or `0.5`. A 4096 square ATF at 0.5 becomes a 2048 PNG.
- Output lines are `OK <path> [fmt WxH] Ns` or `ERR <name>: <error>`. Exit status is 0 on success, 1 if any file failed, 2 for usage errors.
- The PNG is written to `<name>.png.tmp` and then renamed, so an interrupted run leaves no half file.
- `swf` mode reads DefineBinaryData (tag 87) whose payload at offset 6 starts with `ATF`. It names the output from SymbolClass (tag 76). Naming is a heuristic: some build tools name embedded assets `<Something>_atf_<Name>`, and by default the part after the last `_atf_` is used (`Foo_atf_Sheet` becomes `Sheet.png`). Set `ATFTOOL_RAW_NAMES=1` to keep the full SymbolClass name instead. A class name without `_atf_` is used as is either way, and a tag with no SymbolClass entry becomes `binary<id>.png`. It handles FWS, CWS and ZWS.
- Decoding goes through `texture2ddecoder` (BC1 or BC3), converts 0xAARRGGBB to RGBA, optionally resizes with a triangle filter, and writes PNG.
- Cost on a PC: a 4096 square file takes 0.9 to 2.1 seconds, 2048 square 0.2 to 0.4 s. On an H700 class device about 1.5 minutes for 23 large textures, one patcher step per texture.

You normally do not write that loop yourself. The template patchscript reads `tools/patch/atf.txt` (one `kind|scale|input|outdir` line per job) and calls `atftool` for you, skipping jobs whose output already exists:

```
atf|0.5|World/level1.atf|World
swf|0.5|World.swf.orig|World/assets/_embedded
```

An `atf` job is skipped when `<outdir>/<name>.png` exists (the converter renames a finished file into place, so an existing PNG is complete). A `swf` job is skipped when the marker `<outdir>/.done.<swf name>` exists, which the patchscript creates after a successful extraction. Atlas XML scaling is `tools/patch/atlas.txt` (`factor|file.xml`), see doc 03.

### Cross building

The `jpegxr` crate generates C bindings at build time, so bindgen needs libclang. The cross image sets:

```
BINDGEN_EXTRA_CLANG_ARGS_aarch64_unknown_linux_gnu="--target=aarch64-linux-gnu -I/usr/aarch64-linux-gnu/include"
```

with `libclang-dev` and `clang` installed, and release flags `lto`, `codegen-units = 1`, `strip`, `panic = "abort"`. Check the GLIBC floor and NEEDED libraries on the built binary (`objdump -T`, `readelf -d`).

### Licences

Ship the licence texts of what the converter links: the BSD 2 clause jxrlib notice for the `jpegxr` crate, plus lzma-rs, texture2ddecoder, image, flate2 and the Apache 2.0 crates (moxcms, pxfm).

## 4. Loading PNGs in the SWF

Patch the Starling world (doc 02) so it loads PNGs instead of ATF:

- Embedded atlases: replace `Texture.fromAtfData(..., scale, ...)` with a `Loader` that loads the extracted PNG by URL (`loader.load(new URLRequest(url))`), then `Texture.fromBitmapData(bmp, false, false, scale * downscale)`. The first version replaced the binary data and used `Loader.loadBytes`. Loading by URL turned out simpler.
- Embedded PNGs go to `<world>/assets/_embedded/*.png`.
- `AssetManager.enqueue(File)` becomes a per file enqueue from a static table, with `scaleFactor = texture_scale` (check which property your bundled Starling version has, doc 02).
- Dev only SavePNG and SaveXML writers become no-ops.
- Put a trace in the IO_ERROR handler (`[port] FAILED to load`) so a missing PNG shows up in the log.

## 5. Reduced resolution

Decode at 0.5 to cut GPU memory by 4x per texture (a 4096 RGBA texture is 64 MB, 2048 is 16 MB). Then:

- The Starling texture scale must be the original scale times the downscale (for example `1.6 * 0.5` in the example).
- The scale constant used on the device (`SCALE="0.5"` in the patch script) must equal the scale baked into the SWF delta. Keep them in one place.
- Do not halve pixel art without checking. In another port, halving textures damaged pixel art and the user noticed. Measure texels per art pixel, shrink only by lossless 2x or 4x or for huge sheets, and prefer the game's own render scale options. Test losslessness by nearest down then up and compare bytes, and compare against a stock PC baseline. Non integer scales give uneven pixels. Pick factors whose pixels land on whole screen pixels. Memory savings that visibly change the art get rejected.

Alternative, not used in Ruffle: ASTC. PortMaster ships `astcenc`, ASTC 4x4 is a quarter of RGBA memory and Mali G31 and G52 (blob) and Panfrost support it, but desktop GPUs cannot test it, Ruffle has no ASTC path, and palette index art must not be ASTC compressed.

## 6. Atlas coordinates

A Starling atlas XML is in original pixels, divided by the texture scale. When the PNG is half size, every coordinate must be halved or doors, effects and tilesets come out wrong (in the example a level smeared into streaks). Scale these attributes by the factor: `x`, `y`, `width`, `height`, `frameX`, `frameY`, `frameWidth`, `frameHeight`, `pivotX`, `pivotY`.

Atlases can live in two places and both need scaling:

1. Embedded in the AS3 code (a string or an `[Embed]` XML). Patch in an AS3 helper that applies a regex to those attributes at runtime. Use single quoted AS3 strings, because quote escaping got lost between Python and AS3 and caused an XML parse error.
2. Loose XML files on disk next to the level textures. Scale them on the device:

```
atftool atlasxml 0.5 level1.xml.orig level1.xml
```

Keep the pristine `level1.xml.orig`. If the XML differs from `.orig` and from the scaled `.orig`, treat it as a fresh user copy and make it the new `.orig` (doc 03). Verify `.orig` against the manifest md5. Missing the on disk ones made doors and effects the wrong size in some levels, so grep for every XML that a level loads.

## 7. Memory and speed benefit

- A 4096 square RGBA texture decoded at 0.5 uses a quarter of the memory. The Mali blob's GPU memory counts against the same 1 GB, so this is one of the main reasons a Stage3D world fits.
- Decoding once means later starts only read PNGs. Do not decode at every start.
- A vector clip drawn into a BitmapData every frame and then uploaded is a different problem. One GPU texture copy change made a character invisible because offscreen draws were not submitted before the copy. It was fixed by a renderer flush before the copy (doc 04 and doc 06 cover the renderer side).

## Pitfalls

- Believing lossy ATF is "just JPEG XR". The index bits are LZMA.
- Forgetting the 0xFF version marker and mis reading v0 files (3 byte lengths).
- Forgetting to scale the atlas XML, or scaling only the embedded one.
- Scale constant in the patch script not equal to the scale in the SWF delta.
- Halving pixel art that is not lossless to halve.
- Quoting in the AS3 regex helper.
- `atftool inflate` and `tools/swf/swf_inflate.py` both accept CWS and ZWS and copy FWS unchanged, so either can prepare a SWF for a delta.
- Embedded ATF names that do not follow `Foo_atf_Name`: the output falls back to `binary<id>.png`. Check the log.
- Building the converter without libclang for bindgen.
- Leaving a half written PNG. Always write temp then rename, and verify each PNG after conversion.
- Converting everything on every start. Use the converted marker and the per file existence check.

## See also

- 01 Feasibility (ATF census, what Ruffle lacks).
- 02 Shell patching (Starling class patches, scale helpers).
- 03 Delivery (manifest, converted marker, convert only missing outputs).
- 05 Memory and 06 Performance (texture memory).
- `tools/atf/README.md`, `tools/atf/src/`.
- Adobe `dds2atf` (MIT) for the authoritative encoder.

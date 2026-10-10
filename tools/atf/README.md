# atftool

A small Rust tool for Flash/AIR games that ship Adobe ATF textures. Ruffle cannot decode lossy ATF, and many handheld GPUs (Mali) cannot sample DXT, so the textures are converted to PNG once, offline or on first run on the device, and the game loads the PNGs instead.

One static binary, no Python. About 700 KB stripped on x86_64, no libraries beyond libc, libm, libpthread and libgcc_s.

## Commands

```
atftool atf <scale> <out_dir> <file.atf>...    convert loose ATF files to <out_dir>/<name>.png
atftool swf <scale> <out_dir> <file.swf>       extract and convert ATF textures embedded in a SWF
atftool inflate <in.swf> <out.swf>             rewrite a CWS or ZWS SWF as uncompressed FWS
atftool atlasxml <factor> <in.xml> <out.xml>   scale Starling atlas XML coordinates
atftool info <file.atf>                        print version, format, size, mip count, record sizes
atftool --help
```

`<scale>` is a float. 1 keeps the size, 0.5 halves it with a Triangle filter. Only the first mip of the first face is decoded.

Output lines: `OK <path> [<fmt> <W>x<H>] <N>s` on stdout for each converted texture, `ERR <name>: <error>` on stderr for each failure. Each PNG is written as `<name>.png.tmp` and then renamed, so a killed run never leaves a half written PNG under the final name. Exit code 2 for a usage error, 1 if any texture or the whole run failed, 0 otherwise.

### swf mode and names

`swf` reads every DefineBinaryData tag whose payload starts with `ATF`. The PNG name comes from the SymbolClass tag when the tag id is listed there, otherwise it is `binary<id>`.

The name rule is optional and a heuristic. Some build tools name embedded assets `<Something>_atf_<Name>`. By default the part after the last `_atf_` is used (`Foo_atf_Sheet` becomes `Sheet`). Set `ATFTOOL_RAW_NAMES=1` to keep the full SymbolClass name. A class name without `_atf_` is used as is either way.

### inflate

`inflate` supports CWS (zlib) and ZWS (LZMA). An FWS file is copied unchanged. Use it before computing binary deltas so patches stay small and independent of the compression.

### atlasxml

Starling texture atlas XML stores pixel coordinates in original pixels. When a texture is converted at a reduced scale, scale the XML by the same factor. The attributes `x`, `y`, `width`, `height`, `frameX`, `frameY`, `frameWidth`, `frameHeight`, `pivotX` and `pivotY` are multiplied by the factor. Every other attribute and all other text is left untouched. Atlas data can live both on disk and embedded in code, so check both places.

Scaling textures can damage pixel art. Prefer lossless factors (exact 2x or 4x) or huge sheets, and compare against an unscaled baseline.

## ATF format notes

Source: INVENTORY.md section 07, checked against Adobe's encoder (https://github.com/adobe/dds2atf, file `pvr2atfcore.cpp`, functions `write_dxt1` and `write_dxt5`). That repository is the only authoritative description of the lossy layout.

### Header

```
offset  size  field
0       3     "ATF"
3       3     total length (u24 big endian)
6       1     0xFF for version 1 and later; otherwise this byte is already the format byte (legacy header)
7       1     version (v3 for the lossy formats)
8       4     length of the rest of the file (u32 big endian)
12      1     format byte: low 7 bits format, bit 7 set for cubemaps
13      1     log2 width
14      1     log2 height
15      1     mip count
16      ...   texture data
```

For the legacy header (byte 6 is not 0xFF) the format byte is at offset 6 and the texture data starts at offset 10.

### Texture data

For each face (1, or 6 for cubemaps) and each mip level there is a fixed number of records. Every record is a length followed by the payload: u32 big endian for version 1 and later, u24 big endian for the legacy header. Lower mips are normally present as empty records.

| Format | Name | Records per mip |
| --- | --- | --- |
| 0x02 | Compressed | 11 |
| 0x04 | CompressedAlpha | 16 |
| 0x0C | CompressedLossy | 12 |
| 0x0D | CompressedLossyAlpha | 17 |

The records in a mip hold the DXT payload first, then (empty here) PVRTC, ETC1 and ETC2 variants.

### DXT1 (0x02, 0x0C): records 0 and 1

* Record 0: LZMA stream holding the 4 bytes per 4x4 block of DXT1 index bits.
* Record 1: JPEG XR image of size (w/4) by (h/2), one pixel per block. The top half is endpoint 0 (color0) of every block in row major order, the bottom half is endpoint 1 (color1). The pixels are 16 bit BGR565 as written by the encoder. The tool also accepts 24 bit planes.

Block i is rebuilt as color0 (2 bytes), color1 (2 bytes), index bits (4 bytes) and decoded as BC1.

### DXT5 (0x04, 0x0D): records 0 to 3

* Record 0: LZMA stream of 6 bytes per block of DXT5 alpha index bits.
* Record 1: JPEG XR 8 bit gray plane (w/4) by (h/2): top half alpha0, bottom half alpha1.
* Record 2: LZMA stream of 4 bytes per block of colour index bits.
* Record 3: JPEG XR colour endpoint plane, same layout as DXT1 record 1.

Block i is rebuilt as alpha0, alpha1, 6 alpha index bytes, color0, color1, 4 colour index bytes and decoded as BC3.

### Raw LZMA records

The LZMA records are raw streams: a 5 byte header (props byte, then the dictionary size as u32 little endian) followed directly by the range coder data, with no uncompressed size field. The props byte encodes lc = p % 9, lp = (p / 9) % 5, pb = p / 45. The decoded length is known from the block count (blocks times 4 or 6 bytes), so the tool inserts a u64 little endian size after the 5 byte header and hands the stream to lzma-rs, then checks the output length.

### Known unsupported

* Uncompressed formats 0x00 (RGB888) and 0x01 (RGBA8888), and the raw formats 0x03 and 0x05. They are rejected with `unsupported ATF format`.
* Cubemaps are parsed by `info`, but `atf` decodes only the first face.
* Only the first mip is decoded. Mip chains are not read.
* The PVRTC, ETC1 and ETC2 records are ignored.
* Premultiplied alpha is not undone (the files seen so far did not need it).
* Ruffle itself parses the ATF container (`render/src/atf.rs`) but has no path that turns lossy data into RGBA, which is why this conversion exists.
* The `info` command lists records using the known per mip counts, so unknown formats print the header only.

## Build for the host

```
cargo build --release
```

The binary is `target/release/atftool`. The `jpegxr` crate is the ruffle-rs fork at a pinned revision (see Cargo.toml) and is fetched from GitHub, so the first build needs network. It generates C bindings at build time, so clang/libclang and a C compiler must be installed. To keep build output out of the tree set `CARGO_TARGET_DIR`.

Release profile: opt-level 3, lto, codegen-units 1, strip, panic abort.

## Build for aarch64

```
./build-aarch64.sh <out-dir>            # Docker, writes <out-dir>/atftool
./build-aarch64.sh --native <out-dir>   # no Docker, host clang and lld with an arm64 sysroot
```

The Docker variant uses `../../ruffle/Dockerfile` (the ruffle_sdl cross image, glibc 2.30 floor) when it exists, and otherwise builds a small ubuntu:20.04 image defined in the script. Either image needs clang and libclang for the jpegxr bindings and the bindgen variable `BINDGEN_EXTRA_CLANG_ARGS_aarch64_unknown_linux_gnu="--target=aarch64-linux-gnu -I/usr/aarch64-linux-gnu/include"`. The native variant needs an arm64 glibc 2.31 sysroot (default `~/chroot-bullseye`, override with `SYSROOT`) and `rustup`. Both print the highest GLIBC symbol version and the NEEDED libraries of the result. Set `CARGO_CACHE` to share the cargo registry between runs.

## Tests

```
cargo test
```

The tests need no game files. They build synthetic data in memory:

* ATF files in the v3 and legacy header layouts with all four formats (0x02, 0x04, 0x0C, 0x0D), LZMA index bits encoded with lzma-rs and JPEG XR endpoint planes from `tests/fixtures/` (tiny lossless planes made by `tests/gen_fixtures.py`, which needs numpy and imagecodecs only if you want to regenerate them). Decoded pixels are compared per block, and one test checks that index bits pick between the two endpoints.
* `info` output, truncated and malformed input (no panics), unsupported format.
* SWF files built from generated FWS bytes, converted to CWS and ZWS: `inflate` round trips, and `swf` extraction with and without SymbolClass names.
* Command line behaviour: output lines, `.png.tmp` renamed, scaling, exit codes 1 and 2, `--help`.
* `atlasxml` scaling of the pixel attributes only.

Limit: there is no sample from a production encoder. The synthetic 0x0C and 0x0D files follow the layout above, but their endpoint planes are 24 bit lossless JPEG XR images because no encoder for the 16 bit 565 planes was available. The 565 path (2 bytes per pixel) is therefore not covered by the tests. It matches what the tool did on real lossy files (34 to 44 dB PSNR against a Python reference decoder, the difference coming from the resize filter).

## Licenses

atftool is MIT. It depends on the ruffle-rs jpegxr fork (BSD 2 clause jxrlib notice applies), lzma-rs, texture2ddecoder, image and flate2. Keep their notices when redistributing a binary.

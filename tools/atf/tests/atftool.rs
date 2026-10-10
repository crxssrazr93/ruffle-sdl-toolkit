//! Tests that need no game files. Synthetic ATF and SWF data is built here, endpoint planes are
//! the tiny JPEG XR fixtures in tests/fixtures (see gen_fixtures.py), LZMA index bits are
//! encoded with lzma-rs.
//!
//! Not covered: a real lossy sample from a production encoder. The synthetic 0x0C/0x0D files
//! follow the documented record layout, but use 24bpp lossless JPEG XR planes instead of the
//! 16bpp 565 planes an encoder writes (no encoder for those is available here).

use std::io::{Cursor, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

const COLOR_2X4: &[u8] = include_bytes!("fixtures/color_2x4_rgb24.jxr");
const ALPHA_2X4: &[u8] = include_bytes!("fixtures/alpha_2x4_gray8.jxr");
const COLOR_1X2: &[u8] = include_bytes!("fixtures/color_1x2_rgb24.jxr");

fn lzma_enc(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let opts = lzma_rs::compress::Options { unpacked_size: lzma_rs::compress::UnpackedSize::SkipWritingToHeader };
    lzma_rs::lzma_compress_with_options(&mut Cursor::new(data), &mut out, &opts).unwrap();
    out
}

fn put_record(out: &mut Vec<u8>, legacy: bool, payload: &[u8]) {
    if legacy {
        out.extend_from_slice(&(payload.len() as u32).to_be_bytes()[1..]);
    } else {
        out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    }
    out.extend_from_slice(payload);
}

/// Builds an ATF file. `first` are the leading non empty records; the rest of the first mip's
/// records are empty. Further mips are empty records too when `mips` > 1.
fn build_atf(legacy: bool, format: u8, log_w: u8, log_h: u8, mips: u8, first: &[&[u8]]) -> Vec<u8> {
    let n = atftool::records_per_mip(format).unwrap();
    let mut body = vec![format, log_w, log_h, mips];
    for mip in 0..mips {
        for i in 0..n {
            let rec: &[u8] = if mip == 0 { first.get(i).copied().unwrap_or(&[]) } else { &[] };
            put_record(&mut body, legacy, rec);
        }
    }
    let mut out = b"ATF".to_vec();
    if legacy {
        out.extend_from_slice(&(body.len() as u32).to_be_bytes()[1..]);
    } else {
        out.extend_from_slice(&((body.len() + 6) as u32).to_be_bytes()[1..]);
        out.extend_from_slice(&[0xff, 3]);
        out.extend_from_slice(&(body.len() as u32).to_be_bytes());
    }
    out.extend_from_slice(&body);
    out
}

fn rgba(p: u32) -> [u8; 4] {
    [(p >> 16) as u8, (p >> 8) as u8, p as u8, (p >> 24) as u8]
}

/// 8x8 DXT1, all indices 0, so each 4x4 block is endpoint 0: red, green, blue, near white.
fn dxt1_8x8(legacy: bool, format: u8) -> Vec<u8> {
    let bits = lzma_enc(&[0u8; 16]);
    build_atf(legacy, format, 3, 3, 1, &[&bits, COLOR_2X4])
}

fn check_dxt1_8x8(d: &atftool::Decoded) {
    assert_eq!((d.width, d.height), (8, 8));
    let at = |x: usize, y: usize| rgba(d.pixels[y * 8 + x]);
    for (bx, by, want) in [(0, 0, [255, 0, 0, 255]), (1, 0, [0, 255, 0, 255]), (0, 1, [0, 0, 255, 255]), (1, 1, [255, 255, 255, 255])] {
        for y in 0..4 {
            for x in 0..4 {
                assert_eq!(at(bx * 4 + x, by * 4 + y), want, "block ({bx},{by}) pixel ({x},{y})");
            }
        }
    }
}

#[test]
fn decodes_dxt1_lossy_0x0c() {
    let d = atftool::decode(&dxt1_8x8(false, 0x0c)).unwrap();
    assert_eq!(d.format, 0x0c);
    check_dxt1_8x8(&d);
}

#[test]
fn decodes_dxt1_compressed_0x02() {
    let d = atftool::decode(&dxt1_8x8(false, 0x02)).unwrap();
    assert_eq!(d.format, 0x02);
    check_dxt1_8x8(&d);
}

#[test]
fn decodes_legacy_header_u24_lengths() {
    let d = atftool::decode(&dxt1_8x8(true, 0x0c)).unwrap();
    check_dxt1_8x8(&d);
    assert_eq!(atftool::parse_atf(&dxt1_8x8(true, 0x0c)).unwrap().version, 0);
}

fn dxt5_8x8(format: u8) -> Vec<u8> {
    // rec0 alpha index bits (6 bytes per block), rec1 alpha endpoints, rec2 colour index bits,
    // rec3 colour endpoints.
    let abits = lzma_enc(&[0u8; 24]);
    let cbits = lzma_enc(&[0u8; 16]);
    build_atf(false, format, 3, 3, 1, &[&abits, ALPHA_2X4, &cbits, COLOR_2X4])
}

#[test]
fn decodes_dxt5_alpha_0x0d_and_0x04() {
    for format in [0x0d, 0x04] {
        let d = atftool::decode(&dxt5_8x8(format)).unwrap();
        assert_eq!(d.format, format);
        let at = |x: usize, y: usize| rgba(d.pixels[y * 8 + x]);
        assert_eq!(at(0, 0), [255, 0, 0, 255]);
        assert_eq!(at(7, 0), [0, 255, 0, 128]);
        assert_eq!(at(0, 7), [0, 0, 255, 64]);
        assert_eq!(at(7, 7), [255, 255, 255, 200]);
    }
}

#[test]
fn dxt1_index_bits_select_between_endpoints() {
    // One 4x4 block, endpoint 0 red, endpoint 1 blue. Row r uses index r (0..3).
    let bits = lzma_enc(&[0x00, 0x55, 0xaa, 0xff]);
    let atf = build_atf(false, 0x0c, 2, 2, 1, &[&bits, COLOR_1X2]);
    let d = atftool::decode(&atf).unwrap();
    let row = |y: usize| rgba(d.pixels[y * 4]);
    assert_eq!(row(0), [255, 0, 0, 255]);
    assert_eq!(row(1), [0, 0, 255, 255]);
    // 2/3 red + 1/3 blue, then 1/3 red + 2/3 blue
    let (r2, b2) = (row(2)[0] as i32, row(2)[2] as i32);
    let (r3, b3) = (row(3)[0] as i32, row(3)[2] as i32);
    assert!(r2 > r3 && r3 > 0 && b3 > b2 && b2 > 0, "{:?} {:?}", row(2), row(3));
    assert!((r2 - 170).abs() <= 2 && (b3 - 170).abs() <= 2);
}

#[test]
fn info_reports_header_and_records() {
    let atf = dxt1_8x8(false, 0x0c);
    let text = atftool::info(&atf).unwrap();
    assert!(text.contains("version:    3"), "{text}");
    assert!(text.contains("0x0c CompressedLossy"), "{text}");
    assert!(text.contains("dimensions: 8x8"), "{text}");
    assert!(text.contains("mip count:  1"), "{text}");
    assert!(text.contains("12 records"), "{text}");
    let multi = build_atf(false, 0x0d, 4, 4, 3, &[]);
    let t = atftool::info(&multi).unwrap();
    assert!(t.contains("mip count:  3") && t.contains("face 0 mip 2: 17 records"), "{t}");
}

#[test]
fn rejects_bad_input_without_panicking() {
    assert!(atftool::decode(b"nope").is_err());
    assert!(atftool::decode(b"ATF\0\0\0\xff\x03\0\0\0\0").is_err());
    let unsupported = build_atf_raw_format(0x01);
    let e = atftool::decode(&unsupported).err().unwrap().to_string();
    assert!(e.contains("unsupported ATF format"), "{e}");
    let good = dxt1_8x8(false, 0x0c);
    for cut in [11, 13, 20, good.len() - 5] {
        assert!(atftool::decode(&good[..cut]).is_err(), "cut at {cut}");
    }
    assert!(atftool::info(&good[..20]).is_ok() && atftool::info(&good[..14]).is_err());
}

fn build_atf_raw_format(format: u8) -> Vec<u8> {
    let mut v = b"ATF\0\0\x10\xff\x03\0\0\0\x10".to_vec();
    v.extend_from_slice(&[format, 3, 3, 1]);
    v
}

// ---------------------------------------------------------------------------------------------
// SWF helpers

fn tag(code: u16, payload: &[u8]) -> Vec<u8> {
    let mut v = Vec::new();
    if payload.len() < 0x3f {
        v.extend_from_slice(&((code << 6) | payload.len() as u16).to_le_bytes());
    } else {
        v.extend_from_slice(&((code << 6) | 0x3f).to_le_bytes());
        v.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    }
    v.extend_from_slice(payload);
    v
}

fn binary_data(id: u16, data: &[u8]) -> Vec<u8> {
    let mut p = id.to_le_bytes().to_vec();
    p.extend_from_slice(&[0, 0, 0, 0]);
    p.extend_from_slice(data);
    tag(87, &p)
}

fn symbol_class(entries: &[(u16, &str)]) -> Vec<u8> {
    let mut p = (entries.len() as u16).to_le_bytes().to_vec();
    for (id, name) in entries {
        p.extend_from_slice(&id.to_le_bytes());
        p.extend_from_slice(name.as_bytes());
        p.push(0);
    }
    tag(76, &p)
}

/// Body of a minimal SWF: empty RECT, frame rate, frame count, tags, End.
fn swf_body_bytes(tags: &[Vec<u8>]) -> Vec<u8> {
    let mut b = vec![0u8, 0, 12, 1, 0];
    for t in tags {
        b.extend_from_slice(t);
    }
    b.extend_from_slice(&tag(0, &[]));
    b
}

fn make_fws(body: &[u8]) -> Vec<u8> {
    let mut v = b"FWS".to_vec();
    v.push(32);
    v.extend_from_slice(&((body.len() + 8) as u32).to_le_bytes());
    v.extend_from_slice(body);
    v
}

fn make_cws(body: &[u8]) -> Vec<u8> {
    let mut z = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    z.write_all(body).unwrap();
    let mut v = b"CWS".to_vec();
    v.push(32);
    v.extend_from_slice(&((body.len() + 8) as u32).to_le_bytes());
    v.extend_from_slice(&z.finish().unwrap());
    v
}

fn make_zws(body: &[u8]) -> Vec<u8> {
    let lz = lzma_enc(body);
    let mut v = b"ZWS".to_vec();
    v.push(32);
    v.extend_from_slice(&((body.len() + 8) as u32).to_le_bytes());
    v.extend_from_slice(&((lz.len() - 5) as u32).to_le_bytes());
    v.extend_from_slice(&lz);
    v
}

fn sample_body() -> Vec<u8> {
    let a = dxt1_8x8(false, 0x0c);
    let b = dxt5_8x8(0x0d);
    swf_body_bytes(&[
        binary_data(1, &a),
        binary_data(2, &b),
        binary_data(3, b"not an atf payload"),
        symbol_class(&[(1, "pkg.Embed_atf_Sheet"), (3, "pkg.Other")]),
    ])
}

#[test]
fn inflate_round_trip_cws_zws_fws() {
    let body = sample_body();
    let fws = make_fws(&body);
    assert_eq!(atftool::inflate_swf(&make_cws(&body)).unwrap(), fws, "CWS");
    assert_eq!(atftool::inflate_swf(&make_zws(&body)).unwrap(), fws, "ZWS");
    assert_eq!(atftool::inflate_swf(&fws).unwrap(), fws, "FWS");
    assert!(atftool::inflate_swf(b"XYZ12345").is_err());
}

#[test]
fn swf_extracts_atf_with_names_for_every_compression() {
    let body = sample_body();
    for swf in [make_fws(&body), make_cws(&body), make_zws(&body)] {
        let list = atftool::swf_atfs(&swf, false).unwrap();
        let names: Vec<&str> = list.iter().map(|(n, _)| n.as_str()).collect();
        assert_eq!(names, ["Sheet", "binary2"]);
        assert!(atftool::decode(&list[0].1).is_ok());
        let raw = atftool::swf_atfs(&swf, true).unwrap();
        assert_eq!(raw[0].0, "pkg.Embed_atf_Sheet");
    }
}

// ---------------------------------------------------------------------------------------------
// Command line

fn scratch(name: &str) -> PathBuf {
    let p = std::env::temp_dir().join(format!("atftool-test-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&p);
    std::fs::create_dir_all(&p).unwrap();
    p
}

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_atftool"))
}

fn png_size(p: &Path) -> (u32, u32) {
    let d = std::fs::read(p).unwrap();
    assert_eq!(&d[1..4], b"PNG");
    (u32::from_be_bytes(d[16..20].try_into().unwrap()), u32::from_be_bytes(d[20..24].try_into().unwrap()))
}

#[test]
fn cli_atf_converts_and_scales() {
    let dir = scratch("atf");
    let f = dir.join("sheet.atf");
    std::fs::write(&f, dxt1_8x8(false, 0x0c)).unwrap();
    let out = dir.join("out");
    let r = bin().args(["atf", "1", out.to_str().unwrap(), f.to_str().unwrap()]).output().unwrap();
    assert!(r.status.success(), "{}", String::from_utf8_lossy(&r.stderr));
    let stdout = String::from_utf8_lossy(&r.stdout);
    assert!(stdout.starts_with("OK  ") && stdout.contains("[0x0c 8x8]"), "{stdout}");
    assert_eq!(png_size(&out.join("sheet.png")), (8, 8));
    assert!(!out.join("sheet.png.tmp").exists());
    let r = bin().args(["atf", "0.5", out.to_str().unwrap(), f.to_str().unwrap()]).output().unwrap();
    assert!(r.status.success());
    assert_eq!(png_size(&out.join("sheet.png")), (4, 4));
}

#[test]
fn cli_exit_codes_and_err_lines() {
    let dir = scratch("exit");
    let bad = dir.join("bad.atf");
    std::fs::write(&bad, b"garbage garbage").unwrap();
    let out = dir.join("out");
    let r = bin().args(["atf", "1", out.to_str().unwrap(), bad.to_str().unwrap()]).output().unwrap();
    assert_eq!(r.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&r.stderr).contains("ERR bad: not an ATF file"));
    assert_eq!(bin().output().unwrap().status.code(), Some(2));
    assert_eq!(bin().args(["atf", "1"]).output().unwrap().status.code(), Some(2));
    let help = bin().arg("--help").output().unwrap();
    assert!(help.status.success() && String::from_utf8_lossy(&help.stdout).contains("atlasxml"));
}

#[test]
fn cli_swf_extracts_embedded_atf() {
    let dir = scratch("swf");
    let swf = dir.join("shell.swf");
    std::fs::write(&swf, make_zws(&sample_body())).unwrap();
    let out = dir.join("out");
    let r = bin().args(["swf", "1", out.to_str().unwrap(), swf.to_str().unwrap()]).output().unwrap();
    assert!(r.status.success());
    assert_eq!(png_size(&out.join("Sheet.png")), (8, 8));
    assert_eq!(png_size(&out.join("binary2.png")), (8, 8));
}

#[test]
fn cli_inflate_and_info() {
    let dir = scratch("inflate");
    let body = sample_body();
    for (name, swf) in [("c.swf", make_cws(&body)), ("z.swf", make_zws(&body))] {
        let inp = dir.join(name);
        let outp = dir.join(format!("{name}.out"));
        std::fs::write(&inp, swf).unwrap();
        let r = bin().args(["inflate", inp.to_str().unwrap(), outp.to_str().unwrap()]).output().unwrap();
        assert!(r.status.success(), "{}", String::from_utf8_lossy(&r.stderr));
        assert_eq!(std::fs::read(&outp).unwrap(), make_fws(&body), "{name}");
    }
    let f = dir.join("t.atf");
    std::fs::write(&f, dxt1_8x8(false, 0x0c)).unwrap();
    let r = bin().args(["info", f.to_str().unwrap()]).output().unwrap();
    assert!(String::from_utf8_lossy(&r.stdout).contains("dimensions: 8x8"));
}

#[test]
fn atlasxml_scales_only_pixel_attributes() {
    let xml = "<TextureAtlas imagePath='a.png'>\n  <SubTexture name=\"hero_01\" x=\"10\" y=\"20\" width=\"100\" height=\"50\" frameX=\"-4\" frameY=\"-6\" frameWidth=\"108\" frameHeight=\"60\" pivotX=\"3\" pivotY=\"5\" rotated=\"false\"/>\n</TextureAtlas>\n";
    let out = atftool::atlas_xml_scale(0.5, xml).unwrap();
    assert!(out.contains("x=\"5\" y=\"10\" width=\"50\" height=\"25\""), "{out}");
    assert!(out.contains("frameX=\"-2\" frameY=\"-3\" frameWidth=\"54\" frameHeight=\"30\""), "{out}");
    assert!(out.contains("pivotX=\"1.5\" pivotY=\"2.5\""), "{out}");
    assert!(out.contains("name=\"hero_01\"") && out.contains("rotated=\"false\"") && out.contains("imagePath='a.png'"), "{out}");
    // CLI path
    let dir = scratch("xml");
    let (i, o) = (dir.join("in.xml"), dir.join("out.xml"));
    std::fs::write(&i, xml).unwrap();
    let r = bin().args(["atlasxml", "2", i.to_str().unwrap(), o.to_str().unwrap()]).output().unwrap();
    assert!(r.status.success());
    assert!(std::fs::read_to_string(&o).unwrap().contains("width=\"200\" height=\"100\""));
}

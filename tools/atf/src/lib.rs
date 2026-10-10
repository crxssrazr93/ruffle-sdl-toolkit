//! atftool library: decodes Adobe ATF textures (v3 lossy included) to RGBA, extracts embedded
//! ATF from SWF files, inflates compressed SWF files and scales Starling atlas XML.
//!
//! ATF formats handled for decoding: 0x02 Compressed, 0x04 CompressedAlpha, 0x0C CompressedLossy,
//! 0x0D CompressedLossyAlpha (first mip of first face). Per mip, every record is a length (u32 BE,
//! or u24 BE for the legacy header) plus payload. DXT index bits are LZMA compressed (5 byte props
//! header, no size field). The DXT endpoint colours and alphas live in a JPEG XR image of
//! (w/4) x (h/2): top half is endpoint 0 for each 4x4 block, bottom half is endpoint 1.
//! Reference: https://github.com/adobe/dds2atf (pvr2atfcore.cpp).

use std::collections::HashMap;
use std::error::Error;
use std::io::{Cursor, Read};

pub type Res<T> = Result<T, Box<dyn Error>>;

/// Number of records stored per mip level for a given ATF format, if the format is known.
pub fn records_per_mip(format: u8) -> Option<usize> {
    match format {
        0x02 => Some(11),
        0x04 => Some(16),
        0x0c => Some(12),
        0x0d => Some(17),
        _ => None,
    }
}

/// Human readable name of an ATF format code.
pub fn format_name(format: u8) -> &'static str {
    match format {
        0x00 => "RGB888 (uncompressed)",
        0x01 => "RGBA8888 (uncompressed)",
        0x02 => "Compressed",
        0x03 => "RawCompressed",
        0x04 => "CompressedAlpha",
        0x05 => "RawCompressedAlpha",
        0x0c => "CompressedLossy",
        0x0d => "CompressedLossyAlpha",
        _ => "unknown",
    }
}

/// Parsed ATF header plus the records of the first mip of the first face.
pub struct Atf<'a> {
    pub version: u8,
    /// Format code, low 7 bits of the format byte.
    pub format: u8,
    pub cubemap: bool,
    pub width: u32,
    pub height: u32,
    pub mip_count: u8,
    /// Byte offset of the first record length field.
    pub data_offset: usize,
    pub records: Vec<&'a [u8]>,
}

struct Header {
    version: u8,
    format: u8,
    cubemap: bool,
    width: u32,
    height: u32,
    mip_count: u8,
    data_offset: usize,
}

fn parse_header(d: &[u8]) -> Res<Header> {
    if d.len() < 10 || &d[..3] != b"ATF" {
        return Err("not an ATF file".into());
    }
    let (version, p) = if d[6] == 0xff { (d[7], 12) } else { (0, 6) };
    let h = d.get(p..p + 4).ok_or("truncated ATF header")?;
    let (log_w, log_h) = (h[1], h[2]);
    if log_w > 15 || log_h > 15 {
        return Err("implausible ATF dimensions".into());
    }
    Ok(Header {
        version,
        format: h[0] & 0x7f,
        cubemap: h[0] & 0x80 != 0,
        width: 1u32 << log_w,
        height: 1u32 << log_h,
        mip_count: h[3],
        data_offset: p + 4,
    })
}

/// Reads one length prefixed record at `p`, returns (payload, next offset).
fn read_record(d: &[u8], p: usize, version: u8) -> Res<(&[u8], usize)> {
    let (len, p) = if version == 0 {
        let b = d.get(p..p + 3).ok_or("truncated ATF record length")?;
        (u32::from_be_bytes([0, b[0], b[1], b[2]]) as usize, p + 3)
    } else {
        let b = d.get(p..p + 4).ok_or("truncated ATF record length")?;
        (u32::from_be_bytes([b[0], b[1], b[2], b[3]]) as usize, p + 4)
    };
    let payload = d.get(p..p.checked_add(len).ok_or("bad ATF record length")?).ok_or("truncated ATF record")?;
    Ok((payload, p + len))
}

pub fn parse_atf(d: &[u8]) -> Res<Atf<'_>> {
    let h = parse_header(d)?;
    let n = records_per_mip(h.format).ok_or_else(|| format!("unsupported ATF format {:#x}", h.format))?;
    let mut records = Vec::with_capacity(n);
    let mut p = h.data_offset;
    for _ in 0..n {
        let (r, next) = read_record(d, p, h.version)?;
        records.push(r);
        p = next;
    }
    Ok(Atf {
        version: h.version,
        format: h.format,
        cubemap: h.cubemap,
        width: h.width,
        height: h.height,
        mip_count: h.mip_count,
        data_offset: h.data_offset,
        records,
    })
}

/// Text report of an ATF file: version, format, dimensions, mip count and every record size.
pub fn info(d: &[u8]) -> Res<String> {
    use std::fmt::Write;
    let h = parse_header(d)?;
    let mut s = String::new();
    let _ = writeln!(s, "version:    {}{}", h.version, if h.version == 0 { " (legacy header, u24 record lengths)" } else { "" });
    let _ = writeln!(s, "format:     {:#04x} {}", h.format, format_name(h.format));
    let _ = writeln!(s, "cubemap:    {}", h.cubemap);
    let _ = writeln!(s, "dimensions: {}x{}", h.width, h.height);
    let _ = writeln!(s, "mip count:  {}", h.mip_count);
    let Some(n) = records_per_mip(h.format) else {
        let _ = writeln!(s, "records:    format has no known record layout, not listed");
        return Ok(s);
    };
    let faces = if h.cubemap { 6 } else { 1 };
    let mut p = h.data_offset;
    'walk: for face in 0..faces {
        for mip in 0..h.mip_count.max(1) {
            let mut sizes = Vec::with_capacity(n);
            for _ in 0..n {
                match read_record(d, p, h.version) {
                    Ok((r, next)) => {
                        sizes.push(r.len());
                        p = next;
                    }
                    Err(e) => {
                        let _ = writeln!(s, "face {face} mip {mip}: {e} after {} records", sizes.len());
                        break 'walk;
                    }
                }
            }
            let kinds: Vec<String> = sizes.iter().map(|x| x.to_string()).collect();
            let _ = writeln!(s, "face {face} mip {mip}: {} records, sizes {}", n, kinds.join(" "));
        }
    }
    Ok(s)
}

/// Raw LZMA stream (props + dict size, no uncompressed size field) of known output length.
pub fn lzma_raw(blob: &[u8], expected: usize) -> Res<Vec<u8>> {
    if blob.len() < 5 {
        return Err("empty LZMA record".into());
    }
    let mut src = Vec::with_capacity(blob.len() + 8);
    src.extend_from_slice(&blob[..5]);
    src.extend_from_slice(&(expected as u64).to_le_bytes());
    src.extend_from_slice(&blob[5..]);
    let mut out = Vec::with_capacity(expected);
    lzma_rs::lzma_decompress(&mut Cursor::new(src), &mut out)?;
    if out.len() != expected {
        return Err(format!("LZMA gave {} bytes, expected {expected}", out.len()).into());
    }
    Ok(out)
}

/// Decodes a JPEG XR endpoint plane; returns raw pixels and bytes per pixel.
fn jxr(blob: &[u8], bw: u32, bh: u32) -> Res<(Vec<u8>, usize)> {
    let mut dec = jpegxr::ImageDecode::with_reader(Cursor::new(blob))?;
    let (w, h) = dec.get_size()?;
    if w as u32 != bw || h as u32 != bh * 2 {
        return Err(format!("JPEG-XR plane {w}x{h}, expected {bw}x{}", bh * 2).into());
    }
    let info = jpegxr::PixelInfo::from_format(dec.get_pixel_format()?);
    let bpp = info.bits_per_pixel() / 8;
    let stride = w as usize * bpp;
    let mut out = vec![0; stride * h as usize];
    dec.copy_all(&mut out, stride)?;
    Ok((out, bpp))
}

/// Endpoint colour as RGB565 (little endian bytes). JPEG XR planes are 16bpp 565 already, or
/// 24bpp RGB depending on the encoder; both are handled.
fn color565(px: &[u8], bpp: usize) -> [u8; 2] {
    match bpp {
        2 => [px[0], px[1]],
        _ => {
            let (r, g, b) = (px[0] as u16, px[1] as u16, px[2] as u16);
            ((r >> 3) << 11 | (g >> 2) << 5 | (b >> 3)).to_le_bytes()
        }
    }
}

/// Decoded texture: width, height, 0xAARRGGBB pixels and the ATF format code.
pub struct Decoded {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u32>,
    pub format: u8,
}

/// Decodes the first mip of an ATF file to 0xAARRGGBB pixels.
pub fn decode(d: &[u8]) -> Res<Decoded> {
    let atf = parse_atf(d)?;
    let (w, h, r) = (atf.width, atf.height, &atf.records);
    let (bw, bh) = ((w / 4).max(1), (h / 4).max(1));
    let n = (bw * bh) as usize;
    let mut pixels = vec![0u32; (w * h) as usize];
    match atf.format {
        0x02 | 0x0c => {
            let bits = lzma_raw(r[0], n * 4)?;
            let (c, cb) = jxr(r[1], bw, bh)?;
            let mut blocks = vec![0u8; n * 8];
            for i in 0..n {
                let b = &mut blocks[i * 8..i * 8 + 8];
                b[0..2].copy_from_slice(&color565(&c[i * cb..], cb));
                b[2..4].copy_from_slice(&color565(&c[(n + i) * cb..], cb));
                b[4..8].copy_from_slice(&bits[i * 4..i * 4 + 4]);
            }
            texture2ddecoder::decode_bc1(&blocks, w as usize, h as usize, &mut pixels)?;
        }
        _ => {
            let abits = lzma_raw(r[0], n * 6)?;
            let (a, ab) = jxr(r[1], bw, bh)?;
            let cbits = lzma_raw(r[2], n * 4)?;
            let (c, cb) = jxr(r[3], bw, bh)?;
            let mut blocks = vec![0u8; n * 16];
            for i in 0..n {
                let b = &mut blocks[i * 16..i * 16 + 16];
                b[0] = a[i * ab];
                b[1] = a[(n + i) * ab];
                b[2..8].copy_from_slice(&abits[i * 6..i * 6 + 6]);
                b[8..10].copy_from_slice(&color565(&c[i * cb..], cb));
                b[10..12].copy_from_slice(&color565(&c[(n + i) * cb..], cb));
                b[12..16].copy_from_slice(&cbits[i * 4..i * 4 + 4]);
            }
            texture2ddecoder::decode_bc3(&blocks, w as usize, h as usize, &mut pixels)?;
        }
    }
    Ok(Decoded { width: w, height: h, pixels, format: atf.format })
}

/// Decodes an ATF file to an RGBA image, optionally resized with a Triangle filter.
pub fn to_image(data: &[u8], scale: f32) -> Res<(image::RgbaImage, u8, u32, u32)> {
    let dec = decode(data)?;
    // texture2ddecoder emits 0xAARRGGBB
    let mut rgba = Vec::with_capacity(dec.pixels.len() * 4);
    for p in dec.pixels {
        rgba.extend_from_slice(&[(p >> 16) as u8, (p >> 8) as u8, p as u8, (p >> 24) as u8]);
    }
    let mut img = image::RgbaImage::from_raw(dec.width, dec.height, rgba).ok_or("bad image size")?;
    if (scale - 1.0).abs() > f32::EPSILON {
        let nw = ((dec.width as f32 * scale).round() as u32).max(1);
        let nh = ((dec.height as f32 * scale).round() as u32).max(1);
        img = image::imageops::resize(&img, nw, nh, image::imageops::FilterType::Triangle);
    }
    Ok((img, dec.format, dec.width, dec.height))
}

/// Returns the SWF body (everything after the 8 byte header) uncompressed, plus the signature.
/// Supports FWS (stored), CWS (zlib) and ZWS (LZMA).
pub fn swf_body(swf: &[u8]) -> Res<([u8; 3], Vec<u8>)> {
    if swf.len() < 8 {
        return Err("not a SWF".into());
    }
    let sig = [swf[0], swf[1], swf[2]];
    let body = match &sig {
        b"FWS" => swf[8..].to_vec(),
        b"CWS" => {
            let mut v = Vec::new();
            flate2::read::ZlibDecoder::new(&swf[8..]).read_to_end(&mut v)?;
            v
        }
        b"ZWS" => {
            // SWF LZMA: u32 uncompressed length (whole file), u32 compressed length, 5 props
            // bytes, raw stream without size field.
            if swf.len() < 17 {
                return Err("truncated ZWS".into());
            }
            let total = u32::from_le_bytes(swf[4..8].try_into()?) as usize;
            let len = total.checked_sub(8).ok_or("bad ZWS length")?;
            lzma_raw(&swf[12..], len)?
        }
        _ => return Err("not a SWF".into()),
    };
    Ok((sig, body))
}

/// Rewrites a CWS or ZWS SWF as stored (FWS). An FWS input is returned unchanged.
pub fn inflate_swf(data: &[u8]) -> Res<Vec<u8>> {
    let (sig, body) = swf_body(data)?;
    if &sig == b"FWS" {
        return Ok(data.to_vec());
    }
    let mut out = Vec::with_capacity(8 + body.len());
    out.extend_from_slice(b"FWS");
    out.push(data[3]);
    // The length field stays the uncompressed file length for CWS. For ZWS it is the same.
    out.extend_from_slice(&((body.len() + 8) as u32).to_le_bytes());
    out.extend_from_slice(&body);
    Ok(out)
}

/// Returns (name, ATF bytes) for every DefineBinaryData tag holding an ATF texture.
///
/// Naming is optional and heuristic. If the SWF has a SymbolClass entry for the tag, that class
/// name is used. By convention some build tools name embeds "<Something>_atf_<Name>"; unless
/// `raw_names` is set, the part after the last "_atf_" is used. Without SymbolClass the name is
/// `binary<id>`.
pub fn swf_atfs(swf: &[u8], raw_names: bool) -> Res<Vec<(String, Vec<u8>)>> {
    let (_, body) = swf_body(swf)?;
    let first = *body.first().ok_or("empty SWF body")?;
    let nbits = (first >> 3) as usize;
    let mut p = (5 + nbits * 4).div_ceil(8) + 4;
    let mut bins: Vec<(u16, Vec<u8>)> = Vec::new();
    let mut names: HashMap<u16, String> = HashMap::new();
    while p + 2 <= body.len() {
        let hdr = u16::from_le_bytes([body[p], body[p + 1]]);
        p += 2;
        let code = hdr >> 6;
        let mut len = (hdr & 0x3f) as usize;
        if len == 0x3f {
            let b = body.get(p..p + 4).ok_or("truncated tag header")?;
            len = u32::from_le_bytes(b.try_into()?) as usize;
            p += 4;
        }
        let tag = body.get(p..p + len).ok_or("truncated SWF tag")?;
        match code {
            87 if tag.len() > 9 && &tag[6..9] == b"ATF" => bins.push((u16::from_le_bytes([tag[0], tag[1]]), tag[6..].to_vec())),
            76 if tag.len() >= 2 => {
                let count = u16::from_le_bytes([tag[0], tag[1]]) as usize;
                let mut q = 2;
                for _ in 0..count {
                    let id = u16::from_le_bytes([*tag.get(q).ok_or("bad SymbolClass")?, *tag.get(q + 1).ok_or("bad SymbolClass")?]);
                    q += 2;
                    let end = q + tag.get(q..).ok_or("bad SymbolClass")?.iter().position(|&c| c == 0).ok_or("bad SymbolClass")?;
                    names.insert(id, String::from_utf8_lossy(&tag[q..end]).into_owned());
                    q = end + 1;
                }
            }
            0 => break,
            _ => {}
        }
        p += len;
    }
    Ok(bins
        .into_iter()
        .map(|(id, data)| {
            let full = names.get(&id).cloned().unwrap_or_else(|| format!("binary{id}"));
            let name = if raw_names { full } else { full.rsplit("_atf_").next().unwrap_or(&full).to_string() };
            (name, data)
        })
        .collect())
}

/// Scales the pixel coordinates of a Starling texture atlas XML (for a downscaled texture).
pub fn atlas_xml_scale(factor: f64, text: &str) -> Res<String> {
    const ATTRS: [&str; 10] = ["x", "y", "width", "height", "frameX", "frameY", "frameWidth", "frameHeight", "pivotX", "pivotY"];
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(i) = rest.find("=\"") {
        let (head, tail) = rest.split_at(i);
        let name = head.rsplit(|c: char| c.is_whitespace()).next().unwrap_or("");
        let end = tail[2..].find('"').ok_or("unterminated attribute")? + 2;
        let value = &tail[2..end];
        out.push_str(head);
        match value.parse::<f64>() {
            Ok(v) if ATTRS.contains(&name) => out.push_str(&format!("=\"{}\"", v * factor)),
            _ => out.push_str(&tail[..=end]),
        }
        rest = &tail[end + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

//! atftool command line front end. See README.md.

use std::fs;
use std::path::Path;
use std::time::Instant;

use atftool::Res;

const USAGE: &str = "\
usage: atftool atf <scale> <out_dir> <file.atf>...   convert loose ATF files to PNG
       atftool swf <scale> <out_dir> <file.swf>      extract and convert ATF textures embedded in a SWF
       atftool inflate <in.swf> <out.swf>            rewrite CWS or ZWS SWF as uncompressed FWS
       atftool atlasxml <factor> <in.xml> <out.xml>  scale Starling atlas XML coordinates
       atftool info <file.atf>                       print ATF header and record sizes
       atftool --help

Decoded ATF formats: 0x02, 0x04, 0x0C, 0x0D (first mip of first face).
Environment: ATFTOOL_RAW_NAMES=1 keeps the full SymbolClass name in `swf` mode instead of
stripping a leading \"..._atf_\" prefix.";

fn convert(data: &[u8], scale: f32, out: &Path) -> Res<()> {
    let t = Instant::now();
    let (img, fmt, w, h) = atftool::to_image(data, scale)?;
    let tmp = out.with_extension("png.tmp");
    img.save_with_format(&tmp, image::ImageFormat::Png)?;
    fs::rename(&tmp, out)?;
    println!("OK  {} [{fmt:#04x} {w}x{h}] {:.1}s", out.display(), t.elapsed().as_secs_f32());
    Ok(())
}

fn run() -> Res<bool> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() >= 2 && matches!(args[1].as_str(), "--help" | "-h" | "help") {
        println!("{USAGE}");
        return Ok(true);
    }
    if args.len() == 4 && args[1] == "inflate" {
        fs::write(&args[3], atftool::inflate_swf(&fs::read(&args[2])?)?)?;
        return Ok(true);
    }
    if args.len() == 5 && args[1] == "atlasxml" {
        let out = atftool::atlas_xml_scale(args[2].parse()?, &fs::read_to_string(&args[3])?)?;
        fs::write(&args[4], out)?;
        return Ok(true);
    }
    if args.len() == 3 && args[1] == "info" {
        print!("{}", atftool::info(&fs::read(&args[2])?)?);
        return Ok(true);
    }
    if args.len() < 5 || !matches!(args[1].as_str(), "atf" | "swf") {
        eprintln!("{USAGE}");
        std::process::exit(2);
    }
    let scale: f32 = args[2].parse()?;
    let out_dir = Path::new(&args[3]);
    fs::create_dir_all(out_dir)?;
    let mut ok = true;
    let job = |name: &str, data: &[u8]| -> bool {
        let out = out_dir.join(format!("{name}.png"));
        match convert(data, scale, &out) {
            Ok(()) => true,
            Err(e) => {
                eprintln!("ERR {name}: {e}");
                false
            }
        }
    };
    match args[1].as_str() {
        "atf" => {
            for f in &args[4..] {
                let stem = Path::new(f).file_stem().ok_or("bad file name")?.to_string_lossy().into_owned();
                match fs::read(f) {
                    Ok(d) => ok &= job(&stem, &d),
                    Err(e) => {
                        eprintln!("ERR {stem}: {e}");
                        ok = false;
                    }
                }
            }
        }
        _ => {
            let raw = std::env::var("ATFTOOL_RAW_NAMES").map(|v| v == "1").unwrap_or(false);
            for (name, data) in atftool::swf_atfs(&fs::read(&args[4])?, raw)? {
                ok &= job(&name, &data);
            }
        }
    }
    Ok(ok)
}

fn main() {
    match run() {
        Ok(true) => {}
        Ok(false) => std::process::exit(1),
        Err(e) => {
            eprintln!("atftool: {e}");
            std::process::exit(1);
        }
    }
}

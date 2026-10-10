#!/usr/bin/env python3
"""Adds TEST ONLY capture and key hooks to a ruffle_sdl source tree.

Usage: sdl_test_hooks.py <ruffle source dir>
Undo:  git -C <dir> checkout -- sdl/src/main.rs && rm <dir>/sdl/src/test_hooks.rs

Never ship a binary built with these hooks. Apply it to a scratch checkout of the patched
tree (after the ruffle/patches series, and after any optional patch that touches the main
loop), build with the PC build script, and use the result only with tests/pc_sdl_run.sh.

Environment variables the hooked binary understands (all optional):

  RUFFLE_SDL_SHOT=<dir | file | pattern>
      Where captures go. A directory (existing, or a path ending in "/" or with no
      extension) gets shot-001.png, shot-002.png and so on. A path containing %d or %03d
      (printf style) has the capture number substituted. A plain file name gets the first
      capture as is and later ones as <stem>-N.<ext>. Output is PNG (own tiny encoder with
      stored deflate blocks, so the sdl crate needs no new dependency). Without
      RUFFLE_SDL_SHOT nothing is captured.
  RUFFLE_SDL_SHOT_AT=<list>
      Comma separated capture points. A plain integer is a render frame number (1 is the
      first frame the player rendered), a number with an "s" suffix is seconds since the
      first render (fractions allowed, for example 2.5s). Default when RUFFLE_SDL_SHOT is
      set: frame 60.
  RUFFLE_SDL_KEYS=<file>
      A file polled once per loop wake up. Each new line is "down <key>" or "up <key>"
      (also "tap <key>", which is a down now and an up 150 ms later). <key> is an SDL key
      or scancode name ("Space", "Left", "Return", "A", "Escape"); lowercase and the
      aliases enter, esc, up, down, left, right, space work too. The file is read from the
      last consumed byte, so appending lines works (echo "down Left" >> file). If the file
      shrinks the offset restarts at zero.
  RUFFLE_SDL_EXIT_AFTER_SHOTS=1
      Quit the player once every capture point has been saved.

The capture is a glReadPixels of the window's default framebuffer, taken right after the
frame is rendered and before the buffer swap. External grabbers (import, ffmpeg x11grab,
xwd) show black for this GL output on Xvfb and gamescope, which is why the hook exists.

GL pixel pack state: wgpu reads textures back (BitmapData readbacks and filters) through a
pixel pack buffer with its own row length and leaves both set. With the buffer bound
glReadPixels writes into the buffer and the capture is all black, with only the row length
left it writes past the end of the Vec and crashes. The hook saves PIXEL_PACK_BUFFER binding,
PACK_ALIGNMENT, PACK_ROW_LENGTH, PACK_SKIP_ROWS, PACK_SKIP_PIXELS and the read framebuffer,
sets 0 / 1 / 0 / 0 / 0, reads, and restores everything (wgpu tracks that state itself).

The script is idempotent (a second run reports "already applied") and fails loudly (exit 1)
if an anchor is missing or matches more than once.
"""
import os
import sys

MARK = "// RUFFLE_SDL_TEST_HOOKS"

HOOKS_RS = r'''// RUFFLE_SDL_TEST_HOOKS: test only, added by tests/sdl_test_hooks.py. Never ship.
//! Test hooks: framebuffer capture (RUFFLE_SDL_SHOT) and key injection (RUFFLE_SDL_KEYS).

use crate::keys::key_descriptor;
use glow::HasContext;
use ruffle_core::events::PlayerEvent;
use sdl2::keyboard::{Keycode, Mod, Scancode};
use std::path::PathBuf;
use std::time::{Duration, Instant};

enum Point {
    Frame(u64),
    Secs(f64),
}

pub struct Hooks {
    shot: Option<String>,
    points: Vec<(Point, bool)>,
    taken: usize,
    exit_after: bool,
    frames: u64,
    first_render: Option<Instant>,
    keys: Option<PathBuf>,
    key_offset: u64,
    pending_ups: Vec<(Instant, PlayerEvent)>,
}

fn parse_points(spec: &str) -> Vec<(Point, bool)> {
    let mut out = Vec::new();
    for tok in spec.split(',').map(str::trim).filter(|t| !t.is_empty()) {
        if let Some(s) = tok.strip_suffix('s') {
            match s.parse::<f64>() {
                Ok(v) => out.push((Point::Secs(v), false)),
                Err(_) => eprintln!("RUFFLE_SDL_SHOT_AT: bad seconds value {tok:?}"),
            }
        } else {
            match tok.parse::<u64>() {
                Ok(v) => out.push((Point::Frame(v), false)),
                Err(_) => eprintln!("RUFFLE_SDL_SHOT_AT: bad frame value {tok:?}"),
            }
        }
    }
    out
}

fn scancode_for(name: &str) -> Option<Scancode> {
    let alias = match name.to_ascii_lowercase().as_str() {
        "enter" | "return" => "Return",
        "esc" | "escape" => "Escape",
        "up" => "Up",
        "down" => "Down",
        "left" => "Left",
        "right" => "Right",
        "space" => "Space",
        "tab" => "Tab",
        "backspace" => "Backspace",
        _ => "",
    };
    if !alias.is_empty() {
        return Scancode::from_name(alias);
    }
    Scancode::from_name(name)
        .or_else(|| Scancode::from_name(&name.to_ascii_uppercase()))
        .or_else(|| {
            let mut c = name.chars();
            c.next().and_then(|f| {
                Scancode::from_name(&format!("{}{}", f.to_ascii_uppercase(), c.as_str()))
            })
        })
}

fn key_event(name: &str, down: bool) -> Option<PlayerEvent> {
    let sc = match scancode_for(name) {
        Some(sc) => sc,
        None => {
            eprintln!("RUFFLE_SDL_KEYS: unknown key {name:?}");
            return None;
        }
    };
    let kc = Keycode::from_scancode(sc);
    let key = key_descriptor(Some(sc), kc, Mod::NOMOD);
    Some(if down {
        PlayerEvent::KeyDown { key }
    } else {
        PlayerEvent::KeyUp { key }
    })
}

impl Hooks {
    pub fn from_env() -> Self {
        let shot = std::env::var("RUFFLE_SDL_SHOT").ok().filter(|s| !s.is_empty());
        let mut points = match std::env::var("RUFFLE_SDL_SHOT_AT") {
            Ok(spec) => parse_points(&spec),
            Err(_) => Vec::new(),
        };
        if shot.is_some() && points.is_empty() {
            points.push((Point::Frame(60), false));
        }
        let keys = std::env::var_os("RUFFLE_SDL_KEYS")
            .filter(|s| !s.is_empty())
            .map(PathBuf::from);
        Hooks {
            shot,
            points,
            taken: 0,
            exit_after: std::env::var("RUFFLE_SDL_EXIT_AFTER_SHOTS").is_ok_and(|v| v == "1"),
            frames: 0,
            first_render: None,
            keys,
            key_offset: 0,
            pending_ups: Vec::new(),
        }
    }

    /// New key events from the RUFFLE_SDL_KEYS file, plus delayed key ups of "tap" lines.
    pub fn poll_keys(&mut self) -> Vec<PlayerEvent> {
        let mut out = Vec::new();
        let now = Instant::now();
        let mut i = 0;
        while i < self.pending_ups.len() {
            if self.pending_ups[i].0 <= now {
                out.push(self.pending_ups.remove(i).1);
            } else {
                i += 1;
            }
        }
        let Some(path) = &self.keys else {
            return out;
        };
        let Ok(data) = std::fs::read(path) else {
            return out;
        };
        if (data.len() as u64) < self.key_offset {
            self.key_offset = 0;
        }
        let rest = &data[self.key_offset as usize..];
        // only whole lines, a half written last line waits for its newline
        let Some(end) = rest.iter().rposition(|&b| b == b'\n') else {
            return out;
        };
        let text = String::from_utf8_lossy(&rest[..end]).into_owned();
        self.key_offset += end as u64 + 1;
        for line in text.lines() {
            let mut it = line.split_whitespace();
            let (Some(verb), Some(key)) = (it.next(), it.next()) else {
                continue;
            };
            match verb {
                "down" => out.extend(key_event(key, true)),
                "up" => out.extend(key_event(key, false)),
                "tap" => {
                    out.extend(key_event(key, true));
                    if let Some(up) = key_event(key, false) {
                        self.pending_ups
                            .push((now + Duration::from_millis(150), up));
                    }
                }
                _ => eprintln!("RUFFLE_SDL_KEYS: unknown verb {verb:?} (use down, up, tap)"),
            }
        }
        out
    }

    fn path_for(&self, n: usize) -> PathBuf {
        let spec = self.shot.as_deref().unwrap_or("");
        let p = PathBuf::from(spec);
        if spec.ends_with('/') || p.is_dir() || p.extension().is_none() && !spec.contains('%') {
            let _ = std::fs::create_dir_all(&p);
            return p.join(format!("shot-{n:03}.png"));
        }
        if let Some(i) = spec.find('%') {
            let rest = &spec[i + 1..];
            let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
            if rest[digits.len()..].starts_with('d') {
                let width: usize = digits.trim_start_matches('0').parse().unwrap_or(0);
                let num = if digits.starts_with('0') {
                    format!("{n:0width$}")
                } else {
                    format!("{n:width$}")
                };
                let out = format!("{}{}{}", &spec[..i], num, &rest[digits.len() + 1..]);
                if let Some(parent) = PathBuf::from(&out).parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                return PathBuf::from(out);
            }
        }
        if let Some(parent) = p.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if n == 1 {
            return p;
        }
        let stem = p.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        let ext = p.extension().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        p.with_file_name(format!("{stem}-{n}.{ext}"))
    }

    /// Call right after `player.render()` and before the buffer swap. Returns true when the
    /// player should quit (RUFFLE_SDL_EXIT_AFTER_SHOTS=1 and every capture point is done).
    pub fn after_render(&mut self, gl: &glow::Context, w: u32, h: u32) -> bool {
        self.frames += 1;
        let t0 = *self.first_render.get_or_insert_with(Instant::now);
        if self.shot.is_none() {
            return false;
        }
        let secs = t0.elapsed().as_secs_f64();
        let frames = self.frames;
        let mut due = false;
        for (p, done) in self.points.iter_mut() {
            if *done {
                continue;
            }
            let hit = match p {
                Point::Frame(f) => frames >= *f,
                Point::Secs(s) => secs >= *s,
            };
            if hit {
                *done = true;
                due = true;
            }
        }
        if due {
            self.taken += 1;
            let path = self.path_for(self.taken);
            match capture(gl, w, h) {
                Some(rgb) => match std::fs::write(&path, png_rgb(w, h, &rgb)) {
                    Ok(()) => eprintln!(
                        "RUFFLE_SDL_SHOT saved {} frame={} t={:.2}s {}x{}",
                        path.display(),
                        frames,
                        secs,
                        w,
                        h
                    ),
                    Err(e) => eprintln!("RUFFLE_SDL_SHOT write {}: {e}", path.display()),
                },
                None => eprintln!("RUFFLE_SDL_SHOT: capture failed"),
            }
        }
        self.exit_after && self.points.iter().all(|(_, d)| *d)
    }
}

/// glReadPixels of the default framebuffer, top row first, RGB. Saves, resets and restores
/// the pixel pack state and the read framebuffer binding (see sdl_test_hooks.py).
fn capture(gl: &glow::Context, w: u32, h: u32) -> Option<Vec<u8>> {
    let mut px = vec![0u8; (w as usize) * (h as usize) * 4];
    unsafe {
        let pack = gl.get_parameter_i32(glow::PIXEL_PACK_BUFFER_BINDING);
        let align = gl.get_parameter_i32(glow::PACK_ALIGNMENT);
        let row_len = gl.get_parameter_i32(glow::PACK_ROW_LENGTH);
        let skip_rows = gl.get_parameter_i32(glow::PACK_SKIP_ROWS);
        let skip_px = gl.get_parameter_i32(glow::PACK_SKIP_PIXELS);
        let read_fb = gl.get_parameter_i32(glow::READ_FRAMEBUFFER_BINDING);
        gl.bind_buffer(glow::PIXEL_PACK_BUFFER, None);
        gl.pixel_store_i32(glow::PACK_ROW_LENGTH, 0);
        gl.pixel_store_i32(glow::PACK_SKIP_ROWS, 0);
        gl.pixel_store_i32(glow::PACK_SKIP_PIXELS, 0);
        gl.pixel_store_i32(glow::PACK_ALIGNMENT, 1);
        gl.bind_framebuffer(glow::READ_FRAMEBUFFER, None);
        gl.read_pixels(
            0,
            0,
            w as i32,
            h as i32,
            glow::RGBA,
            glow::UNSIGNED_BYTE,
            glow::PixelPackData::Slice(Some(&mut px)),
        );
        gl.bind_buffer(
            glow::PIXEL_PACK_BUFFER,
            std::num::NonZeroU32::new(pack as u32).map(glow::NativeBuffer),
        );
        gl.pixel_store_i32(glow::PACK_ALIGNMENT, align);
        gl.pixel_store_i32(glow::PACK_ROW_LENGTH, row_len);
        gl.pixel_store_i32(glow::PACK_SKIP_ROWS, skip_rows);
        gl.pixel_store_i32(glow::PACK_SKIP_PIXELS, skip_px);
        gl.bind_framebuffer(
            glow::READ_FRAMEBUFFER,
            std::num::NonZeroU32::new(read_fb as u32).map(glow::NativeFramebuffer),
        );
    }
    let mut rgb = Vec::with_capacity((w as usize) * (h as usize) * 3);
    for y in (0..h as usize).rev() {
        for x in 0..w as usize {
            let i = (y * w as usize + x) * 4;
            rgb.extend_from_slice(&px[i..i + 3]);
        }
    }
    Some(rgb)
}

fn crc32(data: &[u8]) -> u32 {
    let mut crc = 0xffff_ffffu32;
    for &b in data {
        crc ^= b as u32;
        for _ in 0..8 {
            crc = if crc & 1 != 0 { (crc >> 1) ^ 0xedb8_8320 } else { crc >> 1 };
        }
    }
    !crc
}

fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    let mut body = kind.to_vec();
    body.extend_from_slice(data);
    out.extend_from_slice(&body);
    out.extend_from_slice(&crc32(&body).to_be_bytes());
}

/// PNG with stored (uncompressed) deflate blocks: big but dependency free.
fn png_rgb(w: u32, h: u32, rgb: &[u8]) -> Vec<u8> {
    let mut raw = Vec::with_capacity(rgb.len() + h as usize);
    for row in rgb.chunks(w as usize * 3) {
        raw.push(0);
        raw.extend_from_slice(row);
    }
    let mut z = vec![0x78, 0x01];
    let blocks: Vec<&[u8]> = raw.chunks(65535).collect();
    for (i, b) in blocks.iter().enumerate() {
        z.push(if i + 1 == blocks.len() { 1 } else { 0 });
        z.extend_from_slice(&(b.len() as u16).to_le_bytes());
        z.extend_from_slice(&(!(b.len() as u16)).to_le_bytes());
        z.extend_from_slice(b);
    }
    let (mut a, mut b) = (1u32, 0u32);
    for &v in &raw {
        a = (a + v as u32) % 65521;
        b = (b + a) % 65521;
    }
    z.extend_from_slice(&((b << 16) | a).to_be_bytes());
    let mut out = b"\x89PNG\r\n\x1a\n".to_vec();
    let mut ihdr = Vec::new();
    ihdr.extend_from_slice(&w.to_be_bytes());
    ihdr.extend_from_slice(&h.to_be_bytes());
    ihdr.extend_from_slice(&[8, 2, 0, 0, 0]);
    chunk(&mut out, b"IHDR", &ihdr);
    chunk(&mut out, b"IDAT", &z);
    chunk(&mut out, b"IEND", &[]);
    out
}
'''

# (old, new) replacements in sdl/src/main.rs, each anchor must match exactly once
EDITS = [
    (
        "mod keys;\n",
        "mod keys;\nmod test_hooks; // RUFFLE_SDL_TEST_HOOKS\n",
    ),
    (
        "    let target = SdlTarget {\n        gl,\n",
        "    let shot_gl = gl.clone(); // RUFFLE_SDL_TEST_HOOKS\n"
        "    let target = SdlTarget {\n        gl,\n",
    ),
    (
        "    'main: loop {\n        let wait = next_frame.saturating_duration_since(Instant::now());\n",
        "    let mut hooks = test_hooks::Hooks::from_env(); // RUFFLE_SDL_TEST_HOOKS\n"
        "    'main: loop {\n"
        "        // RUFFLE_SDL_TEST_HOOKS: keys from the RUFFLE_SDL_KEYS file\n"
        "        for key_event in hooks.poll_keys() {\n"
        "            player.lock().expect(\"player lock\").handle_event(key_event);\n"
        "        }\n"
        "        let wait = next_frame.saturating_duration_since(Instant::now());\n",
    ),
    (
        "                player.render();\n                drop(player);\n",
        "                player.render();\n                drop(player);\n"
        "                // RUFFLE_SDL_TEST_HOOKS: capture before the swap\n"
        "                {\n"
        "                    let (cw, ch) = window.drawable_size();\n"
        "                    if hooks.after_render(&shot_gl, cw, ch) {\n"
        "                        quit.set(true);\n"
        "                    }\n"
        "                }\n",
    ),
]


def die(msg):
    sys.stderr.write("sdl_test_hooks: " + msg + "\n")
    sys.exit(1)


def main():
    if len(sys.argv) != 2:
        die("usage: sdl_test_hooks.py <ruffle source dir>")
    root = sys.argv[1]
    main_rs = os.path.join(root, "sdl", "src", "main.rs")
    hooks_rs = os.path.join(root, "sdl", "src", "test_hooks.rs")
    if not os.path.isfile(main_rs):
        die(f"{main_rs} not found (is this a Ruffle tree with the ruffle_sdl series applied?)")
    src = open(main_rs).read()
    if MARK in src:
        if not os.path.isfile(hooks_rs):
            die("main.rs has the hook markers but sdl/src/test_hooks.rs is missing; restore main.rs first")
        # refresh the module file in case this script is newer, main.rs is already patched
        open(hooks_rs, "w").write(HOOKS_RS)
        print("sdl_test_hooks: already applied (test_hooks.rs refreshed)")
        return
    for old, _ in EDITS:
        n = src.count(old)
        if n != 1:
            die(f"anchor matched {n}x (expected 1): {old.strip()[:70]!r}")
    for old, new in EDITS:
        src = src.replace(old, new, 1)
    for _, new in EDITS:
        if new not in src:
            die("post check failed, an edit did not land")
    open(main_rs, "w").write(src)
    open(hooks_rs, "w").write(HOOKS_RS)
    print("sdl_test_hooks: applied to", root)


if __name__ == "__main__":
    main()

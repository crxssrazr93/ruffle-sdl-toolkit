#!/bin/bash
# cursor_test.sh <ruffle_sdl> [out_dir]
#
# Headless pixel test of the software cursor (optional patch 0100) and of the shell side AS2
# overlay. <ruffle_sdl> must be built from a tree that has the series, the optional patch
# (WITH_OPTIONAL="0100" ruffle/fetch.sh) and tests/sdl_test_hooks.py. Exit code 0 only if every
# check passed.
#
# How it works: tests/pc_sdl_run.sh starts a private Xvfb and runs the binary on a still
# test movie (fixtures/test_static.swf), capturing the window framebuffer three times:
#   1. before any mouse motion      (no cursor)
#   2. shortly after motion         (the arrow is under the pointer)
#   3. after the idle time          (the arrow is gone again)
# The pointer is moved with xdotool on the PRIVATE display only. To get at that display without
# changing pc_sdl_run.sh, the binary is started through a tiny wrapper script that inherits the
# private DISPLAY from pc_sdl_run.sh, refuses to run if DISPLAY is the caller's own, starts the
# mover in the background and then execs the real binary. The three PNGs are decoded with
# python (zlib only) and compared pixel by pixel.
#
# Cases: default arrow, --sw-cursor flag with --render-size and RUFFLE_SW_CURSOR_SIZE, a PNG
# cursor image, switch off (must be pixel identical to before, and to PLAIN_BIN when given),
# the animated movie (cursor over moving content, GL state not corrupted), the SDL colour cursor
# switch, and the AS2 and AS3 overlay snippets compiled with ffdec (each skipped without its tools).
#
# Environment (all optional):
#   PLAIN_BIN   a hooked ruffle_sdl built WITHOUT the optional patch: the "switch off" output
#               must be pixel identical to it
#   FFDEC       path to ffdec (enables the AS2 overlay case, and the AS3 one with RUFFLE_SRC)
#   RUFFLE_SRC  a Ruffle source tree, only used for its tiny AS3 test movie of the AS3 overlay case
set -u
here=$(cd "$(dirname "$0")" && pwd)
RUN="$here/pc_sdl_run.sh"
FIX="$here/fixtures"
[ $# -ge 1 ] || { sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
BIN=$(readlink -f "$1"); [ -x "$BIN" ] || { echo "not executable: $1" >&2; exit 2; }
OUT=${2:-$(mktemp -d /tmp/cursor-test.XXXXXX)}; mkdir -p "$OUT"; OUT=$(readlink -f "$OUT")
PLAIN=${PLAIN_BIN:-}
command -v xdotool >/dev/null || { echo "xdotool missing" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 missing" >&2; exit 2; }
HOST_DISPLAY=${DISPLAY:-}

PX=300; PY=420            # where the pointer goes, window pixels, empty background in the fixtures
IDLE=800                  # RUFFLE_SW_CURSOR_IDLE_MS for the tests
FAILS=0; CASES=0

# ---- the pixel analysis (python, zlib only) ------------------------------------------------
cat > "$OUT/analyze.py" <<'PY'
import struct, sys, zlib

def load(path):
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, w = 8, b"", None
    while pos < len(d):
        n, kind = struct.unpack(">I4s", d[pos:pos + 8])
        body = d[pos + 8:pos + 8 + n]
        pos += 12 + n
        if kind == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
            assert depth == 8 and ctype in (2, 6), "need 8 bit RGB or RGBA"
            bpp = 3 if ctype == 2 else 4
        elif kind == b"IDAT":
            idat += body
    raw = zlib.decompress(idat)
    stride = w * bpp
    rows, prev = [], bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + ((a + b) >> 1)) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        rows.append(line)
        prev = line
    px = [[tuple(r[x * bpp:x * bpp + 3]) for x in range(w)] for r in rows]
    return w, h, px

def diff(a, b):
    (w, h, pa), (w2, h2, pb) = a, b
    assert (w, h) == (w2, h2), f"size {w}x{h} vs {w2}x{h2}"
    return [(x, y) for y in range(h) for x in range(w) if pa[y][x] != pb[y][x]]

def bbox(pts):
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    return min(xs), min(ys), max(xs), max(ys)

mode = sys.argv[1]
fails = []
def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond: fails.append(msg)

if mode == "cursor":
    # cursor <before> <during> <after> <x> <y> <min_px> <max_w> <max_h> [min_h]
    before, during, after = (load(p) for p in sys.argv[2:5])
    x, y, min_px, max_w, max_h = (int(v) for v in sys.argv[5:10])
    min_h = int(sys.argv[10]) if len(sys.argv) > 10 else 0
    d1 = diff(before, during)
    d2 = diff(before, after)
    print(f"  pixels changed by the cursor: {len(d1)}; after idle: {len(d2)}")
    check(len(d1) >= min_px, f"cursor pixels present after motion ({len(d1)} >= {min_px})")
    if d1:
        x0, y0, x1, y1 = bbox(d1)
        print(f"  cursor bounding box: ({x0},{y0})..({x1},{y1}) = {x1 - x0 + 1}x{y1 - y0 + 1}")
        check(abs(x0 - x) <= 2 and abs(y0 - y) <= 2, f"tip at the pointer ({x},{y}) +-2")
        check(x1 - x0 + 1 <= max_w and y1 - y0 + 1 <= max_h, f"inside {max_w}x{max_h}")
        check(y1 - y0 + 1 >= min_h, f"at least {min_h} px tall")
        px = during[2]
        white = sum(1 for (cx, cy) in d1 if min(px[cy][cx]) >= 235)
        black = sum(1 for (cx, cy) in d1 if max(px[cy][cx]) <= 30)
        print(f"  white pixels {white}, black pixels {black}")
        check(white >= 10 and black >= 5, "white fill and black outline both present")
    check(len(d2) == 0, "pixel identical to the first capture after the idle time (cursor gone)")
elif mode == "same":
    a, b = load(sys.argv[2]), load(sys.argv[3])
    d = diff(a, b)
    check(len(d) == 0, f"{sys.argv[2].split('/')[-2]}/{sys.argv[2].split('/')[-1]} == {sys.argv[3].split('/')[-2]}/{sys.argv[3].split('/')[-1]} ({len(d)} pixels differ)")
elif mode == "color":
    # color <before> <during> <r> <g> <b> <count> <x> <y> <w> <h>
    before, during = load(sys.argv[2]), load(sys.argv[3])
    r, g, b, count, x, y, w, h = (int(v) for v in sys.argv[4:12])
    d = diff(before, during)
    hit = [p for p in d if during[2][p[1]][p[0]] == (r, g, b)]
    print(f"  changed pixels {len(d)}, of the cursor colour {len(hit)}")
    check(len(hit) == count and len(d) == count, f"exactly {count} pixels of ({r},{g},{b})")
    if hit:
        x0, y0, x1, y1 = bbox(hit)
        check((x0, y0, x1 - x0 + 1, y1 - y0 + 1) == (x, y, w, h), f"at ({x},{y}) size {w}x{h}, got ({x0},{y0}) {x1 - x0 + 1}x{y1 - y0 + 1}")
elif mode == "moves":
    # moves <a> <b> <min_px>: the animation keeps running (captures differ a lot)
    a, b = load(sys.argv[2]), load(sys.argv[3])
    d = diff(a, b)
    check(len(d) >= int(sys.argv[4]), f"animation still running ({len(d)} pixels differ >= {sys.argv[4]})")
elif mode == "writepng":
    # writepng <out> <w> <h> <r> <g> <b> <a>: a solid RGBA test image
    out = sys.argv[2]
    w, h, r, g, b, a = (int(v) for v in sys.argv[3:9])
    row = b"\x00" + bytes([r, g, b, a]) * w
    def chunk(k, body):
        c = struct.pack(">I", len(body)) + k + body
        return c + struct.pack(">I", zlib.crc32(k + body) & 0xffffffff)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(row * h)) + chunk(b"IEND", b"")
    open(out, "wb").write(png)
sys.exit(1 if fails else 0)
PY
an() { python3 -I "$OUT/analyze.py" "$@"; }

# ---- the wrapper that moves the pointer on the private display ------------------------------
cat > "$OUT/wrap.sh" <<'WRAP'
#!/bin/bash
# started by pc_sdl_run.sh in place of the binary: DISPLAY is its private Xvfb here
if [ -z "${DISPLAY:-}" ] || [ "$DISPLAY" = "${CT_HOST_DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
  echo "wrap.sh: refusing, DISPLAY=$DISPLAY is not a private display" >&2; exit 97
fi
(
  # wait for the first capture (the "before" picture), then move once
  for _ in $(seq 1 400); do [ -e "$CT_OUT/shot-001.png" ] && break; sleep 0.05; done
  sleep "${CT_DELAY:-0.3}"
  xdotool mousemove "$CT_X" "$CT_Y" >/dev/null 2>&1
) &
exec "$CT_REAL" "$@"
WRAP
chmod +x "$OUT/wrap.sh"

# run_case <name> <swf> <shot_at> <delay> <env assignments...> -- <extra ruffle_sdl args...>
run_case() {
  local name=$1 swf=$2 shot_at=$3 delay=$4; shift 4
  local envs=() extra=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  extra=("$@")
  CASE_DIR="$OUT/$name"; rm -rf "$CASE_DIR"; mkdir -p "$CASE_DIR"
  echo "== $name: $(basename "$swf") ${envs[*]:-} ${extra[*]:-}"
  env -u RUFFLE_SW_CURSOR -u RUFFLE_SW_CURSOR_IDLE_MS -u RUFFLE_SW_CURSOR_SIZE -u RUFFLE_SW_CURSOR_IMAGE -u RUFFLE_SDL_CURSOR \
      CT_REAL="$BIN" CT_OUT="$CASE_DIR" CT_X=$PX CT_Y=$PY CT_DELAY="$delay" CT_HOST_DISPLAY="$HOST_DISPLAY" \
      SHOT_AT="$shot_at" EXIT_AFTER_SHOTS=1 "${envs[@]}" \
      "$RUN" --headless "$OUT/wrap.sh" "$swf" "$CASE_DIR" 20 "${extra[@]}" >"$CASE_DIR/harness.log" 2>&1
  local n; n=$(ls "$CASE_DIR"/shot-*.png 2>/dev/null | wc -l)
  echo "  harness exit $(cat "$CASE_DIR/exit_code" 2>/dev/null), captures $n"
}
begin() { CASES=$((CASES + 1)); }
end_case() { # end_case <ok:0/1>
  if [ "$1" -ne 0 ]; then FAILS=$((FAILS + 1)); echo "  CASE FAILED (kept in $CASE_DIR)"; fi
}
shots() { # three capture names in $CASE_DIR
  S1="$CASE_DIR/shot-001.png"; S2="$CASE_DIR/shot-002.png"; S3="$CASE_DIR/shot-003.png"
  [ -f "$S1" ] && [ -f "$S2" ] && [ -f "$S3" ]
}

STATIC="$FIX/test_static.swf"; LOOP="$FIX/test_loop.swf"
[ -f "$STATIC" ] || { echo "missing fixture $STATIC" >&2; exit 2; }
# captures: 1.0 s before motion, motion at ~1.0 s + delay, 1.9 s shortly after, 3.6 s after the idle time
SHOTS="1s,1.9s,3.6s"

# 1. default arrow, enabled by the environment
begin
run_case sw_default "$STATIC" "$SHOTS" 0.3 RUFFLE_SW_CURSOR=1 RUFFLE_SW_CURSOR_IDLE_MS=$IDLE
if shots; then an cursor "$S1" "$S2" "$S3" $PX $PY 60 18 26 21; end_case $?; else echo "  FAIL missing captures"; end_case 1; fi
grep -q "software cursor on" "$CASE_DIR/run.log" || { echo "  FAIL no 'software cursor on' log line"; FAILS=$((FAILS + 1)); }

# 2. the --sw-cursor flag (no env), --render-size (scaled and letterboxed blit), a 40 px arrow
begin
PY=380   # --render-size 320x180 letterboxes the 640x480 movie: the picture is y 60..420, keep the arrow inside it
run_case sw_flag_render_size "$STATIC" "$SHOTS" 0.3 RUFFLE_SW_CURSOR_IDLE_MS=$IDLE RUFFLE_SW_CURSOR_SIZE=40 -- --sw-cursor --render-size 320x180
if shots; then an cursor "$S1" "$S2" "$S3" $PX $PY 100 32 44 36; end_case $?; else echo "  FAIL missing captures"; end_case 1; fi
PY=420

# 3. a PNG as the cursor image: 8x8 solid magenta, natural size, so exactly 64 pixels
begin
an writepng "$OUT/magenta8.png" 8 8 255 0 255 255
run_case sw_image "$STATIC" "$SHOTS" 0.3 RUFFLE_SW_CURSOR=1 RUFFLE_SW_CURSOR_IDLE_MS=$IDLE RUFFLE_SW_CURSOR_IMAGE="$OUT/magenta8.png"
if shots; then
  an color "$S1" "$S2" 255 0 255 64 $PX $PY 8 8; r=$?
  an same "$S1" "$S3" || r=1
  end_case $r
else echo "  FAIL missing captures"; end_case 1; fi

# 4. switched off: the same motion changes nothing, and the output equals a binary without the patch
begin
run_case off "$STATIC" "$SHOTS" 0.3
r=0
if shots; then an same "$S1" "$S2" || r=1; an same "$S1" "$S3" || r=1; else echo "  FAIL missing captures"; r=1; fi
if [ -n "$PLAIN" ] && [ -x "$PLAIN" ]; then
  OFF_DIR=$CASE_DIR
  CT_SAVE_BIN=$BIN; BIN=$(readlink -f "$PLAIN")
  run_case off_plain "$STATIC" "$SHOTS" 0.3
  BIN=$CT_SAVE_BIN
  if [ -f "$CASE_DIR/shot-002.png" ] && [ -f "$OFF_DIR/shot-002.png" ]; then
    an same "$OFF_DIR/shot-002.png" "$CASE_DIR/shot-002.png" || r=1
    an same "$OFF_DIR/shot-003.png" "$CASE_DIR/shot-003.png" || r=1
  else echo "  FAIL missing captures of the plain binary"; r=1; fi
else
  echo "  (PLAIN_BIN not set: comparison with a binary without the patch skipped)"
fi
end_case $r

# 5. cursor over the animated movie: the animation keeps running, so wgpu's state survived
begin
run_case sw_loop "$LOOP" "$SHOTS" 0.3 RUFFLE_SW_CURSOR=1 RUFFLE_SW_CURSOR_IDLE_MS=$IDLE
r=0
if shots; then an moves "$S1" "$S3" 2000 || r=1; else echo "  FAIL missing captures"; r=1; fi
if grep -qiE "panic|GL error|glGetError|software cursor disabled" "$CASE_DIR/run.log"; then echo "  FAIL error text in run.log"; r=1; else echo "  ok   no GL error or panic in run.log"; fi
end_case $r

# 6. the SDL colour cursor switch: starts, logs, does not draw into the GL framebuffer
begin
run_case sdl_cursor "$STATIC" "$SHOTS" 0.3 RUFFLE_SDL_CURSOR=1
r=0
grep -q "SDL colour cursor on" "$CASE_DIR/run.log" && echo "  ok   SDL colour cursor created" || { echo "  FAIL no 'SDL colour cursor on' line"; r=1; }
if shots; then an same "$S1" "$S2" || r=1; else echo "  FAIL missing captures"; r=1; fi
echo "  note: an SDL cursor is drawn by the video driver, so it is not in the GL capture; only creation is checked"
end_case $r

# 7. the AS2 overlay snippet, compiled into the still movie with ffdec, no front end cursor
begin
snip="$here/../tools/swf/snippets/cursor_overlay.as2.txt"
ffdec_ok=0
if [ -n "${FFDEC:-}" ] || command -v ffdec >/dev/null; then ffdec_ok=1; fi
if [ "$ffdec_ok" -eq 1 ] && [ -f "$snip" ]; then
  sed -e "s/cursorIdleMs:Number = 2000/cursorIdleMs:Number = $IDLE/" "$snip" > "$OUT/overlay.as"
  "$here/../tools/swf/ffdec.sh" raw -replace "$STATIC" "$OUT/static_as2.swf" /frame_1/DoAction "$OUT/overlay.as" >"$OUT/ffdec.log" 2>&1
  if [ -s "$OUT/static_as2.swf" ]; then
    run_case as2_overlay "$OUT/static_as2.swf" "$SHOTS" 0.3
    if shots; then an cursor "$S1" "$S2" "$S3" $PX $PY 60 16 26 18; end_case $?; else echo "  FAIL missing captures"; end_case 1; fi
  else echo "  FAIL ffdec produced no SWF, see $OUT/ffdec.log"; end_case 1; fi
else
  echo "== as2_overlay: SKIPPED (set FFDEC to the ffdec launcher to run it)"; CASES=$((CASES - 1))
fi

# 8. the AS3 overlay snippet, compiled with ffdec into a minimal AS3 movie from a Ruffle source
#    tree (RUFFLE_SRC, its tests/tests/swfs/avm2/uncaught_error_basic/test.swf has a Sprite document
#    class named Test). The movie is used in place and not copied into this repository.
begin
snip3="$here/../tools/swf/snippets/cursor_overlay.as3.txt"
base3="${RUFFLE_SRC:-}/tests/tests/swfs/avm2/uncaught_error_basic/test.swf"
if [ "$ffdec_ok" -eq 1 ] && [ -f "$snip3" ] && [ -f "$base3" ]; then
  {
    echo 'package {'
    echo '  import flash.display.Shape; import flash.display.Sprite; import flash.events.MouseEvent;'
    echo '  import flash.events.TimerEvent; import flash.ui.Mouse; import flash.utils.Timer; import flash.utils.getTimer;'
    echo '  public class Test extends Sprite {'
    echo '    public function Test() {'
    echo '      graphics.beginFill(0x181828); graphics.drawRect(0, 0, 550, 400); graphics.endFill();'
    echo '      installCursorOverlay();'
    echo '    }'
    sed -n '/^private var cursorSprite/,/^\/\/ Notes/p' "$snip3" | sed -e '$d' -e "s/CURSOR_IDLE_MS:int = 2000/CURSOR_IDLE_MS:int = $IDLE/"
    echo '  }'
    echo '}'
  } > "$OUT/Test.as"
  "$here/../tools/swf/ffdec.sh" replace-as3 "$base3" "$OUT/as3_overlay.swf" Test "$OUT/Test.as" >"$OUT/ffdec3.log" 2>&1
  if [ -s "$OUT/as3_overlay.swf" ]; then
    run_case as3_overlay "$OUT/as3_overlay.swf" "$SHOTS" 0.3
    # the 550x400 stage is scaled to fit 640x480 (x1.16), the arrow is scaled with it
    if shots; then an cursor "$S1" "$S2" "$S3" $PX $PY 60 24 32 20; end_case $?; else echo "  FAIL missing captures"; end_case 1; fi
  else echo "  FAIL ffdec produced no SWF, see $OUT/ffdec3.log"; end_case 1; fi
else
  echo "== as3_overlay: SKIPPED (needs FFDEC and RUFFLE_SRC pointing at a Ruffle source tree)"; CASES=$((CASES - 1))
fi

echo
echo "cursor_test: $((CASES - FAILS))/$CASES cases passed (output in $OUT)"
[ "$FAILS" -eq 0 ]

#!/usr/bin/env python3
"""Generates tiny AVM1 test movies for the ruffle_sdl test harness. Pure python, no deps.
MIT licensed, created for this toolkit.

  python3 make_test_swf.py [outdir]            writes test_quit.swf, test_relaunch.swf, test_loop.swf, test_keys.swf
  python3 make_test_swf.py --check file.swf    lists the tags of a SWF (sanity check)

Every movie is FWS (uncompressed) version 8, 640x480 at 30 fps, 90 frames. Four coloured
rectangles move every frame (DefineShape + PlaceObject2 with a move) and the first one flashes
through a colour transform. Frame 1 traces "fixture started". The last frame runs:
  test_quit.swf      trace, then fscommand("quit")
  test_relaunch.swf  trace, then fscommand("relaunch", "next")  (ruffle_sdl prints the relaunch
                     marker line on stdout and exits)
  test_loop.swf      nothing, the timeline loops forever (for screenshot tests)
  test_keys.swf      like test_loop, and every frame traces "key Left is down" or
                     "key Space is down" while Key.isDown reports that key (for key injection tests)
"""
import struct
import sys

W, H, FPS, FRAMES = 640, 480, 30, 90


class Bits:
    def __init__(self):
        self.bits = []

    def u(self, value, n):
        for i in range(n - 1, -1, -1):
            self.bits.append((value >> i) & 1)

    def s(self, value, n):
        self.u(value & ((1 << n) - 1), n)

    def bytes(self):
        b = self.bits + [0] * (-len(self.bits) % 8)
        return bytes(int("".join(map(str, b[i:i + 8])), 2) for i in range(0, len(b), 8))


def nbits_signed(*vals):
    n = 1
    for v in vals:
        while not (-(1 << (n - 1)) <= v < (1 << (n - 1))):
            n += 1
    return n


def rect(xmin, xmax, ymin, ymax):
    n = nbits_signed(xmin, xmax, ymin, ymax)
    b = Bits()
    b.u(n, 5)
    for v in (xmin, xmax, ymin, ymax):
        b.s(v, n)
    return b.bytes()


def tag(code, body=b""):
    if len(body) < 63:
        return struct.pack("<H", (code << 6) | len(body)) + body
    return struct.pack("<HI", (code << 6) | 63, len(body)) + body


def define_shape(char_id, w_px, h_px, rgb):
    tw, th = w_px * 20, h_px * 20
    body = struct.pack("<H", char_id) + rect(0, tw, 0, th)
    body += bytes([1, 0x00]) + bytes(rgb)  # one solid fill (RGB in DefineShape)
    body += bytes([0])  # no line styles
    b = Bits()
    b.u(1, 4)  # NumFillBits
    b.u(0, 4)  # NumLineBits
    # style change: FillStyle1 and MoveTo
    b.u(0, 1)
    b.u(0, 1)  # new styles
    b.u(0, 1)  # line style
    b.u(1, 1)  # fill style 1
    b.u(0, 1)  # fill style 0
    b.u(1, 1)  # move to
    b.u(1, 5)  # MoveBits
    b.s(0, 1)
    b.s(0, 1)
    b.u(1, 1)  # fill style 1 = 1
    for dx, dy in ((tw, 0), (0, th), (-tw, 0), (0, -th)):
        n = nbits_signed(dx, dy)
        b.u(1, 1)  # edge
        b.u(1, 1)  # straight
        b.u(n - 2, 4)
        b.u(1, 1)  # general line
        b.s(dx, n)
        b.s(dy, n)
    b.u(0, 6)  # end of shape
    return tag(2, body + b.bytes())


def matrix_translate(x_px, y_px):
    tx, ty = int(x_px * 20), int(y_px * 20)
    n = nbits_signed(tx, ty)
    b = Bits()
    b.u(0, 1)  # no scale
    b.u(0, 1)  # no rotate
    b.u(n, 5)
    b.s(tx, n)
    b.s(ty, n)
    return b.bytes()


def cxform_add(r, g, bl):
    # PlaceObject2 carries a CXFORMWITHALPHA: the add terms are R, G, B, A
    n = nbits_signed(r, g, bl, 0)
    b = Bits()
    b.u(1, 1)  # has add terms
    b.u(0, 1)  # no mult terms
    b.u(n, 4)
    for v in (r, g, bl, 0):
        b.s(v, n)
    return b.bytes()


def place(depth, char_id=None, pos=None, cxform=None, move=False):
    flags = 0
    body = b""
    if char_id is not None:
        flags |= 0x02
    if pos is not None:
        flags |= 0x04
    if cxform is not None:
        flags |= 0x08
    if move:
        flags |= 0x01
    body += bytes([flags]) + struct.pack("<H", depth)
    if char_id is not None:
        body += struct.pack("<H", char_id)
    if pos is not None:
        body += matrix_translate(*pos)
    if cxform is not None:
        body += cxform_add(*cxform)
    return tag(26, body)


def a_push_str(text):
    d = b"\x00" + text.encode() + b"\x00"
    return b"\x96" + struct.pack("<H", len(d)) + d


def a_trace(text):
    return a_push_str(text) + b"\x26"


def a_fscommand(cmd, args=""):
    d = ("FSCommand:" + cmd).encode() + b"\x00" + args.encode() + b"\x00"
    return b"\x83" + struct.pack("<H", len(d)) + d


def a_push_int(v):
    d = b"\x07" + struct.pack("<i", v)
    return b"\x96" + struct.pack("<H", len(d)) + d


def a_trace_if_key(code, text):
    """if (Key.isDown(code)) trace(text)"""
    t = a_trace(text)
    return (a_push_int(code) + a_push_int(1) + a_push_str("Key") + b"\x1c"
            + a_push_str("isDown") + b"\x52" + b"\x12"
            + b"\x9d" + struct.pack("<Hh", 2, len(t)) + t)


def do_action(actions):
    return tag(12, actions + b"\x00")


SHAPES = [  # id, w, h, colour
    (1, 120, 90, (230, 40, 40)),
    (2, 100, 100, (40, 200, 60)),
    (3, 160, 60, (50, 90, 240)),
    (4, 80, 140, (240, 210, 40)),
]


def build(variant):
    body = rect(0, W * 20, 0, H * 20) + struct.pack("<HH", FPS << 8, FRAMES)
    body += tag(9, bytes([24, 24, 40]))  # background
    for cid, w, h, rgb in SHAPES:
        body += define_shape(cid, w, h, rgb)
    for f in range(FRAMES):
        for i, (cid, w, h, _) in enumerate(SHAPES):
            # each rectangle sweeps on its own track, positions change every frame
            x = 20 + ((f * (4 + i * 3) + i * 150) % (W - w - 40))
            y = 30 + i * 105 + (f * (2 + i)) % 40
            cx = (min(255, f * 3), 0, 0) if (i == 0 and f % 2 == 0) else None
            if f == 0:
                body += place(i + 1, cid, (x, y), cx)
            else:
                body += place(i + 1, None, (x, y), cx, move=True)
        if f == 0:
            body += do_action(a_trace("fixture started"))
        if variant == "keys":
            body += do_action(a_trace_if_key(37, "key Left is down") + a_trace_if_key(32, "key Space is down"))
        if f == FRAMES - 1:
            if variant == "quit":
                body += do_action(a_trace("fixture quitting") + a_fscommand("quit"))
            elif variant == "relaunch":
                body += do_action(a_trace("fixture relaunching") + a_fscommand("relaunch", "next"))
        body += tag(1)
    body += tag(0)
    header = b"FWS" + bytes([8])
    return header + struct.pack("<I", 8 + len(body)) + body


def check(path):
    d = open(path, "rb").read()
    assert d[:3] == b"FWS", "not an uncompressed SWF"
    ver, length = d[3], struct.unpack("<I", d[4:8])[0]
    assert length == len(d), f"length field {length} != file size {len(d)}"
    n = d[8] >> 3
    pos = 8 + (5 + 4 * n + 7) // 8 + 4
    counts = {}
    while pos < len(d):
        code_len = struct.unpack("<H", d[pos:pos + 2])[0]
        code, ln = code_len >> 6, code_len & 63
        pos += 2
        if ln == 63:
            ln = struct.unpack("<I", d[pos:pos + 4])[0]
            pos += 4
        counts[code] = counts.get(code, 0) + 1
        pos += ln
        if code == 0:
            break
    assert pos == len(d), "trailing bytes after End tag"
    print(f"{path}: FWS v{ver}, {len(d)} bytes, tags {dict(sorted(counts.items()))}")


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--check":
        for p in sys.argv[2:]:
            check(p)
        return
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    for variant in ("quit", "relaunch", "loop", "keys"):
        path = f"{out}/test_{variant}.swf"
        open(path, "wb").write(build(variant))
        check(path)


if __name__ == "__main__":
    main()

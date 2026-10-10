#!/usr/bin/env python3
"""Unit tests for swf_inflate.py, swf_info.py and anchor.py. Run: python3 tests/test_swf_tools.py"""
import lzma
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(HERE)
sys.path.insert(0, TOOLS)
import swf_inflate  # noqa: E402
import swf_info  # noqa: E402


def rect(xmax, ymax):
    """RECT with Xmin=Ymin=0, values in twips, nbits=16."""
    nbits = 16
    bits = format(nbits, "05b") + format(0, "016b") + format(xmax, "016b") + format(0, "016b") + format(ymax, "016b")
    bits += "0" * (-len(bits) % 8)
    return bytes(int(bits[i:i + 8], 2) for i in range(0, len(bits), 8))


def tag(code, payload):
    if len(payload) < 63:
        return struct.pack("<H", (code << 6) | len(payload)) + payload
    return struct.pack("<HI", (code << 6) | 63, len(payload)) + payload


def make_fws(abc=False, atf=False):
    body = rect(550 * 20, 400 * 20) + struct.pack("<HH", 24 << 8, 3)
    if abc:
        body += tag(82, struct.pack("<I", 0) + b"main\0" + b"\x10\x00\x2e\x00")
    else:
        body += tag(12, b"\x00")
    if atf:
        body += tag(87, struct.pack("<HI", 1, 0) + b"ATF\x00\x00\x00\x00\x00")
    body += tag(87, struct.pack("<HI", 2, 0) + b"plain data")
    body += tag(0, b"")
    return b"FWS" + bytes([9]) + struct.pack("<I", 8 + len(body)) + body


def make_cws(fws):
    return b"CWS" + fws[3:8] + zlib.compress(fws[8:])


def make_zws(fws):
    body = fws[8:]
    filt = [{"id": lzma.FILTER_LZMA1, "dict_size": 1 << 16, "lc": 3, "lp": 0, "pb": 2}]
    alone = lzma.compress(body, format=lzma.FORMAT_ALONE, filters=filt)
    props, data = alone[:5], alone[13:]
    return b"ZWS" + fws[3:8] + struct.pack("<I", len(data)) + props + data


class InflateTests(unittest.TestCase):
    def test_roundtrip(self):
        fws = make_fws()
        self.assertEqual(swf_inflate.inflate_bytes(fws), fws)
        self.assertEqual(swf_inflate.inflate_bytes(make_cws(fws)), fws)
        self.assertEqual(swf_inflate.inflate_bytes(make_zws(fws)), fws)

    def test_errors(self):
        for bad in (b"", b"GIF89a....", b"CWS\x09\x20\x00\x00\x00junk", b"ZWS\x09\x20\x00\x00\x00" + b"x" * 20):
            with self.assertRaises(swf_inflate.SwfError):
                swf_inflate.inflate_bytes(bad)

    def test_cli(self):
        fws = make_fws()
        with tempfile.TemporaryDirectory() as t:
            for name, data in (("c", make_cws(fws)), ("z", make_zws(fws)), ("f", fws)):
                src, dst = os.path.join(t, name + ".swf"), os.path.join(t, name + ".out")
                open(src, "wb").write(data)
                r = subprocess.run([sys.executable, os.path.join(TOOLS, "swf_inflate.py"), src, dst])
                self.assertEqual(r.returncode, 0)
                self.assertEqual(open(dst, "rb").read(), fws)
            r = subprocess.run([sys.executable, os.path.join(TOOLS, "swf_inflate.py"), "/nonexistent", t + "/o"],
                               capture_output=True)
            self.assertEqual(r.returncode, 2)
            open(os.path.join(t, "bad"), "wb").write(b"nope nope nope")
            r = subprocess.run([sys.executable, os.path.join(TOOLS, "swf_inflate.py"), t + "/bad", t + "/o"],
                               capture_output=True)
            self.assertEqual(r.returncode, 3)


class InfoTests(unittest.TestCase):
    def test_info(self):
        for abc, atf in ((False, False), (True, True)):
            fws = make_fws(abc, atf)
            for blob, comp in ((fws, "none (FWS)"), (make_cws(fws), "zlib (CWS)"), (make_zws(fws), "LZMA (ZWS)")):
                info = swf_info.analyse(blob)
                self.assertEqual(info["version"], 9)
                self.assertEqual(info["stage"], (550, 400))
                self.assertEqual(info["frame_rate"], 24.0)
                self.assertEqual(info["frames"], 3)
                self.assertEqual(info["compression"], comp)
                self.assertEqual(info["abc"] > 0, abc)
                self.assertEqual(info["doaction"] > 0, not abc)
                self.assertEqual(info["binary_data"], 2 if atf else 1)
                self.assertEqual(info["atf"], 1 if atf else 0)


class AnchorTests(unittest.TestCase):
    def test_selftest(self):
        import anchor
        anchor._selftest()


if __name__ == "__main__":
    unittest.main(verbosity=2)

#!/usr/bin/env python3
"""swf_inflate.py <in.swf> <out.swf>

Rewrite a compressed SWF as an uncompressed one (FWS), so binary deltas (xdelta3)
and byte level tools see stable, plain data.

Supported inputs
  FWS  uncompressed: copied unchanged.
  CWS  zlib: 'CWS' ver len4, then a zlib stream of everything after byte 8.
  ZWS  LZMA: 'ZWS' ver len4 clen4 props5 data
         bytes 0..2   signature 'ZWS'
         byte  3      version
         bytes 4..7   uncompressed file length (little endian, includes the 8 byte header)
         bytes 8..11  compressed length (little endian, of the LZMA data after the props; not
                      needed for decoding and ignored here, writers disagree about it)
         bytes 12..16 LZMA properties (lc/lp/pb byte, then 4 byte dictionary size)
         bytes 17..   raw LZMA data with NO end marker length field
       This is not a .lzma "alone" file: the alone format wants props5 + uncompressed
       size (8 bytes) + data. We rebuild that header (props5 + size8) and use
       lzma.FORMAT_ALONE, passing the known uncompressed size (len4 - 8).

Exit codes: 0 ok, 1 usage, 2 unreadable input, 3 unsupported or corrupt SWF.
"""
import lzma
import struct
import sys
import zlib


class SwfError(Exception):
    pass


def inflate_bytes(d):
    """Return the FWS bytes for any SWF bytes. Raises SwfError."""
    if len(d) < 8:
        raise SwfError("file too short to be a SWF")
    sig = d[:3]
    if sig == b"FWS":
        return d
    if sig == b"CWS":
        try:
            body = zlib.decompress(d[8:])
        except zlib.error as e:
            raise SwfError("corrupt CWS (zlib) data: %s" % e)
        out = b"FWS" + d[3:8] + body
    elif sig == b"ZWS":
        if len(d) < 17:
            raise SwfError("truncated ZWS header")
        total = struct.unpack("<I", d[4:8])[0]
        props = d[12:17]
        body_len = total - 8
        if body_len < 0:
            raise SwfError("bad ZWS length field")
        alone = props + struct.pack("<Q", body_len) + d[17:]
        try:
            body = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE).decompress(alone)
        except lzma.LZMAError as e:
            raise SwfError("corrupt ZWS (LZMA) data: %s" % e)
        out = b"FWS" + d[3:8] + body
    else:
        raise SwfError("not a SWF (signature %r)" % sig)
    declared = struct.unpack("<I", out[4:8])[0]
    if declared != len(out):
        raise SwfError("length mismatch after inflate: header says %d, got %d" % (declared, len(out)))
    return out


def main(argv):
    if len(argv) != 3:
        sys.stderr.write(__doc__.split("\n\n")[0] + "\n")
        return 1
    try:
        with open(argv[1], "rb") as f:
            d = f.read()
    except OSError as e:
        sys.stderr.write("swf_inflate: cannot read %s: %s\n" % (argv[1], e))
        return 2
    try:
        out = inflate_bytes(d)
    except SwfError as e:
        sys.stderr.write("swf_inflate: %s: %s\n" % (argv[1], e))
        return 3
    tmp = argv[2] + ".tmp"
    with open(tmp, "wb") as f:
        f.write(out)
    import os
    os.replace(tmp, argv[2])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

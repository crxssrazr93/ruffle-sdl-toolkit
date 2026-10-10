#!/usr/bin/env python3
"""swf_info.py <file.swf> [more.swf ...]

Prints version, compression, uncompressed length, stage size, frame rate, frame count,
whether the SWF carries AVM2 code (DoABC tags) or only AVM1 code (DoAction / DoInitAction),
the number of DefineBinaryData tags and how many of them start with the ATF signature.
Pure python, no dependencies. Only the top level tag list is read (sprites are not
descended into, so DoAction inside sprite frames is not counted).
Exit codes: 0 ok, 1 usage, 2 unreadable, 3 not a SWF.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import swf_inflate  # noqa: E402

COMPRESSION = {b"FWS": "none (FWS)", b"CWS": "zlib (CWS)", b"ZWS": "LZMA (ZWS)"}


def read_rect(d, pos):
    nbits = d[pos] >> 3
    total = 5 + nbits * 4
    nbytes = (total + 7) // 8
    bits = "".join(format(b, "08b") for b in d[pos:pos + nbytes])
    vals = []
    off = 5
    for _ in range(4):
        v = int(bits[off:off + nbits], 2) if nbits else 0
        if nbits and v >> (nbits - 1):
            v -= 1 << nbits
        vals.append(v)
        off += nbits
    return vals, pos + nbytes


def analyse(raw):
    comp = COMPRESSION.get(raw[:3])
    if comp is None:
        raise swf_inflate.SwfError("not a SWF (signature %r)" % raw[:3])
    d = swf_inflate.inflate_bytes(raw)
    info = {"version": d[3], "compression": comp, "length": len(d)}
    (xmin, xmax, ymin, ymax), pos = read_rect(d, 8)
    info["stage"] = ((xmax - xmin) // 20, (ymax - ymin) // 20)
    info["frame_rate"] = d[pos + 1] + d[pos] / 256.0
    info["frames"] = struct.unpack("<H", d[pos + 2:pos + 4])[0]
    pos += 4
    abc = doaction = binary = atf = 0
    tags = 0
    while pos + 2 <= len(d):
        (h,) = struct.unpack("<H", d[pos:pos + 2])
        code, ln = h >> 6, h & 63
        pos += 2
        if ln == 63:
            (ln,) = struct.unpack("<I", d[pos:pos + 4])
            pos += 4
        payload = d[pos:pos + ln]
        pos += ln
        tags += 1
        if code == 0:
            break
        if code == 82 or code == 72:
            abc += 1
        elif code in (12, 59):
            doaction += 1
        elif code == 87:
            binary += 1
            if payload[6:9] == b"ATF":
                atf += 1
    info.update(tags=tags, abc=abc, doaction=doaction, binary_data=binary, atf=atf)
    return info


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__.split("\n\n")[0] + "\n")
        return 1
    rc = 0
    for path in argv[1:]:
        try:
            with open(path, "rb") as f:
                raw = f.read()
        except OSError as e:
            sys.stderr.write("swf_info: cannot read %s: %s\n" % (path, e))
            rc = max(rc, 2)
            continue
        try:
            i = analyse(raw)
        except (swf_inflate.SwfError, IndexError, struct.error) as e:
            sys.stderr.write("swf_info: %s: %s\n" % (path, e))
            rc = max(rc, 3)
            continue
        if i["abc"]:
            code = "AVM2 (ActionScript 3, %d DoABC tags)" % i["abc"]
        elif i["doaction"]:
            code = "AVM1 only (ActionScript 1/2, %d DoAction tags)" % i["doaction"]
        else:
            code = "no script tags at top level"
        print("file:          %s" % path)
        print("version:       %d" % i["version"])
        print("compression:   %s" % i["compression"])
        print("uncompressed:  %d bytes" % i["length"])
        print("stage:         %dx%d px" % i["stage"])
        print("frame rate:    %.2f fps" % i["frame_rate"])
        print("frames:        %d" % i["frames"])
        print("code:          %s" % code)
        print("binary data:   %d DefineBinaryData tags, %d start with ATF" % (i["binary_data"], i["atf"]))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))

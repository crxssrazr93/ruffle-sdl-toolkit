#!/usr/bin/env python3
"""Regenerates the tiny JPEG XR endpoint planes used by the cargo tests.

Needs numpy and imagecodecs (pip install imagecodecs numpy). The outputs are checked in, so the
tests do not need Python. Lossless encodes (level=None) of synthetic data, no game content.
Planes are (w/4) x (h/2): top half endpoint 0, bottom half endpoint 1, one pixel per 4x4 block.
"""
import os
import numpy as np
import imagecodecs

here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")
os.makedirs(here, exist_ok=True)

def save(name, arr):
    blob = imagecodecs.jpegxr_encode(arr, level=None)
    with open(os.path.join(here, name), "wb") as f:
        f.write(blob)
    print(name, len(blob), "bytes")

# 8x8 texture = 2x2 blocks, plane is 2 wide, 4 high.
# Endpoint 0 (top two rows): red, green, blue, near white. Endpoint 1 (bottom): all black.
c = np.zeros((4, 2, 3), np.uint8)
c[0, 0] = (248, 0, 0)
c[0, 1] = (0, 252, 0)
c[1, 0] = (0, 0, 248)
c[1, 1] = (248, 252, 248)
save("color_2x4_rgb24.jxr", c)

# Alpha endpoints (8 bit gray): alpha0 per block, alpha1 = 0.
a = np.zeros((4, 2), np.uint8)
a[0, 0], a[0, 1], a[1, 0], a[1, 1] = 255, 128, 64, 200
save("alpha_2x4_gray8.jxr", a)

# 4x4 texture = 1 block, plane is 1 wide, 2 high: endpoint 0 red, endpoint 1 blue.
b = np.zeros((2, 1, 3), np.uint8)
b[0, 0] = (248, 0, 0)
b[1, 0] = (0, 0, 248)
save("color_1x2_rgb24.jxr", b)

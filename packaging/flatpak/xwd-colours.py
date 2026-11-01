#!/usr/bin/env python3
"""Prints how many distinct colours an Xvfb screen shows.

usage: xwd-colours.py <fbdir>/Xvfb_screen0

`Xvfb -fbdir DIR` keeps each screen's framebuffer in DIR as an XWD file that
is updated as clients draw. An empty screen (Xvfb -br) is one colour; a
rendered Flutter window is many (text antialiasing alone gives dozens).
Prints 0 while the file does not exist yet.
"""
import struct
import sys

try:
    with open(sys.argv[1], "rb") as f:
        data = f.read()
except FileNotFoundError:
    print(0)
    sys.exit(0)

# XWDFileHeader: 25 big-endian CARD32 fields.
h = struct.unpack(">25I", data[:100])
header_size, width, height = h[0], h[4], h[5]
bits_per_pixel, bytes_per_line, ncolors = h[11], h[12], h[19]
if bits_per_pixel != 32:
    sys.exit(f"expected a 32 bpp screen, got {bits_per_pixel}")
offset = header_size + ncolors * 12  # each XWDColor is 12 bytes
colours = set()
for y in range(0, height, 2):
    row = data[offset + y * bytes_per_line:offset + y * bytes_per_line + width * 4]
    colours.update(memoryview(row).cast("I"))
print(len(colours))

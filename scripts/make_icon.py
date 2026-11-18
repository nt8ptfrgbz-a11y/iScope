#!/usr/bin/env python3
"""Draw iScope's geometric app icon using only the Python standard library."""
from pathlib import Path
import math
import struct
import zlib


def png(size):
    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            px, py = (x + 0.5) / size, (y + 0.5) / size
            dx, dy = max(abs(px - 0.5) - 0.24, 0), max(abs(py - 0.5) - 0.24, 0)
            edge = (math.hypot(dx, dy) - 0.18) * size
            alpha = max(0, min(1, 0.5 - edge))
            mix = (px + py) / 2
            color = [int(46 + mix * 29), int(111 - mix * 46), int(243 - mix * 28)]
            radius = math.hypot(px - 0.5, py - 0.5)
            shape = min(abs(radius - 0.25), abs(radius - 0.13)) - 0.012
            if abs(px - 0.5) < 0.026 or abs(py - 0.5) < 0.026:
                shape = 1
            if (abs(px - 0.5) < 0.012 and abs(py - 0.5) < 0.32) or (abs(py - 0.5) < 0.012 and abs(px - 0.5) < 0.32):
                shape = min(shape, -0.02)
            shape = min(shape, math.hypot(px - 0.5, py - 0.5) - 0.038)
            white = max(0, min(1, 0.5 - shape * size))
            color = [int(c * (1 - white) + 255 * white) for c in color]
            rows.extend((*color, int(alpha * 255)))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")


body = bytearray()
for size, tag in [(16, b"icp4"), (32, b"icp5"), (64, b"icp6"), (128, b"ic07"), (256, b"ic08"), (512, b"ic09"), (1024, b"ic10")]:
    data = png(size)
    body.extend(tag + struct.pack(">I", len(data) + 8) + data)
destination = Path(__file__).resolve().parents[1] / "Resources/AppIcon.icns"
destination.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
print(f"Generated {destination.name}")

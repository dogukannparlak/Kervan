#!/usr/bin/env python3
"""Kervan simgesi: turuncu yuvarlak kare üstünde beyaz "K". Bağımlılıksız PNG üretir.

Çıktılar: extension/icons/{16,32,48,128}.png ve resources/AppIcon.icns (iconutil ile).
Kullanım: python3 scripts/make-icons.py
"""
import math
import os
import shutil
import struct
import subprocess
import tempfile
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def seg_dist(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def png(n):
    rows, radius, samples = [], 0.22, 4
    for y in range(n):
        row = bytearray([0])
        for x in range(n):
            r = g = b = a = 0
            for sy in range(samples):
                for sx in range(samples):
                    u, v = (x + (sx + .5) / samples) / n, (y + (sy + .5) / samples) / n
                    qx, qy = max(abs(u - .5) - (.5 - radius), 0), max(abs(v - .5) - (.5 - radius), 0)
                    if math.hypot(qx, qy) > radius:
                        continue
                    k = min(seg_dist(u, v, .34, .24, .34, .76), seg_dist(u, v, .36, .52, .68, .24), seg_dist(u, v, .44, .45, .70, .76))
                    cr, cg, cb = (255, 255, 255) if k < .085 else (232, 131, 58)
                    r, g, b, a = r + cr, g + cg, b + cb, a + 1
            if a == 0:
                row += bytes(4)
            else:
                row += bytes([round(r / a), round(g / a), round(b / a), round(255 * a / samples ** 2)])
        rows.append(bytes(row))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b""))


def main():
    for n in (16, 32, 48, 128):
        with open(os.path.join(ROOT, "extension", "icons", f"{n}.png"), "wb") as f:
            f.write(png(n))
    iconset = os.path.join(tempfile.mkdtemp(), "AppIcon.iconset")
    os.makedirs(iconset)
    for n in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            with open(os.path.join(iconset, f"icon_{n}x{n}{'@2x' if scale == 2 else ''}.png"), "wb") as f:
                f.write(png(n * scale))
    os.makedirs(os.path.join(ROOT, "resources"), exist_ok=True)
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(ROOT, "resources", "AppIcon.icns")], check=True)
    shutil.rmtree(os.path.dirname(iconset))


if __name__ == "__main__":
    main()

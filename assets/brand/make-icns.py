#!/usr/bin/env python3
"""Build a modern ICNS container from an Apple-named .iconset directory."""

from __future__ import annotations

import struct
import sys
from pathlib import Path


CHUNKS = (
    (b"icp4", "icon_16x16.png"),
    (b"icp5", "icon_32x32.png"),
    (b"icp6", "icon_32x32@2x.png"),
    (b"ic07", "icon_128x128.png"),
    (b"ic08", "icon_256x256.png"),
    (b"ic09", "icon_512x512.png"),
    (b"ic10", "icon_512x512@2x.png"),
    (b"ic11", "icon_16x16@2x.png"),
    (b"ic12", "icon_32x32@2x.png"),
    (b"ic13", "icon_128x128@2x.png"),
    (b"ic14", "icon_256x256@2x.png"),
)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: make-icns.py ICONSET OUTPUT.icns", file=sys.stderr)
        return 2

    source = Path(sys.argv[1])
    output = Path(sys.argv[2])
    body = bytearray()
    for kind, name in CHUNKS:
        data = (source / name).read_bytes()
        body.extend(kind)
        body.extend(struct.pack(">I", len(data) + 8))
        body.extend(data)

    output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

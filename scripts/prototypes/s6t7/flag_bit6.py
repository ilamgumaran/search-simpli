#!/usr/bin/env python3
"""S6-T7 Phase 1: what a library from `main` does with a text-once index.

    python3 -I flag_bit6.py MANIFEST_FILE

Sets bit 6 (0x0040, `text_once`, manifest v2.4) in a `HYBMAN02` manifest's
flags, in place, and recomputes the manifest's FNV-1a 64 checksum (over the
bytes before it and the payload after it; its offset follows bits 3 and 4,
`docs/manifest-format-v2.md`). Checks first that the checksum it would write
for the unchanged bytes equals the stored one. Run it on a copy of an index
only; nothing else in the directory changes, so the sections are still
`main`'s and only the flag differs.
"""

import struct
import sys
from pathlib import Path


def fnv1a(data: bytes) -> int:
    h = 0xCBF29CE484222325
    for b in data:
        h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


def main() -> int:
    path = Path(sys.argv[1])
    data = bytearray(path.read_bytes())
    assert data[:8] == b"HYBMAN02", "not a v2 manifest"
    flags = struct.unpack_from("<H", data, 10)[0]
    at = 96 + (48 if flags & 0x08 else 0) + (16 if flags & 0x10 else 0)
    stored = struct.unpack_from("<Q", data, at)[0]
    if fnv1a(bytes(data[:at] + data[at + 8:])) != stored:
        print("the stored checksum is not FNV-1a over the expected bytes; not changed")
        return 1
    struct.pack_into("<H", data, 10, flags | 0x40)
    struct.pack_into("<Q", data, at, fnv1a(bytes(data[:at] + data[at + 8:])))
    path.write_bytes(bytes(data))
    print(f"flags 0x{flags:04x} -> 0x{flags | 0x40:04x}, checksum at offset {at} recomputed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

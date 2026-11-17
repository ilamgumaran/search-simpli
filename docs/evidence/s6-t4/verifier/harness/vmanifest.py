#!/usr/bin/env python3
"""Patch a HYBMAN02 manifest: vmanifest.py MANIFEST [--flags-xor N] [--lexical SECTION_FILE]
Finds the manifest checksum (FNV-1a over the bytes before it and after it) by search, applies the
patch, recomputes it. --lexical sets the lexical length (60) and checksum (68) from a v2/v3 section."""
import struct, sys
sys.path.insert(0, __import__('os').path.dirname(__file__))
from lexdec import fnv1a64
p = sys.argv[1]; m = bytearray(open(p, 'rb').read())
cs = next(o for o in range(64, 400, 4) if o + 8 <= len(m) and fnv1a64(bytes(m[:o] + m[o + 8:])) == struct.unpack_from('<Q', m, o)[0])
args = sys.argv[2:]
while args:
    a = args.pop(0)
    if a == '--flags-xor':
        f = struct.unpack_from('<H', m, 10)[0] ^ int(args.pop(0), 0); struct.pack_into('<H', m, 10, f)
    elif a == '--lexical':
        s = open(args.pop(0), 'rb').read(); hl = {b'HYBLEX03': 88, b'HYBLEX02': 80, b'HYBLEX01': 64}[s[:8]]
        struct.pack_into('<Q', m, 60, len(s)); struct.pack_into('<Q', m, 68, struct.unpack_from('<Q', s, hl - 8)[0])
struct.pack_into('<Q', m, cs, fnv1a64(bytes(m[:cs] + m[cs + 8:])))
open(p, 'wb').write(m); print('manifest checksum at', cs, 'flags', hex(struct.unpack_from('<H', m, 10)[0]))

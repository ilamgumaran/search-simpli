#!/usr/bin/env python3
"""S6-T24 Part 1: facts about the analyser's simple case fold that the `scan` design relies on.

    python3 -I fold_facts.py zig/src/core/unicode_tables.zig

Reads `casefold_pairs` from the generated table and prints: the number of pairs; the code points outside ASCII that
fold into ASCII (the only ones an ASCII case-insensitive byte search could miss); the largest fold orbit (the code
points that fold to one target, the target included); and how many pairs change the UTF-8 length (why folding is
done per code point, never by rewriting bytes in place).
"""
from __future__ import annotations

import re
import sys
from collections import defaultdict


def main(argv: list[str]) -> int:
    text = open(argv[0], encoding="utf-8").read()
    body = text[text.index("pub const casefold_pairs"):]
    body = body[: body.index("};")]
    pairs = [(int(a, 16), int(b, 16)) for a, b in re.findall(r"from = 0x([0-9A-Fa-f]+), \.to = 0x([0-9A-Fa-f]+)", body)]
    print(f"pairs {len(pairs)}")
    into_ascii = [(a, b) for a, b in pairs if a >= 0x80 and b < 0x80]
    print("non-ASCII folding into ASCII " + ", ".join(f"U+{a:04X}->{chr(b)}" for a, b in into_ascii))
    orbits: dict[int, set[int]] = defaultdict(set)
    for a, b in pairs:
        orbits[b].update((a, b))
    largest = max(len(v) for v in orbits.values())
    print(f"largest orbit {largest}, orbits of that size {sum(1 for v in orbits.values() if len(v) == largest)}")
    print(f"pairs changing UTF-8 length {sum(1 for a, b in pairs if len(chr(a).encode()) != len(chr(b).encode()))}")
    tamil = [a for a, _ in pairs if 0x0B80 <= a <= 0x0BFF]
    print(f"Tamil code points with a fold {len(tamil)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

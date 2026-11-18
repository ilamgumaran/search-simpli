#!/usr/bin/env python3
"""S6-T8: index sizes of two index directories per corpus, from measured bytes.

    python3 -I sizes.py MAIN_ROOT HEAD_ROOT CORPUS...

For each CORPUS, MAIN_ROOT/CORPUS and HEAD_ROOT/CORPUS are index directories
of the same folder. Prints, per corpus: the bytes of every file of the
current generation (MANIFEST, INDEX-STATE.json and each section file whose
name ends in -<generation>.<ext>, WRITER.LOCK excluded), the content lexical
section's bytes, and its section 5 (offsets) length from the section's
header; each with the change in bytes and in percent of main's, one decimal,
a saving truncated toward zero and a growth rounded up (never rounded in the
branch's favour). Also checks
that every section other than the content lexical section and the manifest
is the same bytes. Not part of any library.
"""
import json
import struct
import sys
from pathlib import Path


def generation(index: Path) -> int:
    return int.from_bytes((index / "MANIFEST").read_bytes()[12:20], "little")


def files(index: Path) -> dict[str, int]:
    g = generation(index)
    out = {}
    for f in sorted(index.iterdir()):
        if f.name in ("MANIFEST", "INDEX-STATE.json") or f.stem.endswith(f"-{g}"):
            out[f.name] = f.stat().st_size
    return out


def offsets_length(lexical: bytes) -> int:
    # v2: 80-byte header, v3/v4: 88; section lengths at 32..72 in both.
    return struct.unpack_from("<5Q", lexical, 32)[4]


def pct(change: int, base: int) -> str:
    # One decimal: a saving truncated toward zero, a growth rounded up, so
    # neither is shown in the branch's favour.
    tenths = abs(change) * 1000 // base if change < 0 else -(-change * 1000 // base)
    sign = "-" if change < 0 else "+"
    return f"{sign}{tenths // 10}.{tenths % 10}%"


def main(argv):
    main_root, head_root = Path(argv[1]), Path(argv[2])
    rows = []
    for corpus in argv[3:]:
        m, h = main_root / corpus, head_root / corpus
        fm, fh = files(m), files(h)
        gm, gh = generation(m), generation(h)
        lm = (m / f"lexical-{gm}.hyblex").read_bytes()
        lh = (h / f"lexical-{gh}.hyblex").read_bytes()
        same_others = all(
            (m / a).read_bytes() == (h / b).read_bytes()
            for a, b in zip(sorted(fm), sorted(fh))
            if not a.startswith("lexical-") and a not in ("MANIFEST", "INDEX-STATE.json"))
        row = {
            "corpus": corpus,
            "magic": [lm[:8].decode(), lh[:8].decode()],
            "total": [sum(fm.values()), sum(fh.values())],
            "lexical": [len(lm), len(lh)],
            "offsets": [offsets_length(lm), offsets_length(lh)],
            "manifest": [fm["MANIFEST"], fh["MANIFEST"]],
            "other_sections_identical": same_others,
        }
        rows.append(row)
        print(json.dumps(row))
    print()
    print("| Corpus | Measure | main (B) | branch (B) | change (B) | change |")
    print("|---|---|---:|---:|---:|---:|")
    for row in rows:
        for key, label in (("total", "index (current generation)"), ("lexical", "content lexical section"), ("offsets", "section 5 (offsets)")):
            a, b = row[key]
            print(f"| {row['corpus']} | {label} | {a:,} | {b:,} | {b - a:+,} | {pct(b - a, a)} |")


if __name__ == "__main__":
    main(sys.argv)

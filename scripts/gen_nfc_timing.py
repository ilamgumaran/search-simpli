#!/usr/bin/env python3
"""S1-T16: generate the single-line NFC timing inputs.

Writes, into DIR (a temp dir, never committed), for each size in KB:
  korean-<size>k-mark.txt   one line of precomposed Hangul syllables, with one
                            `e` + U+0301 (a combining mark) in the middle, so
                            NFC takes the slow path: every syllable is
                            decomposed to jamo and recomposed;
  korean-<size>k-plain.txt  the same line without the mark (fast path).

    python3 scripts/gen_nfc_timing.py DIR [--sizes 256 1024]

The text is deterministic (a fixed word list), so two runs give equal files.
"""
import argparse
from pathlib import Path

WORDS = ["한글", "학교", "가나다라", "마음의", "구름", "하늘과", "바람", "별빛", "꽃잎", "각막"]


def line(size_bytes, with_mark):
    parts, total = [], 0
    i = 0
    while total < size_bytes:
        w = WORDS[i % len(WORDS)] + " "
        parts.append(w)
        total += len(w.encode("utf-8"))
        i += 1
    if with_mark:
        parts[len(parts) // 2] = "é "
    return "".join(parts).rstrip() + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--sizes", type=int, nargs="+", default=[256, 1024])
    args = ap.parse_args()
    out = Path(args.dir)
    out.mkdir(parents=True, exist_ok=True)
    for kb in args.sizes:
        for mark in (True, False):
            name = f"korean-{kb}k-{'mark' if mark else 'plain'}.txt"
            (out / name).write_text(line(kb * 1024, mark), encoding="utf-8")
            print(out / name)


if __name__ == "__main__":
    main()

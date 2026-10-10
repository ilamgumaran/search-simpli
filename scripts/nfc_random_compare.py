#!/usr/bin/env python3
"""S1-T16: random-string oracle for Zig NFC vs Python `unicodedata`.

Draws N random strings (1 to --maxlen, default 12, codepoints) from a mix of Hangul jamo and
syllables, Tamil, Devanagari and other two-part-vowel scripts, Latin with
combining marks, ASCII, CJK compatibility ideographs, variation selectors,
composition exclusions and singletons, runs them through `zig/src/nfc_dump.zig`
and diffs against `unicodedata.normalize("NFC")`. Exit 0 only at 0 differences.

    python3 scripts/nfc_random_compare.py [--n 200000] [--seed 1610] [--work DIR]
"""
import argparse
import random
import subprocess
import sys
import tempfile
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def hexs(s):
    return " ".join(f"{ord(c):X}" for c in s)


def pools():
    r = lambda a, b: [chr(c) for c in range(a, b + 1)]
    marks = [chr(c) for c in range(0x300, 0x370) if unicodedata.combining(chr(c))]
    all_marks = [chr(c) for c in range(0x20, 0x2000) if unicodedata.combining(chr(c))]
    return {
        "jamo_l": r(0x1100, 0x1112), "jamo_v": r(0x1161, 0x1175), "jamo_t": r(0x11A8, 0x11C2),
        "jamo_old": r(0x1113, 0x115F) + r(0x1176, 0x11A7) + r(0x11C3, 0x11FF),
        "syl": [chr(c) for c in range(0xAC00, 0xD7A4, 7)],
        "tamil": r(0x0B95, 0x0BB9) + r(0x0BBE, 0x0BCD) + [chr(0x0BD7)],
        "deva": r(0x0915, 0x0939) + r(0x093C, 0x094D) + [chr(0x0958), chr(0x0959)],
        "twopart": [chr(c) for c in (0x09C7, 0x09BE, 0x09D7, 0x0B47, 0x0B3E, 0x0B56, 0x0B57, 0x0BC6, 0x0BC7, 0x0BBE,
                                      0x0CC6, 0x0CC2, 0x0CD5, 0x0CD6, 0x0CBF, 0x0D46, 0x0D3E, 0x0DD9, 0x0DCF, 0x0DCA,
                                      0x0DDF, 0x0CBC, 0x0BCD)],
        "latin": list("aeiouAEIOUnscdlyzCGNSZ") ,
        "marks": marks, "all_marks": all_marks,
        "ascii": list("xyz .,-1 "),
        "cjk": r(0xF900, 0xF9FF) + r(0x2F800, 0x2F81F),
        "vs": r(0xFE00, 0xFE0F) + [chr(0xE0100), chr(0xE01EF)],
        "misc": [chr(c) for c in (0x212A, 0x212B, 0x2126, 0x0344, 0x0340, 0x0341, 0x0343, 0x037E, 0x0387, 0x1F71,
                                  0x0958, 0x0929, 0x0931, 0x0934, 0x05D0, 0x05B4, 0x05BC, 0x05C1, 0x3046, 0x3099,
                                  0x309A, 0x30AB, 0x1E0B, 0x0323, 0x0307)],
        "greek": r(0x3B1, 0x3C9) + [chr(0x345), chr(0x301), chr(0x308)],
    }


def draw(rng, p, names, maxlen):
    return "".join(rng.choice(p[rng.choice(names)]) for _ in range(rng.randint(1, maxlen)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=200000)
    ap.add_argument("--seed", type=int, default=1610)
    ap.add_argument("--maxlen", type=int, default=12)
    ap.add_argument("--work", default=None)
    args = ap.parse_args()
    work = Path(args.work) if args.work else Path(tempfile.mkdtemp(prefix="nfc-random-"))
    work.mkdir(parents=True, exist_ok=True)
    p = pools()
    rng = random.Random(args.seed)
    mixes = [
        ["jamo_l", "jamo_v", "jamo_t", "syl", "jamo_old", "marks", "ascii"],
        ["tamil", "twopart", "marks", "ascii"],
        ["deva", "twopart", "marks", "all_marks"],
        ["latin", "marks", "all_marks", "ascii", "syl"],
        ["cjk", "vs", "latin", "syl", "ascii", "marks"],
        ["misc", "greek", "latin", "marks", "all_marks", "twopart", "jamo_v", "jamo_t", "syl"],
    ]
    cases = [draw(rng, p, rng.choice(mixes), args.maxlen) for _ in range(args.n)]
    infile, outfile, exe = work / "in.txt", work / "out.txt", work / "nfc_dump"
    infile.write_text("\n".join(hexs(c) for c in cases) + "\n", encoding="ascii")
    subprocess.run(["zig", "build-exe", "-OReleaseFast", str(ROOT / "zig/src/nfc_dump.zig"), f"-femit-bin={exe}"],
                   check=True, cwd=work, capture_output=True, timeout=500)
    subprocess.run([str(exe), str(infile), str(outfile)], check=True, timeout=500)
    got = outfile.read_text(encoding="ascii").split("\n")
    if got and got[-1] == "":
        got.pop()
    assert len(got) == len(cases), (len(got), len(cases))
    bad = [(c, g) for c, g in zip(cases, got) if g != hexs(unicodedata.normalize("NFC", c))]
    changed = sum(1 for c in cases if unicodedata.normalize("NFC", c) != c)
    print(f"unicodedata {unicodedata.unidata_version}; strings {len(cases)}; NFC changes {changed}; differing {len(bad)}")
    for c, g in bad[:5]:
        print(f"  {hexs(c)} -> zig [{g}] python [{hexs(unicodedata.normalize('NFC', c))}]")
    sys.exit(0 if not bad else 1)


if __name__ == "__main__":
    main()

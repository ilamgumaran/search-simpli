#!/usr/bin/env python3
"""S1-T15 criterion 1: Zig NFC vs Python `unicodedata.normalize("NFC")`.

Cases: every non-surrogate codepoint on its own, the NFD form of each (so
recomposition is exercised), and a set of Hangul / mark sequences. The Zig
side is `zig/src/nfc_dump.zig`, built and run with the toolchain on PATH.
`NormalizationTest.txt` is not available offline; with `--normalization-test
FILE` its part-1 NFC column is checked as well (c2 == NFC(c1) == NFC(c2) ==
NFC(c3)).

    python3 scripts/nfc_compare.py [--work DIR] [--normalization-test FILE]

Prints the number of differing cases and a few examples; exit 0 only at 0.
"""
import argparse
import subprocess
import sys
import tempfile
import unicodedata
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def hexs(s):
    return " ".join(f"{ord(c):X}" for c in s)


def unhex(line):
    return "".join(chr(int(x, 16)) for x in line.split())


def build_cases(norm_test):
    cases = []
    origin = []  # codepoint a case came from, or None for the extra sequences
    for cp in range(0x110000):
        if 0xD800 <= cp <= 0xDFFF:
            continue
        ch = chr(cp)
        cases.append(ch)
        origin.append(cp)
        nfd = unicodedata.normalize("NFD", ch)
        if nfd != ch:
            cases.append(nfd)
            origin.append(cp)
    first_extra = len(cases)
    # Hangul: every L+V, every LV+T, and syllable + trailing mark / jamo.
    for l in range(0x1100, 0x1113):
        for v in range(0x1161, 0x1176):
            cases.append(chr(l) + chr(v))
    for lv in range(0xAC00, 0xD7A4, 28):
        for t in range(0x11A8, 0x11C3):
            cases.append(chr(lv) + chr(t))
    cases += ["가́", "가́", "각́",
              "각ᆨ", "ᄀ́ᅡ", "aᅡ", "ᅡᄀ"]
    if norm_test:
        for line in Path(norm_test).read_text(encoding="utf-8").splitlines():
            if line.startswith("@Part2"):
                break
            if not line or line[0] in "#@":
                continue
            for field in line.split(";")[:5]:
                cases.append(unhex(field))
    origin += [None] * (len(cases) - len(origin))
    return cases, origin


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", default=None)
    ap.add_argument("--normalization-test", default=None)
    args = ap.parse_args()
    work = Path(args.work) if args.work else Path(tempfile.mkdtemp(prefix="nfc-compare-"))
    work.mkdir(parents=True, exist_ok=True)
    cases, origin = build_cases(args.normalization_test)
    infile, outfile = work / "in.txt", work / "out.txt"
    infile.write_text("\n".join(hexs(c) for c in cases) + "\n", encoding="ascii")
    subprocess.run(
        ["zig", "run", "-OReleaseFast", str(ROOT / "zig/src/nfc_dump.zig"), "--",
         str(infile), str(outfile)],
        check=True, cwd=work, capture_output=True, timeout=500,
    )
    got = outfile.read_text(encoding="ascii").split("\n")
    if got and got[-1] == "":
        got.pop()
    assert len(got) == len(cases), (len(got), len(cases))
    bad = []
    bad_cps = set()
    for case, line, cp in zip(cases, got, origin):
        want = hexs(unicodedata.normalize("NFC", case))
        if line != want:
            bad.append((case, line, want))
            if cp is not None:
                bad_cps.add(cp)
    kinds = Counter()
    for c, _, _ in bad:
        x = c[0]
        cp = ord(x)
        kinds["hangul" if 0xAC00 <= cp <= 0xD7A3 or 0x1100 <= cp <= 0x11FF else
              "cjk-compat" if 0xF900 <= cp <= 0xFAFF or 0x2F800 <= cp <= 0x2FA1F else
              "other-singleton" if len(c) == 1 else "other"] += 1
    print(f"unicodedata {unicodedata.unidata_version}; cases {len(cases)}")
    print(f"differing cases {len(bad)} ; codepoints with a differing case (alone or as NFD): {len(bad_cps)}")
    print("by kind:", dict(kinds))
    for case, g, w in bad[:5]:
        print(f"  {hexs(case)} -> zig [{g}] python [{w}]")
    sys.exit(0 if not bad else 1)


if __name__ == "__main__":
    main()

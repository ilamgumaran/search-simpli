#!/usr/bin/env python3
"""S6-T24 verifier probe (Verdict 2): compile time of patterns of up to 1,024 bytes (the cap), where the builder's
time fuzz stops at 256 bytes. Each pattern is run with `searchd scan --folder <one-line folder> --time-ms 1`, five
times; the fastest wall-clock of the five (process start included) and the outcome are printed, against a
one-byte literal as the baseline.

Usage: python3 -I probe_compile_1024.py SEARCHD WORKDIR
"""
import os
import subprocess
import sys
import time

searchd, work = sys.argv[1], sys.argv[2]
folder = os.path.join(work, "c1024")
os.makedirs(folder, exist_ok=True)
with open(os.path.join(folder, "x.txt"), "w", encoding="utf-8") as handle:
    handle.write("a line\n")

pairs = [f"{chr(0x100 + 2 * i)}-{chr(0x101 + 2 * i)}" for i in range(200)]
ranges = "".join(pairs)
cases = [
    ("baseline literal x", "x", []),
    ("one class of 200 ranges, insensitive", "[" + ranges + "]", ["--case", "insensitive"]),
    ("two classes of 90 ranges, insensitive, {255} each", "[" + "".join(pairs[:90]) + "]{255}[" + "".join(pairs[90:180]) + "]{255}", ["--case", "insensitive"]),
    ("170 nested optional groups", "(?:" * 170 + "a" + ")?" * 170, []),
    ("nested groups 250 deep", "(" * 250 + "a" + ")" * 250, []),
    ("510 alternatives", "|".join(["a"] * 510), []),
    ("alternation of 100 classes {16}", "|".join(["[a-c]{16}"] * 100), []),
    ("[^\\W x 508]{255}", "[^" + "\\W" * 508 + "]{255}", []),
    ("(?:\\b|\\B|^|$){255} nested x 20", "(?:" * 20 + "\\b|\\B|^|$" + "){255}" * 20, []),
    ("(?:a?){1,255} x 32", "(?:a?){1,255}" * 32, []),
    ("whole word, insensitive, 1,000 \\w", "\\w" * 500, ["--case", "insensitive", "--word"]),
]
for name, pattern, flags in cases:
    best, outcome = None, ""
    for _ in range(5):
        start = time.monotonic()
        done = subprocess.run([searchd, "scan", "--folder", folder, pattern, "--regex", "--json", "--time-ms", "1", *flags],
                              capture_output=True, timeout=120)
        took = (time.monotonic() - start) * 1000
        best = took if best is None else min(best, took)
        outcome = "answered" if done.returncode == 0 else done.stderr.decode().strip()[:110]
    print(f"{name}: {len(pattern.encode())} bytes, fastest of 5 {best:.1f} ms, {outcome}")

#!/usr/bin/env python3
"""S6-T24 verifier probe: `searchd scan --folder` against BSD grep (`/usr/bin/grep -n`) and Python's `re`, on
fixtures made for the edges: CRLF, CR only, no final newline, a BOM, an empty file, empty lines, Tamil,
combining marks, ß and ẞ, Turkish dotted and dotless i, the Kelvin sign and long s, `_` and digits beside a
word, anchors, smart case.

For each (pattern, options) the hit lines (path, line) of scan are compared with grep's (LC_ALL=C and
LC_ALL=en_US.UTF-8) and with Python's `re` over `str.splitlines()` of the file decoded as UTF-8 (a leading BOM
removed), with `re.IGNORECASE` for insensitive. Every disagreement is printed; the verdict sorts each into
"documented in docs/scan.md" or not.

Usage: python3 -I probe_grep_oracle.py SEARCHD WORKDIR
"""
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

searchd, work = sys.argv[1], Path(sys.argv[2])
root = work / "grep-fixtures"
if root.exists():
    shutil.rmtree(root)
root.mkdir(parents=True)
FILES = {
    "crlf.txt": b"tide pool\r\nTide\r\nend$\r\n",
    "cr-only.txt": b"tide one\rtide two\rlast\r",
    "no-final-newline.txt": b"first\nsecond tide",
    "bom.txt": b"\xef\xbb\xbftide at start\nnext\n",
    "empty.txt": b"",
    "empty-lines.txt": b"\n\n\ntide\n\n",
    "tamil.txt": "மழை பெய்தால் மழைக்காலம்\nதமிழ் பள்ளி\n௧௨௩ எண்\n".encode(),
    "marks.txt": "café au lait\ncafé noir\nnaïve\n".encode(),
    "sharp-s.txt": "Straße\nSTRASSE\nstrasse\nGROẞE\ngroße\n".encode(),
    "turkish.txt": "İstanbul\nistanbul\nISTANBUL\nıi\nIı\n".encode(),
    "kelvin.txt": "300 K\n300 K\n300 k\nſun\nsun\nSUN\nask\nASK\n".encode(),
    "words.txt": b"tide_pool\ntide2\ntide pool\nx_tide\n2tide\n(tide)\ntidepool\n",
    "anchors.txt": b"abc\n abc\nabc \nab\n",
    "sigma.txt": "ΣΊΣΥΦΟΣ\nσίσυφος\nσίσυφοσ\n".encode(),
    "nel.txt": "one\u0085tide two tide\n".encode(),
    "vt-ff.txt": b"a\x0btide\x0cb tide\n",
}
for name, data in FILES.items():
    (root / name).write_bytes(data)

CASES = [
    # (pattern, mode, case, whole_word)
    ("tide", "literal", "sensitive", False),
    ("tide", "literal", "insensitive", False),
    ("Tide", "literal", "smart", False),
    ("tide", "literal", "smart", False),
    ("tide", "literal", "sensitive", True),
    ("^tide", "regex", "sensitive", False),
    ("tide$", "regex", "sensitive", False),
    ("^$", "regex", "sensitive", False),
    ("end\\$$", "regex", "sensitive", False),
    ("abc$", "regex", "sensitive", False),
    ("^abc", "regex", "sensitive", False),
    ("pool", "literal", "sensitive", True),
    ("மழை", "literal", "sensitive", True),
    ("மழை", "literal", "sensitive", False),
    ("\\d+", "regex", "sensitive", False),
    ("café", "literal", "sensitive", False),
    ("cafe", "literal", "sensitive", True),
    ("straße", "literal", "insensitive", False),
    ("strasse", "literal", "insensitive", False),
    ("große", "literal", "insensitive", False),
    ("istanbul", "literal", "insensitive", False),
    ("ı", "literal", "insensitive", False),
    ("k", "literal", "insensitive", False),
    ("K", "literal", "insensitive", False),
    ("sun", "literal", "insensitive", False),
    ("s", "literal", "sensitive", False),
    ("ask", "literal", "smart", False),
    ("σίσυφος", "literal", "insensitive", False),
    ("two", "literal", "sensitive", False),
    ("b tide", "literal", "sensitive", False),
]


def scan_lines(pattern, mode, case, ww):
    argv = [searchd, "scan", "--folder", str(root), pattern, "--json", "--case", case, "--page-size", "100", "--max-per-file", "1000"]
    if mode == "regex":
        argv.append("--regex")
    if ww:
        argv.append("--word")
    done = subprocess.run(argv, capture_output=True)
    if done.returncode:
        return "refused: " + done.stderr.decode().strip()
    answer = json.loads(done.stdout)
    assert answer["next_cursor"] is None
    return sorted((h["path"], h["line"]) for h in answer["hits"])


def grep_lines(pattern, mode, case, ww, locale):
    argv = ["/usr/bin/grep", "-rn", "-F" if mode == "literal" else "-E"]
    if case == "insensitive" or (case == "smart" and pattern == pattern.lower()):
        argv.append("-i")
    if ww:
        argv.append("-w")
    argv += ["-e", pattern, "."]
    done = subprocess.run(argv, capture_output=True, cwd=root, env={"LC_ALL": locale, "PATH": "/usr/bin:/bin"})
    out = []
    for line in done.stdout.split(b"\n"):
        if not line:
            continue
        path, number, _ = line.split(b":", 2)
        out.append((path.decode()[2:], int(number)))
    return sorted(out)


def re_lines(pattern, mode, case, ww):
    rx = re.escape(pattern) if mode == "literal" else pattern
    if ww:
        rx = r"(?<!\w)(?:" + rx + r")(?!\w)"
    flags = re.IGNORECASE if (case == "insensitive" or (case == "smart" and pattern == pattern.lower())) else 0
    out = []
    for name in sorted(FILES):
        text = FILES[name].decode("utf-8")
        if text.startswith("﻿"):
            text = text[1:]
        for number, line in enumerate(text.splitlines(), 1):
            if re.search(rx, line, flags):
                out.append((name, number))
    return sorted(out)


for pattern, mode, case, ww in CASES:
    s = scan_lines(pattern, mode, case, ww)
    oracles = {"grep C": grep_lines(pattern, mode, case, ww, "C"),
               "grep UTF-8": grep_lines(pattern, mode, case, ww, "en_US.UTF-8"),
               "re": re_lines(pattern, mode, case, ww)}
    label = f"{pattern!r} {mode} {case}{' word' if ww else ''}"
    diffs = []
    for name, lines in oracles.items():
        if isinstance(s, str):
            diffs.append(f"{name}: scan {s}")
            continue
        only_scan = sorted(set(s) - set(lines))
        only_oracle = sorted(set(lines) - set(s))
        if only_scan or only_oracle:
            diffs.append(f"{name}: only scan {only_scan} only {name} {only_oracle}")
    print(("same " if not diffs else "DIFF ") + label + (": scan " + str(s) if not diffs else ""))
    for d in diffs:
        print("     " + d)

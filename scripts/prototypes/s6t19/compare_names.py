#!/usr/bin/env python3
"""S6-T19 ruling 2: the same tests run by name, main against head.

    python3 -I scripts/prototypes/s6t19/compare_names.py MAIN_NAMES HEAD_NAMES

Each file is a names.txt of names.sh (one line per line a test binary printed, prefixed
with its step, sorted). A test's line is `STEP: FILE.test.NAME...STATUS`. A moved test
keeps NAME and STATUS while its STEP and FILE change, so the lines are compared twice:
whole (the raw diff), and as the multiset of (NAME, the rest of the line: its status or
its first output) over every test line. Every other line (a summary, a status on a line
of its own, a test's further output) is compared whole. Exit 0 when the
(NAME, STATUS) multisets are equal and the other lines differ only in the step summaries.
"""
from __future__ import annotations

import re
import sys
from collections import Counter
from pathlib import Path

# A test's line: its step, file and name, then `...` and its status, or its own output when it prints
# (the status then follows on a line of its own, sorted elsewhere).
TEST = re.compile(r"^(?P<step>[a-z]+): (?P<file>[A-Za-z0-9_]+)\.test\.(?P<name>.*?)\.\.\.(?P<status>.*)$")
SUMMARY = re.compile(r"^[a-z]+: (All \d+ tests passed\.|\d+ passed; \d+ skipped; \d+ failed\.)$")


def read(path: str):
    tests, other = [], []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        m = TEST.match(line)
        (tests if m else other).append(m.groupdict() if m else line)
    return tests, other


def main(argv) -> int:
    main_tests, main_other = read(argv[1])
    head_tests, head_other = read(argv[2])
    a = Counter((t["name"], t["status"]) for t in main_tests)
    b = Counter((t["name"], t["status"]) for t in head_tests)
    print(f"test lines: main {sum(a.values())} ({Counter(t['status'] for t in main_tests)}), "
          f"head {sum(b.values())} ({Counter(t['status'] for t in head_tests)})")
    print(f"distinct (name, status): main {len(a)}, head {len(b)}")
    only_main, only_head = a - b, b - a
    print(f"(name, status) only on main: {sum(only_main.values())}; only on head: {sum(only_head.values())}")
    for (name, status), n in sorted(only_main.items()):
        print(f"  main only: {name}...{status} x{n}")
    for (name, status), n in sorted(only_head.items()):
        print(f"  head only: {name}...{status} x{n}")
    moved = []
    keyed_main = {(t["name"], t["status"]): (t["step"], t["file"]) for t in main_tests}
    for t in head_tests:
        before = keyed_main.get((t["name"], t["status"]))
        if before and before != (t["step"], t["file"]):
            moved.append((t["name"], before, (t["step"], t["file"])))
    print(f"tests whose step or file changed: {len(moved)}")
    for name, (s0, f0), (s1, f1) in moved:
        print(f"  {name}: {s0} {f0}.zig -> {s1} {f1}.zig")
    om, oh = Counter(main_other), Counter(head_other)
    other_diff = [("main", l, n) for l, n in (om - oh).items()] + [("head", l, n) for l, n in (oh - om).items()]
    print(f"other lines differing: {sum(n for _, _, n in other_diff)}")
    for side, line, n in sorted(other_diff):
        print(f"  {side} only: {line}" + (f" x{n}" if n > 1 else ""))
    ok = not only_main and not only_head and all(SUMMARY.match(line) for _, line, _ in other_diff)
    print("same tests by name and status, only the step summaries differ:", "yes" if ok else "NO")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))

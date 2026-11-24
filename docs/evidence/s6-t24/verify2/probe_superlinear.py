#!/usr/bin/env python3
"""S6-T24 verifier probe: line costs that grow faster than (line length x pattern size), and work the budget
does not see.

Part A, every-match search. `Matcher.matchLine` restarts the Pike VM after each match (Python's `finditer`);
each restart runs until every higher-priority thread dies. For `a(.*b)?` over a line of `a`s each match is
one code point long but the greedy `.*b` thread runs to the line's end, so the line costs
(matches listed, up to the 512-byte text) x (line length) x (pattern size), not (line length) x (pattern size).

Part B, the literal paths. `run` hands the whole rest of the file to `std.mem.findPos` (byte search) or
`std.ascii.findIgnoreCasePos` (ASCII-insensitive), Boyer-Moore-Horspool with an O(n x m) worst case, and
asks the budget only between candidate lines, so a needle such as `b` + 1,023 `a`s over long runs of `a`
is searched with no budget check at all.

Usage: python3 -I probe_superlinear.py SEARCHD WORKDIR
WORKDIR gets one folder per case. Wall-clock seconds of one CLI call (process start included), the exit code
and the answer's `stopped` (or the refusal) are printed. These are probe times on a machine that is not quiet:
ratios and orders of magnitude, not a timing of the build.
"""
import json
import os
import subprocess
import sys
import time

searchd, work = sys.argv[1], sys.argv[2]


def folder(name, content: bytes):
    path = os.path.join(work, name)
    os.makedirs(path, exist_ok=True)
    with open(os.path.join(path, "x.txt"), "wb") as handle:
        handle.write(content)
    return path


def run(label, path, pattern, *flags, limit=120.0):
    argv = [searchd, "scan", "--folder", path, pattern, "--json", *flags]
    start = time.monotonic()
    try:
        done = subprocess.run(argv, capture_output=True, timeout=limit)
    except subprocess.TimeoutExpired:
        print(f"{label}: killed after {limit:.0f} s")
        return
    took = time.monotonic() - start
    if done.returncode == 0:
        answer = json.loads(done.stdout)
        tail = f"stopped {answer['stopped']}, hits {len(answer['hits'])}, cursor {'yes' if answer['next_cursor'] else 'no'}"
    else:
        tail = done.stderr.decode("utf-8", "replace").strip()[:200]
    print(f"{label}: {took:.2f} s, exit {done.returncode}, {tail}")


MiB = 1 << 20
print("Part A: a(.*b)? (regex, sensitive) over one line of n a's")
for n in (1 << 14, 1 << 16, 1 << 18, 1 << 20, 1 << 22):  # Verdict 2 adds 2^22
    path = folder(f"a-{n}", b"a" * n + b"\n")
    run(f"  n={n} budget 30000", path, "a(.*b)?", "--regex", "--case", "sensitive", "--time-ms", "30000")
print("  controls over the same lines: a(b)? (no long-running thread); a.*b (one pass of the whole line, never matches)")
for n in (1 << 16, 1 << 20):
    path = os.path.join(work, f"a-{n}")
    run(f"  a(b)? n={n} budget 30000", path, "a(b)?", "--regex", "--case", "sensitive", "--time-ms", "30000")
    run(f"  a.*b  n={n} budget 30000", path, "a.*b", "--regex", "--case", "sensitive", "--time-ms", "30000")
print("  default budget, n = 2^20:")
run("  n=1048576 budget 2000", os.path.join(work, f"a-{1 << 20}"), "a(.*b)?", "--regex", "--case", "sensitive")

print("  (b + (m-1) a's first: BMH's forward compare fails on the first byte, so that needle is linear)")
print("Part B: literal b + (m-1) a's over a 10 MiB file of lines of 4,095 a's, budget 1 ms")
content = (b"a" * 4095 + b"\n") * (10 * MiB // 4096)
path = folder("lit-10m", content)
for m in (16, 256, 1024):
    for needle, shape in (("b" + "a" * (m - 1), "b+a's"), ("a" * (m - 1) + "b", "a's+b")):
        run(f"  {shape} bytes, m={m}", path, needle, "--case", "sensitive", "--time-ms", "1")
        run(f"  {shape} ascii_ci (smart, the default), m={m}", path, needle, "--time-ms", "1")
print("  control: the same needles over a 10 MiB file of x's")
path = folder("lit-10m-x", (b"x" * 4095 + b"\n") * (10 * MiB // 4096))
for m in (1024,):
    needle = "a" * (m - 1) + "b"
    run(f"  bytes, m={m}", path, needle, "--case", "sensitive", "--time-ms", "1")
    run(f"  ascii_ci, m={m}", path, needle, "--time-ms", "1")

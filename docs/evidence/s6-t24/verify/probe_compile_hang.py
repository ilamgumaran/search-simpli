#!/usr/bin/env python3
"""S6-T24 verifier probe: patterns that make `scan` spend its time compiling, before any budget runs.

A group whose body compiles to no instruction (`(?:)(?:)`, two empty groups) is not refused by
"a repeat follows nothing it can repeat" (only an `.empty` node or an assertion is), so `{255}` around it
is accepted; nested, the compiler walks the body 255^depth times while emitting nothing, so the 8,192-step
cap never fires and the time budget (which starts after compiling) never runs.

Usage: python3 -I probe_compile_hang.py SEARCHD FOLDER
Each case is run with a wall-clock limit; the result line gives the seconds and the outcome.
"""
import subprocess
import sys
import time

searchd, folder = sys.argv[1], sys.argv[2]
EMPTY = "(?:)(?:)"


def nest(depth: int) -> str:
    body = EMPTY
    for _ in range(depth):
        body = "(?:" + body + "){255}"
    return body


cases = [
    ("depth 1", nest(1)),
    ("depth 2", nest(2)),
    ("depth 3", nest(3)),
    ("depth 4", nest(4)),
    ("anchors depth 3", "(?:(?:(?:^$){255}){255}){255}"),
    ("word-boundary depth 3", "(?:(?:(?:\\b\\B){255}){255}){255}"),
]
LIMIT = 20.0
for name, pat in cases:
    start = time.monotonic()
    try:
        done = subprocess.run([searchd, "scan", "--folder", folder, pat, "--regex", "--json", "--time-ms", "1"],
                              capture_output=True, timeout=LIMIT)
        took = time.monotonic() - start
        out = (done.stdout or done.stderr).decode("utf-8", "replace")[:160].replace("\n", " ")
        print(f"{name}: pattern {len(pat.encode())} bytes, {took:.2f} s, exit {done.returncode}: {out}")
    except subprocess.TimeoutExpired:
        print(f"{name}: pattern {len(pat.encode())} bytes, still running after {LIMIT:.0f} s (killed); --time-ms 1 was asked")

# The same over `searchd serve` (one process, requests answered in order): the depth-4 pattern with
# time_budget_ms 1, then a `status` call. Only when INDEX is given as a third argument.
if len(sys.argv) > 3:
    import json
    index = sys.argv[3]
    server = subprocess.Popen([searchd, "serve", index], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    start = time.monotonic()
    server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "scan", "params": {"pattern": nest(4), "mode": "regex", "time_budget_ms": 1}}) + "\n")
    server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "status", "params": {}}) + "\n")
    server.stdin.flush()
    first = server.stdout.readline()
    t1 = time.monotonic() - start
    second = server.stdout.readline()
    t2 = time.monotonic() - start
    server.stdin.close()
    server.wait(timeout=60)
    print(f"serve: scan depth 4 with time_budget_ms 1 answered after {t1:.2f} s ({first[:60].strip()}...); "
          f"the status call queued behind it answered after {t2:.2f} s")

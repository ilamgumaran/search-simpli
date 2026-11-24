#!/usr/bin/env python3
"""S6-T24 verifier probe (Verdict 3): the index-side pass outside the budget, measured at 10,000 and 100,000
entries.

Folders of N files (N = 10,000 and 100,000), names of 255 bytes (`a` x 245, 6 digits, `.txt`... cut to 255), each
holding `tide`. Two indexes of each: `full` (every file indexed, kept whole) and `skipped` (`--max-file-bytes 1`,
so every file is too_large and lands in the generation's skipped list, which the scan tests against the scope).

Over `serve`, after one `index_status` call has loaded the index, a `scan` with `time_budget_ms` 1 is timed from
request to answer, three times each: no glob; Verdict 2's glob (`*` + 253 `a` + `b`); `path_prefix` of 255
bytes that no file has. The difference between the no-glob time over `skipped` and over an empty folder's index,
and between the glob and no-glob times, gives the pass's cost and its scope test's cost. Per-entry figures are
printed so linearity can be read off: the ratio of the 100,000 time to the 10,000 time.

Usage: python3 -I probe_index_side.py SEARCHD WORKDIR
Every call bounded; every loop bounded.
"""
import json
import subprocess
import sys
import time
from pathlib import Path

searchd, work = sys.argv[1], Path(sys.argv[2])
GLOB = "*" + "a" * 253 + "b"
PREFIX = "z" * 255


def build(n):
    f = work / f"n{n}"
    if not f.exists():
        f.mkdir(parents=True)
        for i in range(n):
            (f / ("a" * 245 + f"{i:06d}.txt")[:255]).write_text("tide\n")
    out = {}
    for label, extra in (("full", []), ("skipped", ["--max-file-bytes", "1"])):
        idx = work / f"n{n}.{label}.idx"
        if not idx.exists():
            subprocess.run([searchd, "index", str(f), "--out", str(idx), *extra], check=True, capture_output=True,
                           timeout=3600)
        out[label] = idx
    return out


def serve_times(index_path, params_list, repeat=3):
    server = subprocess.Popen([searchd, "serve", str(index_path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True)
    rows = []
    try:
        next_id = 1

        def call(method, params):
            nonlocal next_id
            server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": next_id, "method": method, "params": params}) + "\n")
            server.stdin.flush()
            next_id += 1
            start = time.monotonic()
            line = server.stdout.readline()
            return json.loads(line), (time.monotonic() - start) * 1000

        call("index_status", {})
        for label, params in params_list:
            times, last = [], None
            for _ in range(repeat):
                answer, ms = call("scan", params)
                times.append(ms)
                last = answer.get("result") or answer.get("error")
            summary = (f"stopped {last.get('stopped')}, hits {len(last.get('hits', []))}, pending {last.get('pending_files')}, "
                       f"not_scanned {json.dumps(last.get('not_scanned'))}") if isinstance(last, dict) and "hits" in last else str(last)[:200]
            rows.append((label, times, summary))
    finally:
        server.stdin.close()
        server.wait(timeout=120)
    return rows


empty = work / "n0"
empty.mkdir(parents=True, exist_ok=True)
(empty / "one.txt").write_text("other\n")
empty_idx = work / "n0.idx"
if not empty_idx.exists():
    subprocess.run([searchd, "index", str(empty), "--out", str(empty_idx)], check=True, capture_output=True, timeout=600)
cases = [("no glob", {"pattern": "tide", "time_budget_ms": 1}),
         ("glob * + 253 a + b", {"pattern": "tide", "time_budget_ms": 1, "name_glob": GLOB}),
         ("path_prefix z x 255", {"pattern": "tide", "time_budget_ms": 1, "path_prefix": PREFIX})]
print("serve, time_budget_ms 1, ms from request to answer (index loaded first), three runs each")
for label, t, s in serve_times(empty_idx, cases):
    print(f"  one-file index, {label}: {', '.join(f'{x:.1f}' for x in t)}; {s}")
for n in (10000, 100000):
    idx = build(n)
    for kind in ("full", "skipped"):
        for label, t, s in serve_times(idx[kind], cases):
            print(f"  {n} files, {kind}, {label}: {', '.join(f'{x:.1f}' for x in t)} "
                  f"(least {min(t):.1f} ms, {min(t) * 1e6 / n:.0f} ns an entry); {s}")

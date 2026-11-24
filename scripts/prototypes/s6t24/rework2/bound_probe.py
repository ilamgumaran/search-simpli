#!/usr/bin/env python3
"""S6-T24 rework 2: the stated constant timed end to end, outside the default test run (NFR-19, ruling 3).

A scan holds its caller for at most time_budget_ms + 50 ms (docs/scan.md, "Time"), the walk of a folder, the
index's list of files and the read of the file in hand excepted. Each case here is timed through the command
line (the fastest of three runs, less the same command over no file: process start, the walk or the index's
open and list; the read of the file in hand is left in, so the figure is the stricter) and through `searchd serve` (a scan, then an `index_status` call
queued behind it, timed from the request to both answers, after the index was opened by an earlier call), and
printed with "within" or "OVER" against budget + 50 ms.

Cases: the verifier's 1,024-byte classes `[^\\w x 508]{255}` and `[^\\s x 508]{255}` over 2,000 lines of 254 `→`
(Verdict 2, finding 2) at 1 and 1,000 ms; the verifier's 255-byte glob over 20,000 names of 255 bytes (finding
1) at 1 ms; and rework 1's cases from `tests/test_scan.py` (nested empty repeats, `a(.*b)?` over 2^22 a's, a
1,024-byte literal over 10 MiB) at 1 and 5 ms.

Usage: python3 -I bound_probe.py SEARCHD WORKDIR   (WORKDIR is created and filled; nothing is removed)
"""
import json
import os
import subprocess
import sys
import time

searchd, work = sys.argv[1], sys.argv[2]
OVER_MS = 50
os.makedirs(work, exist_ok=True)


def write(path: str, data: bytes) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if not os.path.exists(path):
        with open(path, "wb") as handle:
            handle.write(data)


def index(folder: str) -> str:
    out = folder + ".idx"
    if not os.path.exists(out):
        subprocess.run([searchd, "index", folder, "--out", out], check=True, capture_output=True, timeout=1800)
    return out


def timed(argv: list[str]) -> tuple[float, subprocess.CompletedProcess]:
    best, done = float("inf"), None
    for _ in range(3):
        start = time.monotonic()
        done = subprocess.run([searchd, *argv], capture_output=True, stdin=subprocess.DEVNULL, timeout=300)
        best = min(best, (time.monotonic() - start) * 1000)
    return best, done


def outcome(done: subprocess.CompletedProcess) -> str:
    if done.returncode == 0:
        answer = json.loads(done.stdout)
        return f"stopped {answer['stopped']}, cursor {'yes' if answer['next_cursor'] else 'no'}"
    return "refused: " + done.stderr.decode("utf-8", "replace").strip()[:90]


def verdict(spent: float, budget: int) -> str:
    return "within" if spent <= budget + OVER_MS else "OVER"


def cli(label: str, source: list[str], pattern: str, flags: list[str], budget: int) -> None:
    # The baseline reads no file: a path_prefix no file has (process start, the walk or the index's open and
    # list, and a prefix test per path, which is inside the budget and so makes the baseline larger, not smaller).
    base, _ = timed(["scan", *source, "zq", "--json", "--path-prefix", "\x01", "--time-ms", "30000"])
    took, done = timed(["scan", *source, pattern, "--json", "--time-ms", str(budget), *flags])
    spent = took - base
    print(f"  {label}, --time-ms {budget}: {took:.0f} ms, baseline {base:.0f} ms, so {spent:.0f} ms "
          f"(budget + {spent - budget:.0f}): {verdict(spent, budget)}; {outcome(done)}")


def serve(label: str, index_path: str, params: dict) -> None:
    server = subprocess.Popen([searchd, "serve", index_path], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True)
    try:
        server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 0, "method": "index_status", "params": {}}) + "\n")
        server.stdin.flush()
        server.stdout.readline()
        best, last = float("inf"), None
        for attempt in range(3):
            start = time.monotonic()
            server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 1 + 2 * attempt, "method": "scan", "params": params}) + "\n")
            server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 2 + 2 * attempt, "method": "index_status", "params": {}}) + "\n")
            server.stdin.flush()
            first = json.loads(server.stdout.readline())
            second = json.loads(server.stdout.readline())
            best = min(best, (time.monotonic() - start) * 1000)
            last = (first, second)
        first, second = last
        what = (f"stopped {first['result']['stopped']}" if "result" in first else f"refused: {first['error']['message'][:80]}")
        budget = params["time_budget_ms"]
        print(f"  {label}, serve, time_budget_ms {budget}: scan and the index_status behind it {best:.0f} ms "
              f"(budget + {best - budget:.0f}): {verdict(best, budget)}; {what}; status {'answered' if 'result' in second else 'failed'}")
    finally:
        server.stdin.close()
        server.wait(timeout=60)


print(f"searchd {searchd.rsplit('/', 3)[-3] if searchd.count('/') >= 3 else searchd}; the bound is budget + {OVER_MS} ms")

arrows = os.path.join(work, "arrows")
write(os.path.join(arrows, "x.txt"), ("→" * 254 + "\n").encode() * 2000)
arrows_index = index(arrows)
print("Finding 2: 1,024-byte classes over 2,000 lines of 254 →")
for name, pattern in (("[^\\w x 508]{255}", "[^" + "\\w" * 508 + "]{255}"), ("[^\\s x 508]{255}", "[^" + "\\s" * 508 + "]{255}")):
    for budget in (1, 1000):
        cli(f"{name} folder", ["--folder", arrows], pattern, ["--regex"], budget)
        cli(f"{name} index", [arrows_index], pattern, ["--regex"], budget)
        serve(name, arrows_index, {"pattern": pattern, "mode": "regex", "time_budget_ms": budget})

names = os.path.join(work, "names")
os.makedirs(names, exist_ok=True)
for i in range(20000):
    write(os.path.join(names, "a" * 245 + f"{i:05d}" + ".txt"), b"tide\n")
names_index = index(names)
glob = "*" + "a" * 253 + "b"
print("Finding 1: a 255-byte glob over 20,000 names of 255 bytes (the walk and the index's list are outside)")
cli("glob folder", ["--folder", names], "tide", ["--glob", glob], 1)
cli("glob index", [names_index], "tide", ["--glob", glob], 1)
serve("glob", names_index, {"pattern": "tide", "name_glob": glob, "time_budget_ms": 1})

print("Rework 1's cases, moved here from tests/test_scan.py")
small = os.path.join(work, "small")
write(os.path.join(small, "a.txt"), b"tide pool\nharbour 12\n")
small_index = index(small)
nest = "(?:)(?:)"
for _ in range(5):
    nest = "(?:" + nest + "){255}"
cli("nested empty repeats (53 bytes) folder", ["--folder", small], nest, ["--regex"], 1)
serve("nested empty repeats", small_index, {"pattern": nest, "mode": "regex", "time_budget_ms": 1})
long_a = os.path.join(work, "a-22")
write(os.path.join(long_a, "x.txt"), b"a" * (1 << 22) + b"\n")
cli("a(.*b)? over 2^22 a's", ["--folder", long_a], "a(.*b)?", ["--regex", "--case", "sensitive"], 5)
literal = os.path.join(work, "lit")
write(os.path.join(literal, "x.txt"), (b"a" * 4095 + b"\n") * (10 * (1 << 20) // 4096))
for case in ("sensitive", "smart"):
    cli(f"1,023 a's and b over 10 MiB, case {case}", ["--folder", literal], "a" * 1023 + "b", ["--case", case], 1)

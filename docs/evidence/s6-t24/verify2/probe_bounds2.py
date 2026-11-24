#!/usr/bin/env python3
"""S6-T24 verifier probe (Verdict 2): does a scan hold its caller for at most time_budget_ms + 50 ms?

The Report states the bound with two things outside it: the walk of a folder and the read of the one file in
hand. Each case below is a CLI call (process start included) or a `searchd serve` session, with the wall-clock
milliseconds, the exit code and the answer's `stopped`, cursor and `files_scanned` (or the refusal).

A. The meter's unit. The VM charges one unit a thread step and reads the clock once per 65,536 units, but a
   step on a class instruction tests every item of the class (`Class.member`, a loop; `\\W` is a binary search
   of the word table), and code points outside ASCII skip the class's ASCII table. A 1,024-byte pattern
   `[^\\W x 508]{255}` over lines of 254 `é` keeps up to 254 threads alive at each position, each testing 508
   items. Controls: `[^\\W]{255}` and `[^a]{255}` over the same lines. Then the costlier items: lines of 254
   `→` (not a word code point, so `\\w` searches both the letter and the mark tables) under `[^\\w x 508]{255}`
   and `[^\\s x 508]{255}`, at three budgets and on both sources, each run 3 times.
B. The scope filter. `kept` is built from every file's name by `globMatches` before the loop, with no budget: a
   255-byte glob `*` + 253 `a` + `b` over 20,000 names of 255 bytes (245 `a`, 5 digits, `.txt`). Over an
   index there is no walk to put it under. Control: no glob, and `*.txt`.
C. Many tiny files (the same 20,000 files, 5 bytes each), a literal that never matches.
D. A file at the 10 MiB limit (10,485,760 bytes) and one byte over it.
E. One 10 MiB line with no terminator: a literal (the Verdict's needle, `ascii_ci`) and a regex.
F. A periodic insensitive literal: (ab) x 512 over 10 MiB of `ABAB...` broken every 1,023 bytes.
G. `searchd serve` over the index: the case A pattern and the case B glob with `time_budget_ms` 1, each with an
   `index_status` call queued behind it.

Usage: python3 -I probe_bounds2.py SEARCHD WORKDIR
Probe times on a machine not kept quiet (run alone, nothing else of the verifier's running): orders of
magnitude, not a timing of the build.
Every call is bounded (300 s); every loop is bounded.
"""
import json
import os
import subprocess
import sys
import time

searchd, work = sys.argv[1], sys.argv[2]
LIMIT = 300.0
MiB = 1 << 20


def sd(*argv, limit=LIMIT):
    start = time.monotonic()
    try:
        done = subprocess.run([searchd, *argv], capture_output=True, timeout=limit)
    except subprocess.TimeoutExpired:
        return None, limit * 1000
    return done, (time.monotonic() - start) * 1000


def run(label, *argv):
    done, ms = sd(*argv)
    if done is None:
        print(f"{label}: killed after {LIMIT:.0f} s")
        return
    if done.returncode == 0:
        a = json.loads(done.stdout)
        tail = (f"stopped {a['stopped']}, hits {len(a['hits'])}, files_scanned {a.get('files_scanned')}, "
                f"cursor {'yes' if a.get('next_cursor') else 'no'}")
    else:
        tail = done.stderr.decode("utf-8", "replace").strip()[:220]
    print(f"{label}: {ms:.0f} ms, exit {done.returncode}, {tail}")


def write(path, data: bytes):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if not os.path.exists(path):
        with open(path, "wb") as handle:
            handle.write(data)


def index(folder, out):
    if not os.path.exists(out):
        done, ms = sd("index", folder, "--out", out, limit=1800)
        print(f"  (index of {os.path.basename(folder)}: exit {done.returncode if done else 'killed'}, {ms / 1000:.1f} s)")


print("process start (a literal over an empty folder)")
os.makedirs(os.path.join(work, "empty"), exist_ok=True)
for _ in range(3):
    run("  baseline", "scan", "--folder", os.path.join(work, "empty"), "zzz", "--json", "--time-ms", "1")

# A
a_folder = os.path.join(work, "a-class")
write(os.path.join(a_folder, "x.txt"), ("é" * 254 + "\n").encode() * 2000)
a_index = os.path.join(work, "a-class.idx")
index(a_folder, a_index)
heavy = "[^" + "\\W" * 508 + "]{255}"
print(f"A. heavy class: {len(heavy.encode())}-byte pattern, 2,000 lines of 254 é")
for pat, name in ((heavy, "[^\\W x 508]{255}"), ("[^\\W]{255}", "[^\\W]{255}"), ("[^a]{255}", "[^a]{255}")):
    for tm in ("1", "100", "1000"):
        run(f"  {name} folder --time-ms {tm}", "scan", "--folder", a_folder, pat, "--regex", "--json", "--time-ms", tm)
    run(f"  {name} index --time-ms 1", "scan", a_index, pat, "--regex", "--json", "--time-ms", "1")
arrow_folder = os.path.join(work, "a-arrow")
write(os.path.join(arrow_folder, "x.txt"), ("→" * 254 + "\n").encode() * 2000)
arrow_index = os.path.join(work, "a-arrow.idx")
index(arrow_folder, arrow_index)
heavy_w = "[^" + "\\w" * 508 + "]{255}"
heavy_s = "[^" + "\\s" * 508 + "]{255}"
print(f"A2. costlier items: {len(heavy_w.encode())}-byte patterns, 2,000 lines of 254 →")
for pat, name in ((heavy_w, "[^\\w x 508]{255}"), (heavy_s, "[^\\s x 508]{255}")):
    for tm in ("1", "100", "1000"):
        for _ in range(3):
            run(f"  {name} folder --time-ms {tm}", "scan", "--folder", arrow_folder, pat, "--regex", "--json", "--time-ms", tm)
    for _ in range(3):
        run(f"  {name} index --time-ms 1", "scan", arrow_index, pat, "--regex", "--json", "--time-ms", "1")
a_line = os.path.join(work, "a-class-one-line")
write(os.path.join(a_line, "x.txt"), ("é" * (5 * MiB)).encode())
run("  heavy class over one 10 MiB line of é, no terminator, --time-ms 1", "scan", "--folder", a_line, heavy,
    "--regex", "--json", "--time-ms", "1")

# B, C
b_folder = os.path.join(work, "b-names")
os.makedirs(b_folder, exist_ok=True)
for i in range(20000):
    write(os.path.join(b_folder, "a" * 245 + f"{i:05d}" + ".txt"), b"tide\n")
b_index = os.path.join(work, "b-names.idx")
index(b_folder, b_index)
glob = "*" + "a" * 253 + "b"
print(f"B. glob of {len(glob)} bytes over 20,000 names of 255 bytes")
for g, name in ((None, "no glob"), ("*.txt", "*.txt"), (glob, "* + 253 a + b")):
    extra = ["--glob", g] if g else []
    run(f"  index, {name}, --time-ms 1", "scan", b_index, "tide", "--json", "--time-ms", "1", *extra)
    run(f"  folder, {name}, --time-ms 1", "scan", "--folder", b_folder, "tide", "--json", "--time-ms", "1", *extra)
print("C. 20,000 tiny files, a literal that never matches")
for tm in ("1", "30000"):
    run(f"  index --time-ms {tm}", "scan", b_index, "zzz", "--json", "--time-ms", tm)
    run(f"  folder --time-ms {tm}", "scan", "--folder", b_folder, "zzz", "--json", "--time-ms", tm)

# D
print("D. the 10 MiB limit (lines of 4,095 x then LF)")
block = b"x" * 4095 + b"\n"
for name, size in (("at-limit", 10 * MiB), ("over-limit", 10 * MiB + 1)):
    folder = os.path.join(work, f"d-{name}")
    data = (block * (size // len(block) + 1))[:size]
    write(os.path.join(folder, "x.txt"), data)
    for pat, flags in (("zzz", []), ("x\\d", ["--regex"])):
        for tm in ("1", "30000"):
            run(f"  {name} ({size} B) {pat} --time-ms {tm}", "scan", "--folder", folder, pat, "--json", "--time-ms", tm, *flags)

# E
print("E. one 10 MiB line, no terminator")
e_folder = os.path.join(work, "e-one-line")
write(os.path.join(e_folder, "x.txt"), b"a" * (10 * MiB))
e_index = os.path.join(work, "e-one-line.idx")
index(e_folder, e_index)
needle = "a" * 1023 + "b"
for src, label in (([ "--folder", e_folder], "folder"), ([e_index], "index")):
    run(f"  {label}: needle 1,023 a + b, smart (ascii_ci), --time-ms 1", "scan", *src, needle, "--json", "--time-ms", "1")
    run(f"  {label}: needle, sensitive (bytes), --time-ms 1", "scan", *src, needle, "--json", "--case", "sensitive", "--time-ms", "1")
    run(f"  {label}: regex a(.*b)?, --time-ms 1", "scan", *src, "a(.*b)?", "--regex", "--json", "--time-ms", "1")
    run(f"  {label}: regex a(.*b)?, --time-ms 30000", "scan", *src, "a(.*b)?", "--regex", "--json", "--time-ms", "30000")

# F
print("F. periodic insensitive literal (ab) x 512 over ABAB... broken every 1,023 bytes")
f_folder = os.path.join(work, "f-periodic")
unit = b"AB" * 511 + b"C"
write(os.path.join(f_folder, "x.txt"), (unit * (10 * MiB // len(unit))))
for tm in ("1", "30000"):
    run(f"  --time-ms {tm}", "scan", "--folder", f_folder, "ab" * 512, "--json", "--case", "insensitive", "--time-ms", tm)


# G
def serve_pair(label, index_path, params):
    server = subprocess.Popen([searchd, "serve", index_path], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True)
    try:
        start = time.monotonic()
        server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "scan", "params": params}) + "\n")
        server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "index_status", "params": {}}) + "\n")
        server.stdin.flush()
        first = server.stdout.readline()
        t1 = (time.monotonic() - start) * 1000
        second = server.stdout.readline()
        t2 = (time.monotonic() - start) * 1000
        answer = json.loads(first)
        res = answer.get("result") or {}
        what = (f"stopped {res.get('stopped')}, files_scanned {res.get('files_scanned')}" if "result" in answer
                else f"error {answer.get('error', {}).get('message', '')[:120]}")
        print(f"  {label}: scan answered after {t1:.0f} ms ({what}); index_status queued behind it after {t2:.0f} ms "
              f"({'result' if 'result' in json.loads(second) else 'error'})")
    finally:
        server.stdin.close()
        server.wait(timeout=60)


print("G. searchd serve, time_budget_ms 1, an index_status call queued behind")
serve_pair("heavy class", a_index, {"pattern": heavy, "mode": "regex", "time_budget_ms": 1})
serve_pair("heavy class [^\\w x 508]{255} over →", arrow_index, {"pattern": heavy_w, "mode": "regex", "time_budget_ms": 1})
serve_pair("heavy class [^\\s x 508]{255} over →, time_budget_ms 100", arrow_index, {"pattern": heavy_s, "mode": "regex", "time_budget_ms": 100})
serve_pair("glob * + 253 a + b", b_index, {"pattern": "tide", "name_glob": glob, "time_budget_ms": 1})
serve_pair("control: literal zzz", b_index, {"pattern": "zzz", "time_budget_ms": 1})

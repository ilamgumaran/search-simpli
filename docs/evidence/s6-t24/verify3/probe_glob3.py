#!/usr/bin/env python3
"""S6-T24 verifier probe (Verdict 3, ruling 1): the new glob matcher (`scan.Glob`, shift-and over a 256-bit set)
against an oracle, and its cost inside the budget.

Part 1, answers. A folder of 400 names drawn with seed 2411 from an alphabet holding ASCII, `é` (2 bytes), `த`
(3 bytes), `𝄞` (4 bytes), and the glob's own `*`, `?`, `[`, `]` as name characters, plus fixed long names. For
600 globs drawn from the same alphabet with `*` and `?` as wildcards (no other syntax: `[` and `]` are literal),
the engine's set of matching files (`searchd scan --folder` and over an index, paged to the end) is compared with
(a) a regular expression written here (`*` -> `.*`, `?` -> `.`, every other code point itself, whole name,
DOTALL) and (b) the Python reference's `scan.glob_matches`. Names that the no-glob scan does not list (the walk's
own rules) are left out of the comparison.

Part 2, cost. 20,000 files of 255-byte names, ASCII (245 `a`, 5 digits, `.txt`) and multibyte (`த` x 80, 5 digits,
`.txt`, 252 bytes), each holding `tide`, scanned at `--time-ms 1` and at `--time-ms 30000` with globs built to be
slow: Verdict 2's `*` + 253 `a` + `b`; `*a` x 127 + `b`; `?` x 255; `*` + `த` x 84; `*?` x 127 + `b`. The
30000 ms run gives the whole filter's time (all 20,000 names, 5.1 MB of names); the 1 ms run must stop within
the bound. Over `serve`, a call is queued behind.

Usage: python3 -I probe_glob3.py REPO SEARCHD WORKDIR
Every call bounded (300 s); every loop bounded.
"""
import json
import os
import random
import re
import subprocess
import sys
import time
from pathlib import Path

repo, searchd, work = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
sys.path.insert(0, str(repo))
from src.search_platform import scan as reference  # noqa: E402

LIMIT = 300


def sd(*argv):
    start = time.monotonic()
    done = subprocess.run([searchd, *map(str, argv)], capture_output=True, timeout=LIMIT)
    return done, (time.monotonic() - start) * 1000


def all_paths(src, glob):
    """Every hit path of `q` (each file holds one), paged to the end, at most 2,000 pages."""
    paths, cursor = [], None
    for _ in range(2000):
        argv = ["scan", *src, "q", "--json", "--max-per-file", "1", "--page-size", "100", "--time-ms", "30000"]
        argv += ["--glob", glob] if glob is not None else []
        argv += ["--cursor", cursor] if cursor else []
        done, _ = sd(*argv)
        if done.returncode != 0:
            return None, done.stderr.decode().strip()
        page = json.loads(done.stdout)
        paths += [h["path"] for h in page["hits"]]
        cursor = page["next_cursor"]
        if not cursor:
            return paths, None
    return None, "paging did not end"


def oracle(glob, name):
    rx = "".join(".*" if c == "*" else "." if c == "?" else re.escape(c) for c in glob)
    return re.fullmatch(rx, name, re.DOTALL) is not None


# Part 1
rng = random.Random(2411)
ALPHA = ["a", "b", "a", "b", ".", "-", " ", "é", "த", "𝄞", "*", "?", "[", "]", "x", "0"]
folder = work / "g-names"
if not folder.exists():
    folder.mkdir(parents=True)
    names = set()
    for _ in range(4000):
        if len(names) >= 400:
            break
        name = "".join(rng.choice(ALPHA) for _ in range(rng.randint(1, 30)))
        if name.startswith(".") or name.endswith(" ") or name in (".", ".."):
            continue
        names.add(name)
    names |= {"a" * 200 + "b", "a" * 250, "த" * 80, "𝄞" * 60, "é" * 120 + ".txt", "*?[]" * 20}
    for name in names:
        (folder / name).write_text("q\n")
index = work / "g-names.idx"
if not index.exists():
    subprocess.run([searchd, "index", str(folder), "--out", str(index)], check=True, capture_output=True, timeout=600)
listed, error = all_paths(["--folder", folder], None)
print(f"Part 1: {len(listed)} names listed by the no-glob scan ({error})")
GALPHA = ALPHA + ["*", "*", "?"]
globs = ["*", "?", "**", "*?*", "a*b", "*[*]*", "?" * 30, "*𝄞", "த*", "*.txt", "é*é", "[", "]", "*a*a*a*a*b"]
for _ in range(10000):
    if len(globs) >= 600:
        break
    g = "".join(rng.choice(GALPHA) for _ in range(rng.randint(1, 12)))
    if "/" not in g and len(g.encode()) <= 255:
        globs.append(g)
differ_oracle = differ_reference = differ_index = 0
examples = []
for glob in globs:
    got, error = all_paths(["--folder", folder], glob)
    got_index, error_index = all_paths([index], glob)
    want = [p for p in listed if oracle(glob, p.rsplit("/", 1)[-1])]
    ref = [p for p in listed if reference.glob_matches(glob, p.rsplit("/", 1)[-1])]
    if got != want:
        differ_oracle += 1
        if len(examples) < 10:
            examples.append(f"oracle: {glob!r}: engine {len(got) if got is not None else error} vs {len(want)}; "
                            f"only engine {sorted(set(got or []) - set(want))[:3]} only oracle {sorted(set(want) - set(got or []))[:3]}")
    differ_reference += got != ref
    differ_index += got != got_index
print(f"Part 1: {len(globs)} globs; folder answers differing from the regular-expression oracle {differ_oracle}, "
      f"from the reference's glob_matches {differ_reference}; index differing from folder {differ_index}")
for line in examples:
    print("  " + line)


# Part 2
def make(name, pattern_of):
    f = work / name
    if not f.exists():
        f.mkdir(parents=True)
        for i in range(20000):
            (f / pattern_of(i)).write_text("tide\n")
    idx = work / (name + ".idx")
    if not idx.exists():
        subprocess.run([searchd, "index", str(f), "--out", str(idx)], check=True, capture_output=True, timeout=1800)
    return f, idx


ascii_f, ascii_i = make("g-ascii", lambda i: "a" * 245 + f"{i:05d}.txt")
multi_f, multi_i = make("g-multi", lambda i: "த" * 80 + f"{i:05d}.txt")
slow = [("* + 253 a + b", "*" + "a" * 253 + "b"), ("*a x 127 + b", "*a" * 127 + "b"), ("? x 255", "?" * 255),
        ("* + த x 84", "*" + "த" * 84), ("*? x 127 + b", "*?" * 127 + "b")]
print("Part 2: 20,000 names; ms of one CLI call, process start included")
for label, (f, i) in (("ascii names", (ascii_f, ascii_i)), ("multibyte names", (multi_f, multi_i))):
    for name, glob in slow:
        for src_label, src in (("folder", ["--folder", f]), ("index", [i])):
            row = []
            for tm in ("1", "30000"):
                done, ms = sd("scan", *src, "tide", "--json", "--time-ms", tm, "--glob", glob, "--page-size", "100")
                if done.returncode == 0:
                    a = json.loads(done.stdout)
                    row.append(f"--time-ms {tm}: {ms:.0f} ms, stopped {a['stopped']}, hits {len(a['hits'])}, cursor {'yes' if a['next_cursor'] else 'no'}")
                else:
                    row.append(f"--time-ms {tm}: {ms:.0f} ms, exit {done.returncode} {done.stderr.decode().strip()[:100]}")
            print(f"  {label}, {name} ({len(glob.encode())} B), {src_label}: " + "; ".join(row))
    done, ms = sd("scan", "--folder", f, "tide", "--json", "--time-ms", "1", "--page-size", "100")
    print(f"  {label}, control without a glob, folder --time-ms 1: {ms:.0f} ms")
    done, ms = sd("scan", i, "tide", "--json", "--time-ms", "1", "--page-size", "100")
    print(f"  {label}, control without a glob, index --time-ms 1: {ms:.0f} ms")


def serve_pair(label, index_path, params):
    server = subprocess.Popen([searchd, "serve", str(index_path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True)
    try:
        start = time.monotonic()
        server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "scan", "params": params}) + "\n")
        server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "index_status", "params": {}}) + "\n")
        server.stdin.flush()
        first = json.loads(server.stdout.readline())
        t1 = (time.monotonic() - start) * 1000
        server.stdout.readline()
        t2 = (time.monotonic() - start) * 1000
        res = first.get("result") or {}
        print(f"  serve, {label}: scan {t1:.0f} ms (stopped {res.get('stopped')}), index_status behind it {t2:.0f} ms")
    finally:
        server.stdin.close()
        server.wait(timeout=60)


for name, glob in slow:
    serve_pair(f"ascii names, {name}", ascii_i, {"pattern": "tide", "name_glob": glob, "time_budget_ms": 1})
serve_pair("multibyte names, * + த x 84", multi_i, {"pattern": "tide", "name_glob": slow[3][1], "time_budget_ms": 1})
serve_pair("control, no glob", ascii_i, {"pattern": "tide", "time_budget_ms": 1})

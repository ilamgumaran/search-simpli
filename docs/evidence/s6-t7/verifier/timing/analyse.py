#!/usr/bin/env python3
"""S6-T7 verifier: the five-run timing rule of 2026-11-17 (docs/process/ROLES.md) over every cell.

    analyse.py TIMDIR > analysis.json   (reads q-run1..5, r-run1..5, o-run1..5, u-run1..5)

Per cell and run r: d_r = head - main, and for each control c in (main2, ctl1, ctl2) c_r - main.
T = max(0.010 ms, 1 % of main's five-run median). A cell FAILS only if median_r(d_r) >= T and
median_r(d_r) - max(median_r(main2 - main), median_r(ctl1 - main), median_r(ctl2 - main)) >= T.
Band excursions (reported, never failing): runs where head > max(main, main2, ctl1, ctl2).
Memory cells (bytes) are reported with the same arithmetic, without T.
Open (interleaved, phase o): the same rule, plus head-v4 (the head's library on main's index).
"""
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path

D = Path(sys.argv[1])
CTL = ("main2", "ctl1", "ctl2")
med = statistics.median


def corpus_of(index):
    return index.rstrip("/").split("/")[-1]


cells = defaultdict(lambda: defaultdict(dict))  # (phase, corpus, cell) -> run -> variant -> value
hashes = defaultdict(set)
for r in range(1, 6):
    for line in open(D / f"q-run{r}.jsonl"):
        x = json.loads(line)
        c, v = corpus_of(x["index"]), x["variant"]
        for w in x["warm"]:
            cells[("q", c, f"{w['field']} {w['query']}")][r][v] = w["p50_ms"]
            hashes[("q", c, f"{w['field']} {w['query']}", v)].add(w["answer_sha256"])
        for f in x["find"]:
            cells[("q", c, f"find {f['mode']} {f['query']}")][r][v] = f["p50_ms"]
            hashes[("q", c, f"find {f['mode']} {f['query']}", v)].add(f["answer_sha256"])
        cells[("q", c, "open (bench.py, p50 of 30)")][r][v] = x["open"]["p50_ms"]
        cells[("q", c, "first query")][r][v] = x["first_query"]["p50_ms"]
        cells[("q", c, "first find")][r][v] = x["first_find"]["p50_ms"]
        cells[("qmem", c, "memory after open (bench.py)")][r][v] = x["memory"]["open_delta"]
    for line in open(D / f"r-run{r}.jsonl"):
        x = json.loads(line)
        c, v = x["corpus"], x["variant"]
        cells[("r", c, "open (rbench, p50 of 60)")][r][v] = x["open"]["p50_ms"]
        cells[("rcpu", c, "open CPU (rbench, p50 of 60)")][r][v] = x["open"]["cpu_p50_ms"]
        cells[("rmem", c, "memory after open (rbench)")][r][v] = x["memory_after_open"]
        cells[("r", c, "first read_span (median file)")][r][v] = x["first_read_span"]["p50_ms"]
        cells[("r", c, "first outline (median file)")][r][v] = x["first_outline"]["p50_ms"]
        for l in x["later"]:
            cells[("r", c, l["cell"])][r][v] = l["p50_ms"]
            cells[("rcpu", c, l["cell"] + " CPU/call")][r][v] = l["cpu_per_call_ms"]
            hashes[("r", c, l["cell"], v)].add(l["answer_sha256"])
    for line in open(D / f"o-run{r}.jsonl"):
        x = json.loads(line)
        for v, val in x["p50_ms"].items():
            cells[("o", x["corpus"], "open interleaved (p50 of 200)")][r][v] = val
        for v, val in x["cpu_p50_ms"].items():
            cells[("ocpu", x["corpus"], "open interleaved CPU (p50 of 200)")][r][v] = val
    if (D / f"o2-run{r}.jsonl").exists():
        for line in open(D / f"o2-run{r}.jsonl"):
            x = json.loads(line)
            for v, val in x["p50_ms"].items():
                cells[("o2", x["corpus"], "open interleaved, own copies (p50 of 200)")][r][v] = val
            for v, val in x["cpu_p50_ms"].items():
                cells[("o2cpu", x["corpus"], "open interleaved, own copies, CPU (p50 of 200)")][r][v] = val
    for line in open(D / f"u-run{r}.jsonl"):
        x = json.loads(line)
        for step in ("first", "update"):
            cells[("u", x["corpus"], f"{step} (median of 3)")][r][x["variant"]] = med(t[step]["ms"] for t in x["trials"])

out = []
for key, runs in sorted(cells.items()):
    phase, corpus, cell = key
    rs = sorted(runs)
    if len(rs) != 5 or any(not all(v in runs[r] for v in ("main", "head") + CTL) for r in rs):
        out.append({"phase": phase, "corpus": corpus, "cell": cell, "incomplete": True})
        continue
    mains = [runs[r]["main"] for r in rs]
    m = med(mains)
    d = [runs[r]["head"] - runs[r]["main"] for r in rs]
    ctl = {c: med(runs[r][c] - runs[r]["main"] for r in rs) for c in CTL}
    md = med(d)
    row = {"phase": phase, "corpus": corpus, "cell": cell, "main_median": m, "median_d": md,
           "pct": 100 * md / m if m else None, "ctl": ctl, "d_runs": d,
           "band_excursions": sum(runs[r]["head"] > max(runs[r][v] for v in ("main",) + CTL) for r in rs)}
    if "head-v4" in runs[rs[0]]:
        row["head_v4_median_d"] = med(runs[r]["head-v4"] - runs[r]["main"] for r in rs)
    if phase in ("qmem", "rmem"):
        row["fails"] = None
    else:
        T = max(0.010, 0.01 * m)
        row["T"] = T
        row["beyond_controls"] = md - max(ctl.values())
        row["fails"] = md >= T and md - max(ctl.values()) >= T
        row["at_T"] = md >= T
    out.append(row)
answers = []
for (phase, c, cell, v), hs in hashes.items():
    if v != "main":
        mh = hashes.get((phase, c, cell, "main"), set())
        if hs != mh:
            answers.append(f"{phase} {c} {cell} {v}: answer differs from main")
    if len(hs) != 1:
        answers.append(f"{phase} {c} {cell} {v}: answer differs between runs")
print(json.dumps({"cells": out, "answer_problems": answers}, indent=1))

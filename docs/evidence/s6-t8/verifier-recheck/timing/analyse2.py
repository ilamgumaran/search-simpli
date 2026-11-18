#!/usr/bin/env python3
"""S6-T8 verifier (recheck): the five-run timing rule of 2026-11-17 over every cell of runs 11-15, under two control sets
fixed in orders.txt before the first run:
  RULE SET     main2, ctl1, ctl2, pA, pB, pD, pC   (decides the cell)
  ORIGINAL SET main2, ctl1, ctl2                    (reported beside it; decides nothing)
T = max(0.010 ms, 1 % of main's five-run median). A cell FAILS if median_r(head2 - main) >= T and exceeds by >= T the
largest median_r(control - main) of the set. Write expectations (ruling 4): first publish and one-file update not slower
than main by more than 2 % (median of the five run medians of each run's median of 3 trials).
    analyse2.py TIM2DIR > analysis2.json
"""
import json, statistics, sys
from collections import defaultdict
from pathlib import Path

D = Path(sys.argv[1])
RUNS = range(11, 16)
RULE = ("main2", "ctl1", "ctl2", "pA", "pB", "pD", "pC")
ORIG = ("main2", "ctl1", "ctl2")
H = "head2"
med = statistics.median
cells = defaultdict(lambda: defaultdict(dict))
hashes = defaultdict(set)
for r in RUNS:
    for line in open(D / f"q-run{r}.jsonl"):
        x = json.loads(line)
        c, v = x["index"].rstrip("/").split("/")[-1], x["variant"]
        for w in x["warm"]:
            k = ("q", c, f"{w['field']} {w['query']}")
            cells[k][r][v] = w["p50_ms"]; hashes[k + (v,)].add(w["answer_sha256"])
        for f in x["find"]:
            k = ("q", c, f"find {f['mode']} {f['query']}")
            cells[k][r][v] = f["p50_ms"]; hashes[k + (v,)].add(f["answer_sha256"])
        cells[("q", c, "open (p50 of 30)")][r][v] = x["open"]["p50_ms"]
        cells[("q", c, "first query")][r][v] = x["first_query"]["p50_ms"]
        cells[("q", c, "first find")][r][v] = x["first_find"]["p50_ms"]
        cells[("qmem", c, "memory after open")][r][v] = x["memory"]["open_delta"]
    for line in open(D / f"u-run{r}.jsonl"):
        x = json.loads(line)
        for step in ("first", "update"):
            cells[("u", x["corpus"], f"{step} (median of 3)")][r][x["variant"]] = med(t[step]["ms"] for t in x["trials"])


def judge(runs, ctlset, m, md):
    ctl = {c: med(runs[r][c] - runs[r]["main"] for r in RUNS) for c in ctlset}
    T = max(0.010, 0.01 * m)
    worst = max(ctl, key=ctl.get)
    return {"ctl": ctl, "largest": worst, "beyond": md - ctl[worst], "fails": md >= T and md - ctl[worst] >= T}


out = []
for key, runs in sorted(cells.items()):
    phase, corpus, cell = key
    if sorted(runs) != list(RUNS) or any(not all(v in runs[r] for v in ("main", H) + RULE) for r in RUNS):
        out.append({"phase": phase, "corpus": corpus, "cell": cell, "incomplete": True}); continue
    m = med(runs[r]["main"] for r in RUNS)
    d = [runs[r][H] - runs[r]["main"] for r in RUNS]
    md = med(d)
    row = {"phase": phase, "corpus": corpus, "cell": cell, "main_median": m, "median_d": md, "pct": 100 * md / m if m else None,
           "d_runs": d, "T": max(0.010, 0.01 * m), "at_T": md >= max(0.010, 0.01 * m)}
    row["band_excursions"] = sum(runs[r][H] > max(runs[r][v] for v in ("main",) + RULE) for r in RUNS)
    if phase != "qmem":
        row["rule_set"] = judge(runs, RULE, m, md)
        row["original_set"] = judge(runs, ORIG, m, md)
    if phase == "u":
        row["write_expectation_met"] = md <= 0.02 * m
    out.append(row)
answers = []
for k, hs in hashes.items():
    v = k[-1]
    if v != "main" and hs != hashes.get(k[:-1] + ("main",), set()):
        answers.append(" ".join(map(str, k)) + ": answer differs from main")
    if len(hs) != 1:
        answers.append(" ".join(map(str, k)) + ": answer differs between runs")
print(json.dumps({"cells": out, "answer_problems": answers}, indent=1))

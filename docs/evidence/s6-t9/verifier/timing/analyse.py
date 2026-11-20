#!/usr/bin/env python3
"""S6-T9 verifier: the five-run timing rule of 2026-11-17 over every cell of runs 1-5 (orders.txt fixed the sets):
  RULE SET     main2, cq, co, cf, cm, cs   (decides the cell)
  PLACED ALONE co, cf, cm, cs              (reported)
  MAIN2 ALONE  main2                       (reported)
T = max(0.010 ms, 1 % of main's five-run median). A cell FAILS if median_r(head - main) >= T and exceeds by >= T the
largest median_r(control - main) of the set. Band: head above every other build in >= 3 of 5 runs (tabulated only).
Memory after open: bytes, head against main per run. Updates (ruling 4): per build, the median over the runs of each
run's median of 3 trials; head against main in %.
    analyse.py TIMDIR RUNS(e.g. 1,2,3,4,5) > analysis.txt   (also writes TIMDIR/analysis.json)
"""
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path

D = Path(sys.argv[1])
RUNS = [x for x in sys.argv[2].split(",")]
SETS = {"rule": ("main2", "cq", "co", "cf", "cm", "cs"), "placed": ("co", "cf", "cm", "cs"), "main2": ("main2",)}
ALL = ("main", "main2", "head", "cq", "co", "cf", "cm", "cs")
med = statistics.median
cells = defaultdict(lambda: defaultdict(dict))
hashes = defaultdict(set)
mem = defaultdict(lambda: defaultdict(dict))
for r in RUNS:
    for line in open(D / f"q-run{r}.jsonl"):
        x = json.loads(line)
        c, v = x["index"].rstrip("/").split("/")[-1], x["variant"]
        for w in x["warm"]:
            k = (c, f"{w['field']} {w['query']}")
            cells[k][r][v] = w["p50_ms"]
            hashes[(c, k[1], "q")].add(w["answer_sha256"])
        for f in x["find"]:
            k = (c, f"find {f['mode']} {f['query']}")
            cells[k][r][v] = f["p50_ms"]
            hashes[(c, k[1], "f")].add(f["answer_sha256"])
        for key in ("open", "first_query", "first_find", "first_filename", "first_both"):
            if key in x:
                cells[(c, f"[{key}]")][r][v] = x[key]["p50_ms"]
        mem[c][r][v] = x["memory"]["open_delta"]


def judge(runs, ctl):
    m = med(runs[r]["main"] for r in RUNS)
    T = max(0.010, 0.01 * m)
    dh = med(runs[r]["head"] - runs[r]["main"] for r in RUNS)
    dc = {v: med(runs[r][v] - runs[r]["main"] for r in RUNS) for v in ctl}
    top = max(dc.values())
    fail = dh >= T and dh - top >= T
    return m, T, dh, dc, top, fail


out = {"cells": {}, "fails": {s: [] for s in SETS}, "at_T_within": [], "band": []}
complete = 0
for k, runs in sorted(cells.items()):
    if any(set(ALL) - set(runs[r]) for r in RUNS):
        continue
    complete += 1
    res = {}
    for s, ctl in SETS.items():
        m, T, dh, dc, top, fail = judge(runs, ctl)
        res[s] = {"top": top, "fail": fail}
        if fail:
            out["fails"][s].append(k)
    m, T, dh, dc, top, fail = judge(runs, SETS["rule"])
    band = sum(1 for r in RUNS if all(runs[r]["head"] > runs[r][v] for v in ALL if v != "head"))
    out["cells"]["\t".join(k)] = {"main_ms": m, "T": T, "head_minus_main": dh, "controls": dc, "band": band,
                                  "sets": res, "per_run": {r: runs[r] for r in RUNS}}
    if dh >= T and not fail:
        out["at_T_within"].append(k)
    if band >= 3:
        out["band"].append(k)

us = lambda x: f"{x * 1000:+.1f}"
print(f"runs {RUNS}; complete cells {complete}")
for s in SETS:
    print(f"\nFAILS under {s} set ({', '.join(SETS[s])}): {len(out['fails'][s])}")
    for k in out["fails"][s]:
        e = out["cells"]["\t".join(k)]
        print(f"  {k[0]:11s} {k[1][:44]:44s} head-main {us(e['head_minus_main'])} us ({e['head_minus_main'] / e['main_ms'] * 100:+.1f} %)"
              f" T {e['T'] * 1000:.1f}  top ctl {us(e['sets'][s]['top'])}  ctl " +
              " ".join(f"{v}{us(e['controls'][v])}" for v in SETS["rule"]))
print(f"\nAt or above T but within the rule set's controls: {len(out['at_T_within'])}")
for k in out["at_T_within"]:
    e = out["cells"]["\t".join(k)]
    print(f"  {k[0]:11s} {k[1][:44]:44s} head-main {us(e['head_minus_main'])} T {e['T'] * 1000:.1f} top {us(e['sets']['rule']['top'])}")
print(f"\nBand excursions (head above every other build in >= 3 of {len(RUNS)} runs): {len(out['band'])}")
for c in sorted({k[0] for k in out["band"]}):
    print(f"  {c}: {sum(1 for k in out['band'] if k[0] == c)}")
print("\nThe special cells (open, first query/find/filename/both), head - main and the rule set's top control (us):")
for k in sorted(out["cells"]):
    if "[" in k:
        e = out["cells"][k]
        c, name = k.split("\t")
        print(f"  {c:11s} {name:17s} main {e['main_ms'] * 1000:9.1f} head-main {us(e['head_minus_main']):>8s} "
              f"({e['head_minus_main'] / e['main_ms'] * 100:+.1f} %) T {e['T'] * 1000:6.1f} top {us(e['sets']['rule']['top']):>8s} "
              f"placed-top {us(e['sets']['placed']['top']):>8s} main2 {us(e['controls']['main2']):>8s} "
              f"rule:{'FAIL' if e['sets']['rule']['fail'] else 'pass'} placed:{'FAIL' if e['sets']['placed']['fail'] else 'pass'} "
              f"main2:{'FAIL' if e['sets']['main2']['fail'] else 'pass'} band {e['band']}")
bad = [k for k, v in hashes.items() if len(v) != 1]
print(f"\nAnswer hashes: {len(hashes)} cells, {len(bad)} with more than one answer over every build and run")
print("\nMemory after open (open_delta, bytes), head - main per run, and main2 - main:")
for c in sorted(mem):
    print(f"  {c:11s} head-main " + " ".join(f"{mem[c][r]['head'] - mem[c][r]['main']:+d}" for r in RUNS) +
          "   main2-main " + " ".join(f"{mem[c][r]['main2'] - mem[c][r]['main']:+d}" for r in RUNS) +
          f"   main {mem[c][RUNS[0]]['main']}")

# updates
up = defaultdict(lambda: defaultdict(dict))
for r in RUNS:
    p = D / f"u-run{r}.jsonl"
    if not p.exists():
        continue
    for line in open(p):
        x = json.loads(line)
        for step in ("first", "update", "unchanged"):
            for metric in ("ms", "plan_ms", "open_plan_ms"):
                up[(x["corpus"], step, metric)][r][x["variant"]] = med(t[step][metric] for t in x["trials"])
        up[(x["corpus"], "flags", "")][r][x["variant"]] = sorted({t["flags_after"] for t in x["trials"]})
print("\nUpdates (median over runs of each run's median of 3 trials; ms), head and main2 against main:")
for k in sorted(up):
    if k[1] == "flags":
        continue
    runs = up[k]
    rs = [r for r in RUNS if r in runs and "head" in runs[r] and "main" in runs[r]]
    if not rs:
        continue
    m = med(runs[r]["main"] for r in rs)
    vals = {v: med(runs[r][v] for r in rs if v in runs[r]) for v in ("main", "head", "main2", "cs", "cm")}
    print(f"  {k[0]:10s} {k[1]:9s} {k[2]:12s} main {m:9.3f} head {vals['head']:9.3f} ({(vals['head'] - m) / m * 100:+.1f} %) "
          f"main2 {(vals['main2'] - m) / m * 100:+.1f} % cs {(vals['cs'] - m) / m * 100:+.1f} % cm {(vals['cm'] - m) / m * 100:+.1f} %  runs {len(rs)}")
    out.setdefault("updates", {})["\t".join(k)] = {"vals": vals, "per_run": {r: runs[r] for r in rs}}
for k in sorted(up):
    if k[1] == "flags":
        print(f"  flags after, {k[0]}: " + "; ".join(f"{v} {up[k][RUNS[0]].get(v)}" for v in ("main", "head")))
(D / "analysis.json").write_text(json.dumps(out, indent=0, default=list))

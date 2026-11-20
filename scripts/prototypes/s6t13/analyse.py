#!/usr/bin/env python3
"""S6-T13: the open-time cells by the rule of 2026-11-17 (orders.txt).  python3 -I analyse.py OPEN.jsonl
Per corpus and metric (open_p50 decides; cpu_p50 reported): main's five-run median M; T = max(0.010, 1 % of M);
d(b) = median over runs of (b - main) for each build b; the cell fails if d(head) >= T and d(head) - max over the
control set {main2, cl, cm} of d(control) >= T. Band: runs where head is above every other build."""
import json
import statistics
import sys

rows = [json.loads(l) for l in open(sys.argv[1])]
builds = ["main", "main2", "head", "cl", "cm"]
controls = ["main2", "cl", "cm"]
for metric in ("open_p50", "cpu_p50"):
    print(f"## {metric} (ms)")
    print("| corpus | main median | head - main | main2 / cl / cm - main | T | rule | band (head above all) |")
    print("| --- | ---: | ---: | --- | ---: | --- | ---: |")
    for corpus in ("timing-10k", "prose-10k", "tamil-10k"):
        v = {(r["build"], r["run"]): r[metric] for r in rows if r["corpus"] == corpus}
        runs = sorted({run for (_, run) in v})
        assert len(runs) == 5 and all((b, run) in v for b in builds for run in runs), corpus
        m = statistics.median(v[("main", run)] for run in runs)
        t = max(0.010, 0.01 * m)
        d = {b: statistics.median(v[(b, run)] - v[("main", run)] for run in runs) for b in builds}
        worst = max(d[c] for c in controls)
        fail = d["head"] >= t and d["head"] - worst >= t
        band = sum(1 for run in runs if all(v[("head", run)] > v[(b, run)] for b in builds if b != "head"))
        print(f"| {corpus} | {m:.4f} | {d['head']:+.4f} ({100 * d['head'] / m:+.2f} %) | "
              f"{d['main2']:+.4f} / {d['cl']:+.4f} / {d['cm']:+.4f} | {t:.4f} | {'FAIL' if fail else 'pass'} | {band}/5 |")
    print()
print("## per run, open_p50 (ms)")
for corpus in ("timing-10k", "prose-10k", "tamil-10k"):
    for run in sorted({r["run"] for r in rows}):
        vals = {r["build"]: r["open_p50"] for r in rows if r["corpus"] == corpus and r["run"] == run}
        print(f"{corpus} run{run}: " + "  ".join(f"{b} {vals[b]:.4f}" for b in builds))

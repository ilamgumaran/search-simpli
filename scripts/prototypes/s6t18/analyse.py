#!/usr/bin/env python3
"""S6-T18 ruling 4: the timed runs of run_timing.sh by the rule of 2026-11-17, as orders.txt fixes it.

    python3 -I analyse.py ROWS.jsonl ...

Cells: (corpus, query). For a cell, per run r each build's p50 wall time (qbench.py); m = median_r(main),
T = max(0.010 ms, 1 % of m), d(v) = median_r(v_r - main_r) (paired by run). The cell fails when d(head) >= T and
d(head) - max(d(main2), d(cr), d(cd)) >= T. A band excursion is head above every other build in a run (tabulated:
3 or more of 5 runs is reported, never failing). The same is printed for the CPU time p50, for information, and
the peak resident size (largest ru_maxrss) per build and corpus. `answers`: distinct answer digests over every
row of the cell (1: every build and run answered the same). Not part of any build.
"""
from __future__ import annotations

import json
import statistics
import sys
from collections import defaultdict

BASE, HEAD, CONTROLS = "main", "head", ("main2", "cr", "cd")
BUILDS = (BASE, "main2", HEAD, "cr", "cd")


def judge(values, label):
    """values: cell -> build -> run -> ms. Prints the table; returns the failing cells."""
    print(f"\n### {label}\n")
    print("| Corpus | Query | main (ms) | head - main | main2 / cr / cd - main | T | head - largest control | Rule | Band |")
    print("|---|---|---:|---:|---|---:|---:|---|---:|")
    failed = []
    for cell in sorted(values):
        v = values[cell]
        runs = sorted(set.intersection(*(set(v[b]) for b in BUILDS)))
        m = statistics.median(v[BASE][r] for r in runs)
        t = max(0.010, 0.01 * m)
        d = {b: statistics.median(v[b][r] - v[BASE][r] for r in runs) for b in BUILDS if b != BASE}
        over = d[HEAD] - max(d[c] for c in CONTROLS)
        fails = d[HEAD] >= t and over >= t
        band = sum(1 for r in runs if all(v[HEAD][r] > v[b][r] for b in BUILDS if b != HEAD))
        if fails:
            failed.append(cell)
        print(f"| {cell[0]} | {cell[1]} | {m:.4f} | {d[HEAD]:+.4f} ({100 * d[HEAD] / m:+.2f} %) | "
              f"{d['main2']:+.4f} / {d['cr']:+.4f} / {d['cd']:+.4f} | {t:.4f} | {over:+.4f} | "
              f"{'FAIL' if fails else 'pass'} | {band}/{len(runs)} |")
    return failed


def main(argv):
    wall, cpu = defaultdict(lambda: defaultdict(dict)), defaultdict(lambda: defaultdict(dict))
    answers, peaks, loads, runs_seen, stamps = defaultdict(set), defaultdict(list), [], set(), []
    for path in argv[1:]:
        for line in open(path, encoding="utf-8"):
            r = json.loads(line)
            cell = (r["corpus"], r["query"])
            wall[cell][r["build"]][r["run"]] = r["p50_ms"]
            cpu[cell][r["build"]][r["run"]] = r["cpu_p50_ms"]
            answers[cell].update(r["answers"])
            peaks[(r["corpus"], r["build"])].append(r["maxrss_max"])
            loads.append(r["load_before"][1])
            runs_seen.add(r["run"])
            stamps.append(r["at"])
            if r["exit"] != [0]:
                print(f"exit {r['exit']} in {cell} {r['build']} run {r['run']}")
    print(f"runs {sorted(runs_seen)}; rows written {min(stamps)} to {max(stamps)}; 5-minute load before each "
          f"process {min(loads):.2f}-{max(loads):.2f}")
    print(f"cells {len(wall)}; every cell one answer: {all(len(a) == 1 for a in answers.values())}")
    failed = judge(wall, "Wall time p50 of a `searchd query` process (judged)")
    cfailed = judge(cpu, "CPU time p50 (user + system) of the same processes (information)")
    print("\n### Peak resident size (largest ru_maxrss over every process of the corpus), bytes\n")
    print("| Corpus | " + " | ".join(BUILDS) + " | head - main |")
    print("|---|" + "---:|" * (len(BUILDS) + 1))
    for corpus in sorted({c for c, _ in peaks}):
        row = {b: max(peaks[(corpus, b)]) for b in BUILDS}
        print(f"| {corpus} | " + " | ".join(f"{row[b]:,}" for b in BUILDS) + f" | {row[HEAD] - row[BASE]:+,} |")
    print(f"\nwall: {len(failed)} of {len(wall)} cells fail {failed}")
    print(f"cpu (information): {len(cfailed)} of {len(cpu)} cells would fail {cfailed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

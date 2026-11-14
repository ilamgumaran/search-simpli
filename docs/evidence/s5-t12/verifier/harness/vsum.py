#!/usr/bin/env python3
"""Verifier summary of one S5-T12 run, with the rule of "Rulings on Phase 2"
item 2 applied to it:
    python3 -I vsum.py RUN.jsonl
Per (workload, query): main's median of its per-round p50s; for main2
(noise), part1 and head the median [range] over rounds of the per-round
difference against main. The run's noise band: the largest and smallest
noise median over every cell, and the per-round extremes over every cell.
A cell is flagged ABOVE when head - main exceeds the largest noise median.
"""
import json, statistics, sys
from collections import defaultdict

rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
if any("refused" in r for r in rows):
    raise SystemExit("incomplete run (a gate refusal): not summarized")
p50 = defaultdict(dict)
answers = defaultdict(set)
for r in rows:
    p50[(r["variant"], r["field"], r["query"])][r["round"]] = r["p50_ms"]
    answers[(r["field"], r["query"])].add(r["answer_sha256"])
fields = list(dict.fromkeys(r["field"] for r in rows))
queries = list(dict.fromkeys(r["query"] for r in rows))
rounds = sorted({r["round"] for r in rows})
assert len(rounds) == 8 and all(len(v) == 8 for v in p50.values()), "not 8 complete rounds"


def diffs(x, f, q):
    return [p50[(x, f, q)][k] - p50[("main", f, q)][k] for k in rounds]


noise_medians = {}
noise_all = []
for f in fields:
    for q in queries:
        d = diffs("main2", f, q)
        noise_medians[(f, q)] = statistics.median(d)
        noise_all += d
top = max(noise_medians.values())
bottom = min(noise_medians.values())
print(f"rounds {len(rounds)}; answers identical across libraries and rounds: {all(len(s) == 1 for s in answers.values())}")
print(f"noise medians over {len(noise_medians)} cells: {bottom:+.4f} .. {top:+.4f}; per-round noise extremes {min(noise_all):+.4f} .. {max(noise_all):+.4f}")
print()
print("| workload | query | main | main2 - main | part1 - main | head - main | head - main > top noise median |")
print("|---|---|---:|---:|---:|---:|---|")
above = []
for f in fields:
    for q in queries:
        cells = [f"{statistics.median(p50[('main', f, q)].values()):.4f}"]
        for x in ("main2", "part1", "head"):
            d = diffs(x, f, q)
            cells.append(f"{statistics.median(d):+.4f} [{min(d):+.4f}, {max(d):+.4f}]")
        h = statistics.median(diffs("head", f, q))
        flag = "ABOVE" if h > top else ""
        if flag:
            above.append((f, q, h))
        print(f"| {f} | `{q}` | " + " | ".join(cells) + f" | {flag} |")
print()
print("cells above the top noise median:", json.dumps(above))
lo = min(noise_all)
for f in ("both", "both-all"):
    worst = max(max(diffs("head", f, q)) for q in queries)
    med = [statistics.median(diffs("head", f, q)) for q in queries]
    print(f"{f}: head - main medians {min(med):+.4f} .. {max(med):+.4f}; least saving in any round {worst:+.4f}; "
          f"beyond the per-round noise band (below {lo:+.4f}) in every round of every query: {worst < lo}")

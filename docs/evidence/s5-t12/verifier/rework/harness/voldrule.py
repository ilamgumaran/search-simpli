#!/usr/bin/env python3
"""Cross-check only (not the rule): the old rule of "Rulings on Phase 2" item 2
applied to the re-measurement, i.e. head2 - main against the run's largest
main2 - main median over every cell, in both runs.
    python3 -I voldrule.py RUN_A.jsonl RUN_B.jsonl
"""
import json, statistics, sys
from collections import defaultdict


def load(path):
    p50 = defaultdict(dict)
    for line in open(path, encoding="utf-8"):
        r = json.loads(line)
        p50[(r["variant"], r["field"], r["query"])][r["round"]] = r["p50_ms"]
    return p50


def med(p50, x, f, q):
    rounds = sorted(p50[("main", f, q)])
    return statistics.median(p50[(x, f, q)][k] - p50[("main", f, q)][k] for k in rounds)


above = []
for path in sys.argv[1:3]:
    p50 = load(path)
    cells = sorted({(f, q) for (_, f, q) in p50})
    top = max(med(p50, "main2", f, q) for f, q in cells)
    flagged = {(f, q): round(med(p50, "head2", f, q), 4) for f, q in cells if med(p50, "head2", f, q) > top}
    print(f"{path.split('/')[-1]}: largest main2 - main median {top:+.4f}; head2 cells above it: {json.dumps([[f, q, v] for (f, q), v in flagged.items()])}")
    above.append(set(flagged))
print("above in both runs:", sorted(above[0] & above[1]))

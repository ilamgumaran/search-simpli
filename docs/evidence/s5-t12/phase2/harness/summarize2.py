#!/usr/bin/env python3
"""Summarize an S5-T12 Phase 2 run: python3 -I summarize2.py RUN.jsonl

Per (workload, query): `main`'s median of its per-round p50s (ms), then
the median and range over the rounds of the per-round differences
main2 - main (the noise), part1 - main (the check alone), part2 - part1
(the lazy view alone) and part2 - main (both parts); and the check that
every library answered every case byte for byte as `main` did.
"""

from __future__ import annotations

import json
import statistics
import sys
from collections import defaultdict

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
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
pairs = [("main2", "main"), ("part1", "main"), ("part2", "part1"), ("part2", "main")]
print(f"rounds: {len(rounds)}; answers identical across libraries and rounds: {all(len(s) == 1 for s in answers.values())}")
print()
print("| workload | query | main | " + " | ".join(f"{x} - {y} [range]" for x, y in pairs) + " |")
print("|---|---|---:|" + "---:|" * len(pairs))
for field in fields:
    for q in queries:
        cells = [f"{statistics.median(p50[('main', field, q)].values()):.4f}"]
        for x, y in pairs:
            d = [p50[(x, field, q)][k] - p50[(y, field, q)][k] for k in rounds]
            cells.append(f"{statistics.median(d):+.4f} [{min(d):+.4f}, {max(d):+.4f}]")
        print(f"| {field} | `{q}` | " + " | ".join(cells) + " |")
print()
print("medians per library (ms)")
for field in fields:
    for q in queries:
        print(field, repr(q), " ".join(f"{v}={statistics.median(p50[(v, field, q)].values()):.4f}" for v in ("main", "main2", "part1", "part2")))

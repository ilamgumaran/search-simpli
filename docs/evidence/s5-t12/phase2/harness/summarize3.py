#!/usr/bin/env python3
"""Summarize an S5-T12 run with any variants:
    python3 -I summarize3.py RUN.jsonl BASE X1 X2 ...
Per (workload, query): BASE's median of its per-round p50s (ms), then for
each Xi the median and range over the rounds of the per-round differences
Xi - BASE; and whether every library answered every case as BASE did."""
from __future__ import annotations
import json, statistics, sys
from collections import defaultdict
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
if any("refused" in r for r in rows):
    raise SystemExit("incomplete run (a gate refusal): not summarized")
base, others = sys.argv[2], sys.argv[3:]
p50 = defaultdict(dict)
answers = defaultdict(set)
for r in rows:
    p50[(r["variant"], r["field"], r["query"])][r["round"]] = r["p50_ms"]
    answers[(r["field"], r["query"])].add(r["answer_sha256"])
fields = list(dict.fromkeys(r["field"] for r in rows))
queries = list(dict.fromkeys(r["query"] for r in rows))
rounds = sorted({r["round"] for r in rows})
print(f"rounds: {len(rounds)}; answers identical across libraries and rounds: {all(len(s) == 1 for s in answers.values())}")
print()
print(f"| workload | query | {base} | " + " | ".join(f"{x} - {base} [range]" for x in others) + " |")
print("|---|---|---:|" + "---:|" * len(others))
for field in fields:
    for q in queries:
        cells = [f"{statistics.median(p50[(base, field, q)].values()):.4f}"]
        for x in others:
            d = [p50[(x, field, q)][k] - p50[(base, field, q)][k] for k in rounds]
            cells.append(f"{statistics.median(d):+.4f} [{min(d):+.4f}, {max(d):+.4f}]")
        print(f"| {field} | `{q}` | " + " | ".join(cells) + " |")

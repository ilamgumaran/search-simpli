#!/usr/bin/env python3
"""Summarize an S5-T12 Phase 1 run: python3 -I summarize.py RUN.jsonl

Per query and field: each variant's median over the rounds of its per-round
p50 (ms), and for proto, noview and main2 the median and range over the
rounds of (variant - main) per round; then each variant's both - content
per query (median over rounds). Also checks that every variant answered
every query byte for byte as main did.
"""

from __future__ import annotations

import json
import statistics
import sys
from collections import defaultdict

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
if any("refused" in r for r in rows):
    raise SystemExit("incomplete run (a gate refusal): not summarized")
p50 = defaultdict(dict)  # (variant, field, query) -> round -> p50
answers = defaultdict(set)
for r in rows:
    p50[(r["variant"], r["field"], r["query"])][r["round"]] = r["p50_ms"]
    answers[(r["field"], r["query"])].add(r["answer_sha256"])
variants = ["main", "main2", "proto", "noview"]
queries = list(dict.fromkeys(r["query"] for r in rows))
fields = ["content", "both"]
rounds = sorted({r["round"] for r in rows})
print(f"rounds: {len(rounds)}; answers identical across variants and rounds: {all(len(s) == 1 for s in answers.values())}")
print()
print(f"| field | query | main | main2-main [range] | proto-main [range] | noview-main [range] |")
print("|---|---|---:|---:|---:|---:|")
for field in fields:
    for q in queries:
        base = p50[("main", field, q)]
        cells = [f"{statistics.median(base.values()):.4f}"]
        for v in ("main2", "proto", "noview"):
            d = [p50[(v, field, q)][k] - base[k] for k in rounds]
            cells.append(f"{statistics.median(d):+.4f} [{min(d):+.4f}, {max(d):+.4f}]")
        print(f"| {field} | `{q}` | " + " | ".join(cells) + " |")
print()
print("both - content per round, median [range], ms")
print("| query | " + " | ".join(variants) + " |")
print("|---|" + "---:|" * len(variants))
for q in queries:
    cells = []
    for v in variants:
        d = [p50[(v, "both", q)][k] - p50[(v, "content", q)][k] for k in rounds]
        cells.append(f"{statistics.median(d):+.4f} [{min(d):+.4f}, {max(d):+.4f}]")
    print(f"| `{q}` | " + " | ".join(cells) + " |")
print()
print("medians per variant (ms)")
for field in fields:
    for q in queries:
        print(field, repr(q), " ".join(f"{v}={statistics.median(p50[(v, field, q)].values()):.4f}" for v in variants))

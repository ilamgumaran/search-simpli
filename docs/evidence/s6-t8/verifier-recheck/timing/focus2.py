#!/usr/bin/env python3
"""S6-T8 verifier (recheck): per-run p50 (µs) of the prose-10k warm `both` cells for all nine libraries, runs 11-15.
    focus2.py TIM2DIR"""
import json, sys
from pathlib import Path
D = Path(sys.argv[1])
LIBS = ["main", "main2", "ctl1", "ctl2", "pA", "pB", "pD", "pC", "head2"]
cells = {}
for r in range(11, 16):
    for line in open(D / f"q-run{r}.jsonl"):
        x = json.loads(line)
        if not x["index"].rstrip("/").endswith("/prose-10k"):
            continue
        for w in x["warm"]:
            if w["field"] == "both":
                cells.setdefault(w["query"], {}).setdefault(r, {})[x["variant"]] = w["p50_ms"] * 1000
print("Per-run p50 (µs), prose-10k warm both; each run's library order is in orders.txt")
for q, runs in cells.items():
    print(f"\nprose-10k both {q}")
    print("run " + "".join(f"{v:>9}" for v in LIBS) + "  head2-main")
    for r in sorted(runs):
        row = runs[r]
        print(f"{r:>3} " + "".join(f"{row.get(v, float('nan')):9.1f}" for v in LIBS) + f"  {row['head2'] - row['main']:+9.1f}")

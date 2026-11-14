#!/usr/bin/env python3
"""Verifier summary of the first `content` query after an open (S5-T8 bound:
head - main <= +0.10 ms), five libraries:
    python3 -I vfsum5.py RUN.jsonl
Per (snapshot, query) the median [range] over rounds of the per-round
difference against main.
"""
import json, statistics, sys
from collections import defaultdict

rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
if any("refused" in r for r in rows):
    raise SystemExit("incomplete run (a gate refusal): not summarized")
p50 = defaultdict(dict)
for r in rows:
    p50[(r["variant"], r["field"], r["query"])][r["round"]] = r["p50_ms"]
fields = list(dict.fromkeys(r["field"] for r in rows))
queries = list(dict.fromkeys(r["query"] for r in rows))
rounds = sorted({r["round"] for r in rows})
assert all(len(v) == len(rounds) for v in p50.values()), "incomplete rounds"
OTHERS = ("main2", "ctl1", "ctl2", "head2")
print(f"First content query after an open (15 fresh handles, median), {len(rounds)} rounds, ms; differences: median [range] over rounds")
print("| snapshot | query | main | " + " | ".join(f"{x} - main" for x in OTHERS) + " |")
print("|---|---|---:|" + "---:|" * len(OTHERS))
worst = None
for f in fields:
    for q in queries:
        cells = [f"{statistics.median(p50[('main', f, q)].values()):.4f}"]
        for x in OTHERS:
            d = [p50[(x, f, q)][k] - p50[("main", f, q)][k] for k in rounds]
            cells.append(f"{statistics.median(d):+.4f} [{min(d):+.4f}, {max(d):+.4f}]")
            if x == "head2":
                m = statistics.median(d)
                worst = m if worst is None else max(worst, m)
        print(f"| {f.replace('first-content-', '')} | `{q}` | " + " | ".join(cells) + " |")
print(f"\nlargest head - main median: {worst:+.4f} ms; bound +0.10 ms: {'met' if worst <= 0.10 else 'MISSED'}")

"""S6-T8 F2: per variant and cell, the median change against main (us) and the per-run spread of (variant - main) in
the same run (min..max), from bench.py rows.  f2table.py ROWS.jsonl VARIANT,VARIANT,... [SKIP_RUNS]"""
import json
import statistics
import sys
from collections import defaultdict

rows, variants = sys.argv[1], sys.argv[2].split(",")
skip = {int(x) for x in sys.argv[3].split(",")} if len(sys.argv) > 3 else set()
by = defaultdict(dict)  # (cell) -> {(variant, run): us}
runs = set()
for line in open(rows, encoding="utf-8"):
    r = json.loads(line)
    if r["round"] in skip:
        continue
    runs.add(r["round"])
    for c in r["warm"]:
        if c["field"] == "both":
            by[c["query"]][(r["variant"], r["round"])] = c["p50_ms"] * 1000
print(f"runs {len(runs)}")
for cell, values in by.items():
    base = statistics.median(values[("main", run)] for run in runs)
    parts = []
    for v in variants:
        med = statistics.median(values[(v, run)] for run in runs) - base
        paired = sorted(values[(v, run)] - values[("main", run)] for run in runs)
        parts.append(f"{v} {med:+.1f} [{paired[0]:+.0f}..{paired[-1]:+.0f}]")
    print(f"both {cell!r}: main {base:.1f}; " + "; ".join(parts))

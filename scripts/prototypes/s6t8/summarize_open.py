#!/usr/bin/env python3
"""S6-T8: open time and memory after open, the head against BASE, from
bench.py rows (ruling 4's "open not above main" and "memory not above main").

    python3 -I summarize_open.py BASE HEAD CONTROL[,CONTROL...] ROWS.jsonl ...

Per corpus (the index folder's name): each run's open p50 for BASE and HEAD,
the median over runs of HEAD's change in us and in percent of BASE's median
(one decimal, rounded to nearest, half away from zero), the largest
control's median change, and each run's RSS change at open (bench.py's
`memory.open_delta`) for BASE and HEAD. Not part of any library.
"""
import json
import statistics
import sys
from collections import defaultdict

base, head, controls = sys.argv[1], sys.argv[2], sys.argv[3].split(",")
opens = defaultdict(lambda: defaultdict(list))
memory = defaultdict(lambda: defaultdict(list))
order = []
for path in sys.argv[4:]:
    for line in open(path, encoding="utf-8"):
        r = json.loads(line)
        corpus = r["index"].rstrip("/").split("/")[-1]
        if corpus not in order:
            order.append(corpus)
        opens[corpus][r["variant"]].append(r["open"]["p50_ms"])
        memory[corpus][r["variant"]].append(r["memory"]["open_delta"])


def pct(change: float, of: float) -> str:
    tenths = int(abs(change) * 1000 / of + 0.5)
    return f"{'-' if change < 0 else '+'}{tenths // 10}.{tenths % 10} %"


for corpus in order:
    o, m = opens[corpus], memory[corpus]
    b = statistics.median(o[base])
    d = (statistics.median(o[head]) - b) * 1000
    largest = max((statistics.median(o[c]) - b) * 1000 for c in controls)
    runs = lambda v: " ".join(f"{x:.3f}" for x in o[v])
    mem = lambda v: " / ".join(f"{x:,}" for x in m[v])
    print(f"{corpus:11s} open {base} {runs(base)} ms, {head} {runs(head)} ms; median d {d:+.1f} us ({pct(d, b * 1000)}), "
          f"largest control {largest:+.1f} us; memory after open {base} {mem(base)} B, {head} {mem(head)} B")

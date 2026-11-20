#!/usr/bin/env python3
"""S6-T9: the cells after an open in bench.py rows (open, first content
query, first find, first file-name query, first both query), each read by
the rule of 2026-11-17 (docs/process/ROLES.md).

    python3 -I summarize_first.py BASE HEAD CONTROL[,CONTROL...] ROWS.jsonl ...

Per corpus (the index folder's name) and cell: BASE's median p50 over the
runs, d = the median over runs of (HEAD - BASE) in us and in percent of
BASE's median (one decimal, rounded to nearest), T = the larger of 10 us
and 1 % of BASE's median, and the largest control's median change. "at T"
when d >= T; "beyond" when also d - largest control >= T. Not part of any
library.
"""
import json
import statistics
import sys
from collections import defaultdict

base, head, controls = sys.argv[1], sys.argv[2], sys.argv[3].split(",")
CELLS = (("open", "open"), ("first_query", "first query"), ("first_find", "first find"),
         ("first_filename", "first filename"), ("first_both", "first both"))
values = defaultdict(lambda: defaultdict(lambda: defaultdict(dict)))
order = []
for path in sys.argv[4:]:
    for line in open(path, encoding="utf-8"):
        r = json.loads(line)
        corpus = r["index"].rstrip("/").split("/")[-1]
        if corpus not in order:
            order.append(corpus)
        for key, _ in CELLS:
            values[corpus][key][r["variant"]][r["round"]] = r[key]["p50_ms"]


def pct(change: float, of: float) -> str:
    tenths = int(abs(change) * 1000 / of + 0.5)
    return f"{'-' if change < 0 else '+'}{tenths // 10}.{tenths % 10} %"


def median_change(cell, variant):
    return statistics.median((cell[variant][run] - cell[base][run]) * 1000 for run in cell[base])


at_t = beyond = 0
for corpus in order:
    for key, label in CELLS:
        cell = values[corpus][key]
        b = statistics.median(cell[base].values()) * 1000
        t = max(10.0, 0.01 * b)
        d = median_change(cell, head)
        largest = max(median_change(cell, c) for c in controls)
        flag = ""
        if d >= t:
            at_t += 1
            flag = "AT T"
            if d - largest >= t:
                beyond += 1
                flag = "BEYOND"
        print(f"{corpus:11s} {label:15s} {base} {b:9.1f} us  d {d:+8.1f} us ({pct(d, b)})  T {t:5.1f}  largest control {largest:+8.1f} us  {flag}")
print(f"cells at T: {at_t}; beyond the controls by T: {beyond}")

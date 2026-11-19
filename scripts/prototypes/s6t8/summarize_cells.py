#!/usr/bin/env python3
"""S6-T8 (rulings on the Report, item 2): warm query cells of bench.py rows,
each variant's median p50 change against BASE, by the rule of 2026-11-17.

    python3 -I summarize_cells.py ROWS.jsonl BASE HEAD CONTROL[,CONTROL...] [OTHER,...]

Per cell (a warm query's field and query, or a `find`'s mode and query): BASE's median p50 in us, each other variant's
median change in us, T = max(10 us, 1 % of BASE's median), and HEAD's
change less the largest control's; "beyond" when HEAD's change and that
difference are both T or more. OTHER variants (for instance another build of
the head's query-path source) are shown but are not controls. Also the number of distinct answers over
every row of the cell (1 = every variant answered the same). Not part of any
library.
"""
import json
import statistics
import sys
from collections import defaultdict

rows_path, base, head, controls = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].split(",")
others = sys.argv[5].split(",") if len(sys.argv) > 5 else []
cells = defaultdict(lambda: defaultdict(list))
answers = defaultdict(set)
runs = set()
loads = []
for line in open(rows_path, encoding="utf-8"):
    r = json.loads(line)
    runs.add(r["round"])
    loads += r.get("load_before", [])
    for c in r["warm"]:
        key = (c["field"], c["query"])
        cells[key][r["variant"]].append(c["p50_ms"] * 1000)
        answers[key].add(c["answer_sha256"])
    for c in r.get("find", []):
        key = ("find " + c["mode"], c["query"])
        cells[key][r["variant"]].append(c["p50_ms"] * 1000)
        answers[key].add(c["answer_sha256"])
variants = [base] + controls + others + [head]
print(f"runs {len(runs)}; 1-, 5- and 15-minute load before each set {min(loads):.2f}-{max(loads):.2f}")
print("cell".ljust(36) + "".join(v.rjust(9) for v in variants) + "       T  head-ctl  verdict  answers")
for key, by in cells.items():
    m = statistics.median(by[base])
    t = max(10.0, m / 100)
    change = {v: statistics.median(by[v]) - m for v in variants if v != base}
    largest = max(change[c] for c in controls)
    h = change[head]
    verdict = "beyond" if h >= t and h - largest >= t else ("at T" if h >= t else "-")
    print(f"{key[0] + ' ' + key[1]:36s}{m:9.1f}" + "".join(f"{change[v]:+9.1f}" for v in variants[1:])
          + f" {t:7.1f} {h - largest:+9.1f}  {verdict:7s}  {len(answers[key])}")

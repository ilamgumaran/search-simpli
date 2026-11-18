#!/usr/bin/env python3
"""S6-T7 Phase 2: the builder's two query/`find` runs, read by the rule of
2026-11-17 (docs/process/ROLES.md) for information only (the verifier's five
runs decide).

    python3 -I query_cells.py RUN1.jsonl RUN2.jsonl

Rows are S6-T4's `bench.py bench` rows of five libraries: main, main2, head,
ctl1, ctl2. Per corpus and cell (warm query per field, `find` request; and
open, first query, first find): d = head - main per run, its median over the
runs; T = the larger of 0.010 ms and 1 % of main's median; the controls'
largest median of (control - main). A cell is "at T" when median d >= T and
"beyond the controls" when also median d - largest control >= T. Answer
hashes: head's against main's for every cell. Not part of any library.
"""
import json
import statistics
import sys
from collections import defaultdict

CONTROLS = ("main2", "ctl1", "ctl2")


def cells(row):
    out = {"open": (row["open"]["p50_ms"], None), "first query": (row["first_query"]["p50_ms"], None),
           "first find": (row["first_find"]["p50_ms"], None)}
    for w in row["warm"]:
        out[f"{w['field']} {w['query']}"] = (w["p50_ms"], w.get("answer_sha256"))
    for f in row["find"]:
        out[f"find {f['mode']} {f['query']}"] = (f["p50_ms"], f.get("answer_sha256"))
    return out


runs = []
loads = []
for path in sys.argv[1:]:
    rows = defaultdict(dict)
    for line in open(path, encoding="utf-8"):
        r = json.loads(line)
        rows[r["index"].rstrip("/").split("/")[-1]][r["variant"]] = r
        loads += r["load_before"] + r["load_after"]
    runs.append(rows)
print(f"runs {len(runs)}; 5-minute load {min(loads):.2f}-{max(loads):.2f}")
for corpus in runs[0]:
    per = [{v: cells(run[corpus][v]) for v in ("main", "head") + CONTROLS} for run in runs]
    keys = list(per[0]["main"])
    at_t, beyond, hash_bad, n = [], [], 0, 0
    by_group = defaultdict(list)
    for k in keys:
        n += 1
        main_med = statistics.median(p["main"][k][0] for p in per)
        d = statistics.median(p["head"][k][0] - p["main"][k][0] for p in per)
        ctl = max(statistics.median(p[c][k][0] - p["main"][k][0] for p in per) for c in CONTROLS)
        t = max(0.010, 0.01 * main_med)
        group = k.split(" ", 1)[0] if not k.startswith(("open", "first")) else k
        by_group[group].append((d, main_med))
        if any(p["head"][k][1] != p["main"][k][1] for p in per):
            hash_bad += 1
        if d >= t:
            at_t.append((k, round(d * 1000, 2), round(ctl * 1000, 2)))
            if d - ctl >= t:
                beyond.append(k)
    print(f"## {corpus}: {n} cells; answers differ from main in {hash_bad}; at T {len(at_t)}; beyond the controls by T {len(beyond)}")
    for k, d, c in at_t:
        print(f"   at T: {k}: d {d:+.2f} us, largest control {c:+.2f} us")
    for g, values in by_group.items():
        ds = [v[0] * 1000 for v in values]
        rel = [v[0] / v[1] * 100 for v in values]
        print(f"   {g:12s} cells {len(values):3d}  median d {statistics.median(ds):+8.3f} us  range {min(ds):+8.3f} .. {max(ds):+8.3f} us  "
              f"median {statistics.median(rel):+6.2f} %")

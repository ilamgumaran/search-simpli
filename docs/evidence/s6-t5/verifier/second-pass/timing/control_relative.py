#!/usr/bin/env python3
"""S6-T5 second verification, computed afterwards at the orchestrator's request (a rule applied after the
measurement, not part of the Verdict). From the five gated runs (run1..5.jsonl in this folder), per cell:
m_X = five-run median of (X - main) for X in head, main2, ctl1, ctl2 (p50 per run, ms); T = 0.010 ms, or 1 % of
main's five-run median when that is 5 ms or more.
(A) m_head >= T;  (B) (A) and m_head > max(m_main2, m_ctl1, m_ctl2);  (C) (A) and m_head > that max + T.
Also per field: cells with m_main2 >= T, m_ctl1 >= T, m_ctl2 >= T.
    python3 control_relative.py run1.jsonl ... run5.jsonl > control-relative.md
"""
import json
import statistics
import sys
from collections import defaultdict

FIELDS = ("content", "find", "filename", "both")


def cells(row):
    out = {}
    for w in row["warm"]:
        out[f"{w['field']} {w['query']}"] = w["p50_ms"]
    for f in row["find"]:
        out[f"find {f['mode']} {f['query']}"] = f["p50_ms"]
    return out


runs = []
for p in sys.argv[1:]:
    rows = defaultdict(dict)
    for line in open(p, encoding="utf-8"):
        r = json.loads(line)
        rows[r["index"].rstrip("/").split("/")[-1]][r["variant"].removeprefix("n")] = cells(r)
    runs.append(rows)
assert len(runs) == 5

out = []
for corpus in runs[0]:
    for k in runs[0][corpus]["main"]:
        main = [run[corpus]["main"][k] for run in runs]
        m = {v: statistics.median(run[corpus][v][k] - run[corpus]["main"][k] for run in runs)
             for v in ("head", "main2", "ctl1", "ctl2")}
        main_med = statistics.median(main)
        T = 0.010 if main_med < 5.0 else 0.01 * main_med
        ctl_max = max(m["main2"], m["ctl1"], m["ctl2"])
        A = m["head"] >= T
        out.append({"corpus": corpus, "cell": k, "field": k.split(" ", 1)[0], "main": main_med, "T": T, **m,
                    "A": A, "B": A and m["head"] > ctl_max, "C": A and m["head"] > ctl_max + T,
                    "main2_T": m["main2"] >= T, "ctl1_T": m["ctl1"] >= T, "ctl2_T": m["ctl2"] >= T})

us = lambda x: f"{x * 1000:+.2f}"
print("# S6-T5 second pass: head against the controls' own medians\n")
print("**Computed afterwards at the orchestrator's request, for the maintainer; not part of the Verdict.** This is a")
print("rule applied after the measurement, to the five gated runs already taken (`run1..5.jsonl`); no new run, no")
print("build. m_X = five-run median of (X − `main`), X = head, `main2`, `ctl1`, `ctl2`; T = 0.010 ms, or 1 % of")
print("`main`'s five-run median at 5 ms or more. (A) m_head ≥ T (clause (1), as reported); (B) (A) and m_head >")
print("max(m_main2, m_ctl1, m_ctl2); (C) (A) and m_head > that max + T. Script: `control_relative.py`.\n")
print("| Field | Cells | (A) | (B) | (C) | m_main2 ≥ T | m_ctl1 ≥ T | m_ctl2 ≥ T |")
print("|---|---:|---:|---:|---:|---:|---:|---:|")
for f in FIELDS:
    cs = [c for c in out if c["field"] == f]
    print(f"| `{f}` | {len(cs)} | {sum(c['A'] for c in cs)} | {sum(c['B'] for c in cs)} | {sum(c['C'] for c in cs)} | "
          f"{sum(c['main2_T'] for c in cs)} | {sum(c['ctl1_T'] for c in cs)} | {sum(c['ctl2_T'] for c in cs)} |")
cs = out
print(f"| all | {len(cs)} | {sum(c['A'] for c in cs)} | {sum(c['B'] for c in cs)} | {sum(c['C'] for c in cs)} | "
      f"{sum(c['main2_T'] for c in cs)} | {sum(c['ctl1_T'] for c in cs)} | {sum(c['ctl2_T'] for c in cs)} |")
print("\nEvery cell in (B), µs (medians of differences against `main`):\n")
print("| Corpus | Cell | `main` median | T | m_head | m_main2 | m_ctl1 | m_ctl2 | m_head − max(controls) | (C) |")
print("|---|---|---:|---:|---:|---:|---:|---:|---:|---|")
for c in out:
    if c["B"]:
        mx = max(c["main2"], c["ctl1"], c["ctl2"])
        print(f"| {c['corpus']} | `{c['cell']}` | {c['main'] * 1000:.1f} | {c['T'] * 1000:.1f} | {us(c['head'])} | "
              f"{us(c['main2'])} | {us(c['ctl1'])} | {us(c['ctl2'])} | {us(c['head'] - mx)} | {'yes' if c['C'] else 'no'} |")
print("\nCells where a control or `main2` reaches T (the controls' own clause-(1) \"failures\"), µs:\n")
print("| Corpus | Cell | `main` median | T | m_head | m_main2 | m_ctl1 | m_ctl2 |")
print("|---|---|---:|---:|---:|---:|---:|---:|")
for c in out:
    if c["main2_T"] or c["ctl1_T"] or c["ctl2_T"]:
        print(f"| {c['corpus']} | `{c['cell']}` | {c['main'] * 1000:.1f} | {c['T'] * 1000:.1f} | {us(c['head'])} | "
              f"{us(c['main2'])} | {us(c['ctl1'])} | {us(c['ctl2'])} |")

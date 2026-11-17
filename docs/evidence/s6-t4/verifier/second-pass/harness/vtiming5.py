#!/usr/bin/env python3
"""Second verification of S6-T4: the five-run rule (orchestrator's ruling after
the first Verdict).

    vtiming5.py RUN1 ... RUN5

Per corpus and cell: d_r = head - main (p50 of the cell in run r). Band of a run =
min..max of main, main2, vctl1, vctl2 in that run. T = 0.010 ms, or 1 % of main's
five-run median when that median is 5 ms or more. A cell fails if
(1) median_r(d_r) >= T, or (2) head > the band's max in 3 or more of the 5 runs.
Prints JSON: failing cells, every cell with median d >= +0.005 ms (with main2 - main's
five-run median), per-corpus worst cells, answer-hash equality, the bars.
"""
import json
import statistics
import sys
from collections import defaultdict

CONTROLS = ("main", "main2", "vctl1", "vctl2")


def corpus_of(index):
    return index.rstrip("/").split("/")[-1]


def cells(row):
    out = {}
    for w in row["warm"]:
        out[f"{w['field']} {w['query']}"] = (w["p50_ms"], w.get("answer_sha256"))
    for f in row["find"]:
        out[f"find {f['mode']} {f['query']}"] = (f["p50_ms"], f.get("answer_sha256"))
    return out


def main():
    runs = []
    for p in sys.argv[1:]:
        rows = defaultdict(dict)
        for line in open(p, encoding="utf-8"):
            r = json.loads(line)
            rows[corpus_of(r["index"])][r["variant"]] = r
        runs.append(rows)
    rep = {"fail_1": [], "fail_2": [], "near": [], "worst": {}, "answers_equal": True, "bars": {}, "counts": {}}
    for corpus in runs[0]:
        per_run = [{v: cells(run[corpus][v]) for v in CONTROLS + ("head",)} for run in runs]
        keys = list(per_run[0]["main"])
        rep["counts"][corpus] = len(keys)
        allcells = []
        for k in keys:
            for pr in per_run:
                hashes = {pr[v][k][1] for v in pr}
                if len(hashes) != 1:
                    rep["answers_equal"] = False
            mains = [pr["main"][k][0] for pr in per_run]
            d = [pr["head"][k][0] - pr["main"][k][0] for pr in per_run]
            d2 = [pr["main2"][k][0] - pr["main"][k][0] for pr in per_run]
            above = [pr["head"][k][0] > max(pr[c][k][0] for c in CONTROLS) for pr in per_run]
            below = [pr["head"][k][0] < min(pr[c][k][0] for c in CONTROLS) for pr in per_run]
            band = [max(pr[c][k][0] for c in CONTROLS) - min(pr[c][k][0] for c in CONTROLS) for pr in per_run]
            main_med = statistics.median(mains)
            T = 0.010 if main_med < 5.0 else 0.01 * main_med
            md = statistics.median(d)
            cell = {"cell": f"{corpus} | {k}", "main_median": round(main_med, 4), "T": round(T, 4),
                    "d": [round(x, 4) for x in d], "median_d": round(md, 4),
                    "main2_minus_main": [round(x, 4) for x in d2], "median_main2": round(statistics.median(d2), 4),
                    "above_band_runs": sum(above), "below_band_runs": sum(below),
                    "band_width": [round(x, 4) for x in band]}
            allcells.append(cell)
            if md >= T:
                rep["fail_1"].append(cell["cell"])
            if sum(above) >= 3:
                rep["fail_2"].append(cell["cell"])
            if md >= 0.005 or md >= T or sum(above) >= 3:
                rep["near"].append(cell)
        rep["worst"][corpus] = sorted(allcells, key=lambda c: -c["median_d"])[:3]
        rep["above3_any"] = rep.get("above3_any", 0)
        b = []
        for pr_run in runs:
            m, h = pr_run[corpus]["main"], pr_run[corpus]["head"]
            b.append({"open_pct": round(100 * (h["open"]["p50_ms"] / m["open"]["p50_ms"] - 1), 1),
                      "first_find_pct": round(100 * (h["first_find"]["p50_ms"] / m["first_find"]["p50_ms"] - 1), 1),
                      "mem_open_MB": [round(m["memory"]["open_delta"] / 1e6, 1), round(h["memory"]["open_delta"] / 1e6, 1)],
                      "mem_q_MB": [round(m["memory"]["queries_delta"] / 1e6, 1), round(h["memory"]["queries_delta"] / 1e6, 1)]})
        rep["bars"][corpus] = b
    print(json.dumps(rep, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()

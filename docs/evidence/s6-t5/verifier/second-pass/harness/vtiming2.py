#!/usr/bin/env python3
"""S6-T5 second verification: vtiming.py with the n-prefixed library names mapped. S6-T5 verification: the five-run rule (S6-T4, "Ruling after the first Verdict", with the
second Verdict's varied orders), adapted from S6-T4's verifier vtiming5.py.

    vtiming.py RUN1 ... RUN5 > analysis.json

Per corpus and cell: d_r = head - main (p50 of the cell in run r). Band of a run = min..max of
main, main2, ctl1, ctl2 in that run. T = 0.010 ms, or 1 % of main's five-run median when that
median is 5 ms or more. A cell fails (1) if median_r(d_r) >= T, (2) if head > the band's max in
3 or more of the 5 runs. Answer hashes: every library's equal to main's on content and find
cells; on both/filename cells the four controls equal main's (head's differ only by warnings,
checked separately).
"""
import json
import statistics
import sys
from collections import defaultdict

CONTROLS = ("main", "main2", "ctl1", "ctl2")


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
            # second pass: the libraries are named nmain, nmain2, nhead, nctl1, nctl2
            rows[corpus_of(r["index"])][r["variant"][1:] if r["variant"].startswith("n") else r["variant"]] = r
        runs.append(rows)
    rep = {"fail_1": [], "fail_2": [], "table": [], "per_field": {}, "hash_problems": [], "head_hash_differs": 0,
           "loads": [], "all": []}
    for corpus in runs[0]:
        per_run = [{v: cells(run[corpus][v]) for v in CONTROLS + ("head",)} for run in runs]
        keys = list(per_run[0]["main"])
        for k in keys:
            field = k.split(" ", 1)[0]
            for pr in per_run:
                ctl_hashes = {pr[v][k][1] for v in CONTROLS}
                if len(ctl_hashes) != 1:
                    rep["hash_problems"].append(f"{corpus} | {k}: controls differ")
                if field in ("content", "find") and pr["head"][k][1] != pr["main"][k][1]:
                    rep["hash_problems"].append(f"{corpus} | {k}: head differs")
                if field in ("both", "filename") and pr["head"][k][1] != pr["main"][k][1]:
                    rep["head_hash_differs"] += 1
            mains = [pr["main"][k][0] for pr in per_run]
            d = [pr["head"][k][0] - pr["main"][k][0] for pr in per_run]
            d2 = [pr["main2"][k][0] - pr["main"][k][0] for pr in per_run]
            dc1 = [pr["ctl1"][k][0] - pr["main"][k][0] for pr in per_run]
            dc2 = [pr["ctl2"][k][0] - pr["main"][k][0] for pr in per_run]
            above = [pr["head"][k][0] > max(pr[c][k][0] for c in CONTROLS) for pr in per_run]
            band = [max(pr[c][k][0] for c in CONTROLS) - min(pr[c][k][0] for c in CONTROLS) for pr in per_run]
            excess = [pr["head"][k][0] - max(pr[c][k][0] for c in CONTROLS) for pr in per_run]
            main_med = statistics.median(mains)
            T = 0.010 if main_med < 5.0 else 0.01 * main_med
            md = statistics.median(d)
            cell = {"corpus": corpus, "cell": k, "field": field, "main_median": round(main_med, 4), "T": round(T, 4),
                    "d": [round(x, 4) for x in d], "median_d": round(md, 4), "median_d_us": round(md * 1000, 2),
                    "median_main2": round(statistics.median(d2), 4), "median_ctl1": round(statistics.median(dc1), 4),
                    "median_ctl2": round(statistics.median(dc2), 4),
                    "above_band_runs": sum(above), "band_width": [round(x, 4) for x in band],
                    "median_excess_over_band_us": round(statistics.median(excess) * 1000, 2)}
            rep["all"].append(cell)
            f1, f2 = md >= T, sum(above) >= 3
            cell["fails"] = ("(1)" if f1 else "") + ("(2)" if f2 else "") or "no"
            if f1:
                rep["fail_1"].append(f"{corpus} | {k}")
            if f2:
                rep["fail_2"].append(f"{corpus} | {k}")
            if md >= 0.005 or f1 or f2:
                rep["table"].append(cell)
            pf = rep["per_field"].setdefault(f"{corpus} {field}", {"cells": 0, "fail_1": 0, "fail_2": 0, "median_d_us": []})
            pf["cells"] += 1
            pf["fail_1"] += f1
            pf["fail_2"] += f2
            pf["median_d_us"].append(round(md * 1000, 2))
        for i, run in enumerate(runs):
            for v in CONTROLS + ("head",):
                r = run[corpus][v]
                rep["loads"].append([i + 1, corpus, v, r["load_before"], r["load_after"]])
    for v in rep["per_field"].values():
        xs = sorted(v["median_d_us"])
        v["median_d_us"] = {"min": xs[0], "median": statistics.median(xs), "max": xs[-1]}
    print(json.dumps(rep, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()

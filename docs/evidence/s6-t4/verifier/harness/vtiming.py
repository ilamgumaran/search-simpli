#!/usr/bin/env python3
"""Verifier's analysis of the S6-T4 timing runs.

    vtiming.py MY_RUN1 MY_RUN2 BUILDER_RUN1 BUILDER_RUN2

Per corpus, per run: head - main per cell (p50 of the cell in that run);
the band of a run and workload is the largest |x - main| over the workload's
cells for x in the controls (main2, vctl1, vctl2; the builder's: main2, ctl1,
ctl2). The rule fixed by "Rulings on the Phase 2 Report": a cell fails if
(a) beyond the band in both of my runs, (b) at or above T in both of my runs,
(c) at or above T in one of my runs and in one of the builder's runs.
T = 0.010 ms, or 1 % of main's p50 when main's p50 is 5 ms or more.
"""
import json
import sys
from collections import defaultdict

CONTROLS = {"mine": ("main2", "vctl1", "vctl2"), "builder": ("main2", "ctl1", "ctl2")}
HEAD = {"mine": "head", "builder": "v3"}


def corpus_of(index):
    return index.rstrip("/").split("/")[-1]


def load(path):
    rows = defaultdict(dict)
    for line in open(path, encoding="utf-8"):
        r = json.loads(line)
        rows[corpus_of(r["index"])][r["variant"]] = r
    return rows


def cells(row):
    out = {}
    for w in row["warm"]:
        out[("warm", f"{w['field']} {w['query']}")] = w["p50_ms"]
    for f in row["find"]:
        out[("find", f"find {f['mode']} {f['query']}")] = f["p50_ms"]
    return out


def analyse(rows, who):
    res = {}
    for corpus, variants in rows.items():
        main = cells(variants["main"])
        head = cells(variants[HEAD[who]])
        band = {}
        for wl in ("warm", "find"):
            band[wl] = max(abs(cells(variants[c])[k] - main[k]) for c in CONTROLS[who] for k in main if k[0] == wl)
        per = {}
        for k in main:
            t = 0.010 if main[k] < 5.0 else 0.01 * main[k]
            per[k] = {"delta": head[k] - main[k], "main": main[k], "T": t, "band": band[k[0]]}
        res[corpus] = {"band": band, "cells": per,
                       "answers_equal": all(
                           a.get("answer_sha256") == b.get("answer_sha256")
                           for v in variants.values()
                           for a, b in zip(variants["main"]["warm"] + variants["main"]["find"], v["warm"] + v["find"])),
                       "bars": bars(variants, HEAD[who])}
    return res


def bars(variants, head):
    m, h = variants["main"], variants[head]
    return {
        "open_main": m["open"]["p50_ms"], "open_head": h["open"]["p50_ms"],
        "open_pct": 100.0 * (h["open"]["p50_ms"] / m["open"]["p50_ms"] - 1),
        "first_find_pct": 100.0 * (h["first_find"]["p50_ms"] / m["first_find"]["p50_ms"] - 1),
        "first_query_pct": 100.0 * (h["first_query"]["p50_ms"] / m["first_query"]["p50_ms"] - 1),
        "mem_open_main_MB": m["memory"]["open_delta"] / 1e6, "mem_open_head_MB": h["memory"]["open_delta"] / 1e6,
        "mem_q_main_MB": m["memory"]["queries_delta"] / 1e6, "mem_q_head_MB": h["memory"]["queries_delta"] / 1e6,
        "load": [m["load_before"], h["load_before"]],
    }


def main():
    mine = [analyse(load(p), "mine") for p in sys.argv[1:3]]
    builder = [analyse(load(p), "builder") for p in sys.argv[3:5]]
    report = {"bands": {}, "listed": [], "fail_a": [], "fail_b": [], "fail_c": [], "bars": {}, "answers_equal": {}}
    for corpus in mine[0]:
        report["bands"][corpus] = [m[corpus]["band"] for m in mine] + [b[corpus]["band"] for b in builder if corpus in b]
        report["bars"][corpus] = [m[corpus]["bars"] for m in mine]
        report["answers_equal"][corpus] = [m[corpus]["answers_equal"] for m in mine]
        for k in mine[0][corpus]["cells"]:
            my = [m[corpus]["cells"][k] for m in mine]
            bu = [b[corpus]["cells"].get(k) for b in builder if corpus in b]
            T = max(c["T"] for c in my)
            beyond = [c["delta"] > c["band"] for c in my]
            at_T_mine = [c["delta"] >= c["T"] for c in my]
            at_T_b = [c is not None and c["delta"] >= c["T"] for c in bu]
            name = f"{corpus} | {k[1]}"
            if all(beyond):
                report["fail_a"].append(name)
            if all(at_T_mine):
                report["fail_b"].append(name)
            if any(at_T_mine) and any(at_T_b):
                report["fail_c"].append(name)
            if any(at_T_mine) or any(at_T_b):
                report["listed"].append({
                    "cell": name, "T": round(T, 4),
                    "main_p50": [round(c["main"], 4) for c in my] + [round(c["main"], 4) for c in bu if c],
                    "mine": [round(c["delta"], 4) for c in my],
                    "mine_band": [round(c["band"], 4) for c in my],
                    "builder": [round(c["delta"], 4) if c else None for c in bu],
                    "builder_band": [round(c["band"], 4) if c else None for c in bu]})
        report["worst"] = report.get("worst", {})
        report["worst"][corpus] = [max(((c["delta"], k[1]) for k, c in m[corpus]["cells"].items() if k[0] == wl), key=lambda x: x[0])
                                   for m in mine for wl in ("warm", "find")]
    print(json.dumps(report, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()

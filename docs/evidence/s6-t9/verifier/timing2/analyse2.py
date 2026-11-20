#!/usr/bin/env python3
"""S6-T9 verifier, timing set 2: the timing-10k find cells, by the rule of 2026-11-17, per five-run set and pooled.
    analyse2.py SET1_DIR SET1_RUNS SET2_DIR SET2_RUNS > analysis2.txt     (RUNS like 1,2,3,4,5 or 1,2b,3,4,5)
Per cell and set: median_r(head - main), T = max(0.010 ms, 1 % of main's median), the largest median_r(control - main)
of the rule set (main2, cq, co, cf, cm, cs), fail = d >= T and d - top >= T. Also the placed set (co, cf, cm, cs) and
main2 alone. The ten runs pooled (information only) are judged the same way over ten runs."""
import json
import statistics
import sys
from pathlib import Path

med = statistics.median
SETS = {"rule": ("main2", "cq", "co", "cf", "cm", "cs"), "placed": ("co", "cf", "cm", "cs"), "main2": ("main2",)}
ALL = ("main", "main2", "head", "cq", "co", "cf", "cm", "cs")


def load(d, runs):
    cells = {}
    hashes = {}
    for r in runs:
        for line in open(Path(d) / f"q-run{r}.jsonl"):
            x = json.loads(line)
            if x["index"].rstrip("/").split("/")[-1] != "timing-10k":
                continue
            for f in x["find"]:
                k = f"find {f['mode']} {f['query']}"
                cells.setdefault(k, {}).setdefault(r, {})[x["variant"]] = f["p50_ms"]
                hashes.setdefault(k, set()).add(f["answer_sha256"])
    for k, rr in cells.items():
        for r in runs:
            missing = set(ALL) - set(rr.get(r, {}))
            if missing:
                raise SystemExit(f"{k} run {r}: missing {sorted(missing)}")
    return cells, hashes


def judge(per_run, ctl):
    rs = list(per_run)
    m = med(per_run[r]["main"] for r in rs)
    T = max(0.010, 0.01 * m)
    d = med(per_run[r]["head"] - per_run[r]["main"] for r in rs)
    tops = {v: med(per_run[r][v] - per_run[r]["main"] for r in rs) for v in ctl}
    top_v = max(tops, key=tops.get)
    top = tops[top_v]
    return {"main": m, "T": T, "d": d, "top": top, "top_v": top_v, "fail": d >= T and d - top >= T}


s1, h1 = load(sys.argv[1], sys.argv[2].split(","))
s2, h2 = load(sys.argv[3], sys.argv[4].split(","))
assert set(s1) == set(s2), "different cells"
us = lambda x: f"{x * 1000:+.1f}"
out = {}
print(f"set 1 runs {sys.argv[2]}; set 2 runs {sys.argv[4]}; {len(s1)} timing-10k find cells")
print("cell | set1 head-main, T, top ctl, rule | set2 head-main, T, top ctl, rule | pooled(10) head-main, T, top, rule "
      "| set2 placed, main2 alone")
for k in sorted(s1):
    pooled = {f"1:{r}": v for r, v in s1[k].items()} | {f"2:{r}": v for r, v in s2[k].items()}
    a, b, p = judge(s1[k], SETS["rule"]), judge(s2[k], SETS["rule"]), judge(pooled, SETS["rule"])
    bp, bm = judge(s2[k], SETS["placed"]), judge(s2[k], SETS["main2"])
    pp, pm = judge(pooled, SETS["placed"]), judge(pooled, SETS["main2"])
    F = lambda j: "FAIL" if j["fail"] else "pass"
    print(f"{k:34s} | {us(a['d'])} T {a['T'] * 1000:.1f} top {us(a['top'])} {a['top_v']} {F(a)} "
          f"| {us(b['d'])} T {b['T'] * 1000:.1f} top {us(b['top'])} {b['top_v']} {F(b)} "
          f"| {us(p['d'])} T {p['T'] * 1000:.1f} top {us(p['top'])} {F(p)} "
          f"| placed {F(bp)} main2 {F(bm)} (pooled placed {F(pp)} main2 {F(pm)})")
    out[k] = {"set1": a, "set2": b, "pooled": p, "set2_placed": bp, "set2_main2": bm, "pooled_placed": pp,
              "pooled_main2": pm, "set2_per_run": s2[k]}
f1 = [k for k in out if out[k]["set1"]["fail"]]
f2 = [k for k in out if out[k]["set2"]["fail"]]
fp = [k for k in out if out[k]["pooled"]["fail"]]
print(f"\nrule set fails: set 1 {len(f1)} {f1}\n                set 2 {len(f2)} {f2}\n                pooled {len(fp)} {fp}")
print(f"set 2 placed-alone fails: {[k for k in out if out[k]['set2_placed']['fail']]}")
print(f"set 2 main2-alone fails: {[k for k in out if out[k]['set2_main2']['fail']]}")
bad = [k for k in s2 if len(h1[k] | h2[k]) != 1]
print(f"answer hashes: {len(s2)} cells, {len(bad)} with more than one answer over both sets, every build and run")
Path(sys.argv[3], "analysis2.json").write_text(json.dumps(out, indent=0))

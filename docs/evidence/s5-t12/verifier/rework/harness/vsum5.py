#!/usr/bin/env python3
"""Verifier summary of one S5-T12 re-measurement run (part 1 alone), with
item 3 of "Re-ruling after the Verdict at d882a95" applied:
    python3 -I vsum5.py RUN.jsonl
Libraries: main, main2 (a second build, byte-identical), ctl1 and ctl2 (the
verifier's placement controls: main plus inert code, main's work), head2 (the
head). Per (workload, query) the median [range] over rounds of the per-round
difference against main. A workload's band is the largest absolute median,
over that workload's cells, of main2, ctl1 and ctl2 against main. EXCEEDS:
head2 - main is above the band. SAVING: head2 - main is below -band.
"""
import json, statistics, sys
from collections import defaultdict

rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
if any("refused" in r for r in rows):
    raise SystemExit("incomplete run (a gate refusal): not summarized")
p50 = defaultdict(dict)
answers = defaultdict(set)
for r in rows:
    p50[(r["variant"], r["field"], r["query"])][r["round"]] = r["p50_ms"]
    answers[(r["field"], r["query"])].add(r["answer_sha256"])
fields = list(dict.fromkeys(r["field"] for r in rows))
queries = list(dict.fromkeys(r["query"] for r in rows))
rounds = sorted({r["round"] for r in rows})
assert all(len(v) == len(rounds) for v in p50.values()), "incomplete rounds"
CONTROLS = ("main2", "ctl1", "ctl2")


def diffs(x, f, q):
    return [p50[(x, f, q)][k] - p50[("main", f, q)][k] for k in rounds]


def med(x, f, q):
    return statistics.median(diffs(x, f, q))


print(f"rounds {len(rounds)}; answers identical across libraries and rounds: {all(len(s) == 1 for s in answers.values())}")
bands = {}
print("\n| workload | band (max abs median of main2, ctl1, ctl2) | main2 | ctl1 | ctl2 | per-round extremes of the three |")
print("|---|---:|---:|---:|---:|---:|")
for f in fields:
    per = {x: max(abs(med(x, f, q)) for q in queries) for x in CONTROLS}
    rr = [d for x in CONTROLS for q in queries for d in diffs(x, f, q)]
    bands[f] = max(per.values())
    print(f"| {f} | {bands[f]:.4f} | {per['main2']:.4f} | {per['ctl1']:.4f} | {per['ctl2']:.4f} | {min(rr):+.4f} .. {max(rr):+.4f} |")
print("\n| workload | query | main | main2 - main | ctl1 - main | ctl2 - main | head - main | vs band |")
print("|---|---|---:|---:|---:|---:|---:|---|")
exceeds, savings = [], defaultdict(list)
for f in fields:
    for q in queries:
        cells = [f"{statistics.median(p50[('main', f, q)].values()):.4f}"]
        for x in CONTROLS + ("head2",):
            d = diffs(x, f, q)
            cells.append(f"{statistics.median(d):+.4f} [{min(d):+.4f}, {max(d):+.4f}]")
        h = med("head2", f, q)
        flag = "EXCEEDS" if h > bands[f] else ("SAVING" if h < -bands[f] else "")
        if flag == "EXCEEDS":
            exceeds.append([f, q, round(h, 4), round(bands[f], 4)])
        if flag == "SAVING":
            savings[f].append(q)
        print(f"| {f} | `{q}` | " + " | ".join(cells) + f" | {flag} |")
print("\ncells exceeding their workload's band:", json.dumps(exceeds))
for f in ("both", "both-all"):
    m = [med("head2", f, q) for q in queries]
    print(f"{f}: head - main medians {min(m):+.4f} .. {max(m):+.4f}; band {bands[f]:.4f}; saving beyond the band on {len(savings[f])} of {len(queries)} queries")

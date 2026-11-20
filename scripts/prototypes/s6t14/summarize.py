#!/usr/bin/env python3
"""S6-T14 ruling 5: the timed runs of run_timing.sh by the rule of 2026-11-17, as orders.txt fixes it.

    python3 -I summarize.py BASE HEAD CONTROL[,CONTROL...] ROWS.jsonl ...

Cells per corpus (the index folder's name), from scripts/prototypes/s6t9/bench.py rows: `open` (open p50), each warm
query (field and query, p50) and each `find` (mode and query, p50) are judged; the first query, first find, first
file-name and first `both` query after an open are shown, not judged. For a cell, per run r the variant's value;
m = median_r(BASE), T = max(0.010 ms, 1 % of m), d(v) = median_r(v_r - BASE_r) (paired by run). The cell fails when
d(HEAD) >= T and d(HEAD) - max over CONTROLs of d(control) >= T. A band excursion is HEAD above every other variant
in 3 or more runs (tabulated, never failing). `answers` is the number of distinct answer digests over every row of
the cell (1: every build and run answered the same). Every time in ms in the rows, shown in us. Not part of any
library.
"""
from __future__ import annotations

import json
import statistics
import sys
from collections import defaultdict

JUDGED = ("open", "warm", "find")
SHOWN = ("first_query", "first_find", "first_filename", "first_both")


def main(argv: list[str]) -> int:
    base, head, controls = argv[1], argv[2], argv[3].split(",")
    variants = [base, *controls, head]
    values = defaultdict(lambda: defaultdict(dict))   # (corpus, kind, name) -> variant -> run -> ms
    answers = defaultdict(set)
    runs, loads = set(), []
    for path in argv[4:]:
        for line in open(path, encoding="utf-8"):
            r = json.loads(line)
            corpus = r["index"].rstrip("/").split("/")[-1]
            v, run = r["variant"], r["round"]
            runs.add(run)
            loads += r.get("load_before", [])
            values[(corpus, "open", "")][v][run] = r["open"]["p50_ms"]
            for kind in SHOWN:
                if r.get(kind):
                    values[(corpus, kind, "")][v][run] = r[kind]["p50_ms"]
            for c in r["warm"]:
                key = (corpus, "warm", f"{c['field']} {c['query']}")
                values[key][v][run] = c["p50_ms"]
                answers[key].add(c["answer_sha256"])
            for c in r.get("find", []):
                key = (corpus, "find", f"{c['mode']} {c['query']}")
                values[key][v][run] = c["p50_ms"]
                answers[key].add(c["answer_sha256"])
    runs = sorted(runs)
    print(f"runs {runs}; variants {variants}; 1-, 5- and 15-minute load before each process "
          f"{min(loads):.2f}-{max(loads):.2f}" if loads else f"runs {runs}")
    header = (f"{'cell':44}{'main us':>10}" + "".join(f"{'d ' + v:>11}" for v in variants[1:])
              + f"{'d%':>8}{'T us':>8}{'h-ctl':>9}  verdict  band  answers")
    totals = defaultdict(lambda: defaultdict(int))
    worst = {}
    for corpus in sorted({k[0] for k in values}):
        print(f"\n## {corpus}\n{header}")
        keys = sorted((k for k in values if k[0] == corpus),
                      key=lambda k: ((JUDGED + SHOWN).index(k[1]), k[2]))
        for key in keys:
            by = values[key]
            common = [r for r in runs if all(r in by.get(v, {}) for v in variants)]
            if not common:
                print(f"{key[1] + ' ' + key[2]:44}  missing in some variant")
                totals[corpus]["missing"] += 1
                continue
            m = statistics.median(by[base][r] for r in common)
            t = max(0.010, m / 100)
            d = {v: statistics.median(by[v][r] - by[base][r] for r in common) for v in variants[1:]}
            largest = max(d[c] for c in controls)
            h = d[head]
            band = sum(1 for r in common if all(by[head][r] > by[v][r] for v in variants if v != head))
            judged = key[1] in JUDGED
            if not judged:
                verdict = "shown"
            elif h >= t and h - largest >= t:
                verdict = "FAIL"
            else:
                verdict = "pass"
            if judged:
                totals[corpus][verdict] += 1
                totals[corpus]["band"] += band >= 3
                totals[corpus]["cells"] += 1
                if key[1] not in worst.get(corpus, {}) or h / m > worst[corpus][key[1]][0]:
                    worst.setdefault(corpus, {})[key[1]] = (h / m, key[2], h, m)
            pct = 100 * h / m if m else 0.0
            name = (key[1] if not key[2] else key[1] + " " + key[2])[:43]
            print(f"{name:44}{m * 1000:10.1f}" + "".join(f"{d[v] * 1000:+11.1f}" for v in variants[1:])
                  + f"{pct:+8.1f}{t * 1000:8.1f}{(h - largest) * 1000:+9.1f}  {verdict:7s}  {band}/{len(common)}"
                  + (f"  {len(answers[key])}" if key in answers else ""))
    print("\n## totals (judged cells: open, warm queries, finds)")
    failed = 0
    for corpus, t in sorted(totals.items()):
        failed += t["FAIL"]
        print(f"{corpus}: {t['cells']} cells, {t['pass']} pass, {t['FAIL']} fail, {t['band']} band excursions"
              + (f", {t['missing']} missing" if t["missing"] else ""))
        for kind, (ratio, name, h, m) in sorted(worst.get(corpus, {}).items()):
            print(f"  largest d({head})/main among {kind}: {kind} {name} {h * 1000:+.1f} us on {m * 1000:.1f} us "
                  f"({100 * ratio:+.1f} %)")
    print(f"\nexpectation (ruling 5): every judged cell passes the rule: {'met' if not failed else 'NOT met'}"
          f" ({failed} failing)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

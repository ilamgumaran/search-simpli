#!/usr/bin/env python3
"""S6-T9: run_updates.sh rows, main against head, per corpus.

    python3 -I summarize_updates.py ROWS.jsonl

Per corpus and kind (first: the first publish from main's format; second:
the one-file update after it; unchanged: an update with nothing changed),
each side's median wall time over every update of every set, the change in
ms and in percent of main's (one decimal, rounded to nearest); and the
median planning time (`plan_ms`: the stages parse_committed, load_previous
and changes) and state decode (`parse_committed`) of each kind. Also the
manifest flags after the updates and the load range. Not part of any
library.
"""
import json
import statistics
import sys
from collections import defaultdict

walls = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
plans = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
parses = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
flags = defaultdict(dict)
loads = []
order = []
for line in open(sys.argv[1], encoding="utf-8"):
    r = json.loads(line)
    corpus, v, res = r["corpus"], r["variant"], r["result"]
    if corpus not in order:
        order.append(corpus)
    flags[corpus][v] = res["flags_after"]
    loads += res["load_before"] + res["load_after"]
    for kind in ("first", "second", "unchanged"):
        for u in res[kind]:
            walls[corpus][kind][v].append(u["wall_ms"])
            plans[corpus][kind][v].append(u["plan_ms"])
            parses[corpus][kind][v].append(u["parse_committed_ms"])


def pct(change: float, of: float) -> str:
    tenths = int(abs(change) * 1000 / of + 0.5)
    return f"{'-' if change < 0 else '+'}{tenths // 10}.{tenths % 10} %"


print(f"load {min(loads):.2f}-{max(loads):.2f} (1-, 5- and 15-minute values before and after each set)")
for corpus in order:
    for kind in ("first", "second", "unchanged"):
        w, p, s = walls[corpus][kind], plans[corpus][kind], parses[corpus][kind]
        m, h = statistics.median(w["main"]), statistics.median(w["head"])
        pm, ph = statistics.median(p["main"]), statistics.median(p["head"])
        sm, sh = statistics.median(s["main"]), statistics.median(s["head"])
        print(f"{corpus:11s} {kind:9s} wall main {m:8.1f} head {h:8.1f} ms ({len(w['main'])} each) {h - m:+6.1f} ms ({pct(h - m, m)});"
              f"  plan main {pm:7.2f} head {ph:7.2f} ms ({pct(ph - pm, pm)});  state decode main {sm:.3f} head {sh:.3f} ms")
    print(f"{'':11s} flags after: main {flags[corpus]['main']}, head {flags[corpus]['head']}")

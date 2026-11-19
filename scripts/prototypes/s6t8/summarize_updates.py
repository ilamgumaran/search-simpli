#!/usr/bin/env python3
"""S6-T8: one-file update and first publish from the old format, main against
the head (rows of run_updates.sh), for ruling 4's 2 % bar.

    python3 -I summarize_updates.py UPDATES.jsonl

Per corpus and variant, the median over every timed update of every set and
run; the head's change against main in ms and percent of main (one decimal,
rounded to nearest, half away from zero). first = the first update
of main's index (head: HYBLEX03 -> HYBLEX04), second = the next one-line
update. Not part of any library.
"""
import json
import statistics
import sys
from collections import defaultdict


def pct(change: float, base: float) -> str:
    tenths = int(abs(change) * 1000 / base + 0.5)
    return f"{'-' if change < 0 else '+'}{tenths // 10}.{tenths % 10} %"


rows = defaultdict(lambda: defaultdict(lambda: {"first": [], "second": [], "after": None}))
loads = []
for line in open(sys.argv[1], encoding="utf-8"):
    r = json.loads(line)
    cell = rows[r["corpus"]][r["variant"]]
    cell["first"] += r["result"]["first_update_ms"]
    cell["second"] += r["result"]["second_update_ms"]
    cell["after"] = r["result"]["magics_after_first"]
    loads += r["result"]["load_before"] + r["result"]["load_after"]
print(f"load {min(loads):.2f}-{max(loads):.2f} (the 1-, 5- and 15-minute values before and after each set)")
for corpus, by in rows.items():
    parts = []
    for kind in ("first", "second"):
        m, h = statistics.median(by["main"][kind]), statistics.median(by["head"][kind])
        parts.append(f"{kind}: main {m:7.1f} head {h:7.1f} ({len(by['head'][kind])} each) {h - m:+6.1f} ms ({pct(h - m, m)})")
    print(f"{corpus:11s} " + "   ".join(parts))
    print(f"            after the first update: main {by['main']['after']}; head {by['head']['after']}")

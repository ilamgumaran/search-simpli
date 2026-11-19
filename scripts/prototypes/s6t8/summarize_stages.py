#!/usr/bin/env python3
"""S6-T8 (rulings on the Report, item 1a): the stage breakdown of rows from
run_stages.sh, main against the head.

    python3 -I summarize_stages.py STAGES.jsonl [MIN_MS]

Per corpus and kind (first = the first update of main's index, the head's
HYBLEX03 -> HYBLEX04 publish; second = the next one-line update), the median
of each stage over every update of every set and run, for main and the head,
and the head's change; stages whose change is under MIN_MS (default 0.3) in
both directions are left out, `total` and the wall time always shown.
Percentages of main, one decimal, rounded to nearest. Rows with no `main`
variant (the split runs) print the head's `build_lexical` stages alone. Not
part of any library.
"""
import json
import statistics
import sys
from collections import defaultdict

rows = defaultdict(lambda: defaultdict(lambda: defaultdict(lambda: defaultdict(list))))
order = defaultdict(list)
loads = []
for line in open(sys.argv[1], encoding="utf-8"):
    r = json.loads(line)
    for kind in ("first", "second"):
        for update in r["result"][kind]:
            cell = rows[r["corpus"]][kind][r["variant"]]
            cell["wall"].append(update["wall_ms"])
            for name, ms in update["stages"].items():
                cell[name].append(ms)
                if name not in order[r["corpus"]]:
                    order[r["corpus"]].append(name)
    loads += r["result"]["load_before"] + r["result"]["load_after"]
floor = float(sys.argv[2]) if len(sys.argv) > 2 else 0.3
print(f"load {min(loads):.2f}-{max(loads):.2f} (the 1-, 5- and 15-minute values before and after each set)")
for corpus, kinds in rows.items():
    for kind in ("first", "second"):
        main, head = kinds[kind]["main"], kinds[kind]["head"]
        if not main:
            # Rows of the head alone (the split of `build_lexical.offsets`).
            print(f"\n{corpus} {kind} ({len(head['wall'])} updates, head only)   head ms")
            for name in order[corpus] + ["wall"]:
                if head.get(name) and (name.startswith("build_lexical") or name in ("total", "wall")):
                    print(f"  {name:42s} {statistics.median(head[name]):9.3f}")
            continue
        print(f"\n{corpus} {kind} ({len(head['wall'])} updates each)   main ms   head ms   change")
        for name in order[corpus] + ["wall"]:
            if name not in main or name not in head:
                continue
            m, h = statistics.median(main[name]), statistics.median(head[name])
            if abs(h - m) < floor and name not in ("total", "wall"):
                continue
            pct = f"{(h - m) * 100 / m:+.1f} %" if m > 0 else ""
            print(f"  {name:42s} {m:9.3f} {h:9.3f} {h - m:+9.3f} {pct}")

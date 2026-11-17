#!/usr/bin/env python3
"""S6-T4 Phase 2: the timing and memory bars from `run2.sh`'s two runs.

    python3 -I bars.py RUN1.jsonl RUN2.jsonl

Libraries: `main` (98c4a2b on v2), `main2` (a second build of it), `ctl1`
and `ctl2` (the placement controls on v2) and `v3` (this branch on v3).
Per corpus and run, against `main`:
  - open: `ss_open`+`ss_close` p50; bar: v3 at least 10 % faster (timing,
    prose, Tamil), in both runs;
  - first `find` after an open, p50; bar: v3 at most `main` + 5 %, both runs;
  - memory (`phys_footprint` growth, MB = 10^6 B): after open v3 at least
    6 / 13 / 6 MB below `main` (timing / prose / Tamil); after the query set
    no higher than `main`'s; both runs;
  - warm query and `find` cells (p50 of each request): the band of a run and
    workload is the largest |p50 - main's p50| over its cells of `main2`,
    `ctl1` and `ctl2`. A cell fails when v3 - main exceeds the band in both
    runs, or is +0.010 ms or more in both runs; a cell whose `main` p50 is
    5 ms or more fails only when v3 - main exceeds max(band, 1 % of its
    `main` p50) in both runs. Cells at +0.010 ms or more (or over the band)
    in one run only are listed too.
Every cell's answer hash must be the same for all five libraries.
Prints Markdown. Not part of any library or the build.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

CORPORA = ["timing-10k", "prose-10k", "tamil-10k", "j2"]
LABEL = {"timing-10k": "timing", "prose-10k": "prose", "tamil-10k": "Tamil", "j2": "J2"}
MEMORY_BAR = {"timing-10k": 6e6, "prose-10k": 13e6, "tamil-10k": 6e6}
CONTROLS = ["main2", "ctl1", "ctl2"]
ABSOLUTE = 0.010
SLOW_MAIN = 5.0


def load(path: str) -> dict:
    rows = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        row = json.loads(line)
        corpus = Path(row["index"]).name
        rows[(corpus, row["variant"])] = row
    return rows


def cells(row: dict) -> dict:
    out = {}
    for c in row["warm"]:
        out[("query", c["field"], c["query"])] = c
    for c in row["find"]:
        out[("find", c["mode"], c["query"])] = c
    return out


def pct(new: float, old: float) -> str:
    return f"{(new - old) / old * 100:+.1f} %"


def main(argv: list[str]) -> int:
    runs = [load(p) for p in argv[1:3]]
    misses = []
    print("## Open, first find, memory\n")
    print("| Corpus | Run | open main / v3 (ms) | change | first find main / v3 (ms) | change "
          "| memory after open main / v3 (MB) | below main | after queries main / v3 (MB) |")
    print("|---|---|---|---|---|---|---|---|---|")
    for corpus in CORPORA:
        for n, rows in enumerate(runs, 1):
            m, v = rows[(corpus, "main")], rows[(corpus, "v3")]
            om, ov = m["open"]["p50_ms"], v["open"]["p50_ms"]
            fm, fv = m["first_find"]["p50_ms"], v["first_find"]["p50_ms"]
            mm, mv = m["memory"]["open_delta"], v["memory"]["open_delta"]
            qm, qv = m["memory"]["queries_delta"], v["memory"]["queries_delta"]
            print(f"| {LABEL[corpus]} | {n} | {om:.3f} / {ov:.3f} | {pct(ov, om)} | {fm:.3f} / {fv:.3f} | {pct(fv, fm)} "
                  f"| {mm / 1e6:.1f} / {mv / 1e6:.1f} | {(mm - mv) / 1e6:.1f} | {qm / 1e6:.1f} / {qv / 1e6:.1f} |")
            if corpus in MEMORY_BAR:
                if ov > om * 0.90:
                    misses.append(f"open {LABEL[corpus]} run {n}: {pct(ov, om)}")
                if mm - mv < MEMORY_BAR[corpus]:
                    misses.append(f"memory after open {LABEL[corpus]} run {n}: {(mm - mv) / 1e6:.1f} MB below")
                if qv > qm:
                    misses.append(f"memory after queries {LABEL[corpus]} run {n}: {(qv - qm) / 1e6:+.1f} MB")
            if fv > fm * 1.05:
                misses.append(f"first find {LABEL[corpus]} run {n}: {pct(fv, fm)}")

    print("\n## Warm query and find cells (v3 - main, ms; band = largest |control - main| of the run)\n")
    print("| Corpus | Workload | cells | band run 1 / 2 | worst v3 - main run 1 / 2 | over band both runs | +0.010 or more both runs | one run only |")
    print("|---|---|---|---|---|---|---|---|")
    differing_answers = 0
    for corpus in CORPORA:
        per_run = []
        for rows in runs:
            main_cells = cells(rows[(corpus, "main")])
            for variant in CONTROLS + ["v3"]:
                for key, c in cells(rows[(corpus, variant)]).items():
                    if c["answer_sha256"] != main_cells[key]["answer_sha256"]:
                        differing_answers += 1
            per_run.append((main_cells, {name: cells(rows[(corpus, name)]) for name in CONTROLS + ["v3"]}))
        for workload in ("query", "find"):
            keys = [k for k in per_run[0][0] if k[0] == workload]
            bands, worst, deltas = [], [], []
            for main_cells, others in per_run:
                band = max(abs(others[name][k]["p50_ms"] - main_cells[k]["p50_ms"]) for name in CONTROLS for k in keys)
                bands.append(band)
                d = {k: others["v3"][k]["p50_ms"] - main_cells[k]["p50_ms"] for k in keys}
                deltas.append(d)
                worst.append(max(d.values()))
            failed, single = [], []
            for k in keys:
                main_p50 = per_run[0][0][k]["p50_ms"]
                limits = [max(b, main_p50 * 0.01) if main_p50 >= SLOW_MAIN else b for b in bands]
                over = [deltas[i][k] > limits[i] for i in range(2)]
                absolute = [main_p50 < SLOW_MAIN and deltas[i][k] >= ABSOLUTE for i in range(2)]
                name = f"{k[1]} `{k[2]}` ({deltas[0][k]:+.4f} / {deltas[1][k]:+.4f}; main {main_p50:.3f})"
                if all(over) or all(absolute):
                    failed.append(name)
                elif any(over) or any(absolute):
                    single.append(name)
            for name in failed:
                misses.append(f"{LABEL[corpus]} {workload} cell {name}")
            print(f"| {LABEL[corpus]} | {workload} | {len(keys)} | {bands[0]:.4f} / {bands[1]:.4f} | {worst[0]:+.4f} / {worst[1]:+.4f} "
                  f"| {'; '.join(failed) or 'none'} | {'(in the column before)' if failed else 'none'} | {'; '.join(single) or 'none'} |")
    print(f"\nAnswer hashes differing from main's (any library, any cell, both runs): {differing_answers}\n")
    print("## Missed\n")
    print("\n".join(f"- {m}" for m in misses) if misses else "None.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

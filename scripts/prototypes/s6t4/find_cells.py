#!/usr/bin/env python3
"""S6-T4 rework, item 2: the three `find` cells the first Verdict named.

    python3 -I find_cells.py EVIDENCE_DIR

EVIDENCE_DIR is `docs/evidence/s6-t4`. Reads the builder's two Phase 2 runs
(`phase2/run{1,2}.jsonl`), the verifier's two (`verifier/run{1,2}.jsonl`) and
the same-library format experiment (`rework/format-ab.jsonl`,
`format_ab.sh`). Prints, for each cell:

  - every library's p50 / min by its position in the run (run2.sh and
    vrun.sh rotate the same five by RUN: run 1 runs main2, ctl1, ctl2, head,
    main; run 2 ctl1, ctl2, head, main, main2);
  - the mean p50 at each position over the four runs, and head - main,
    main2 - main per run;
  - this branch's library on the v2 and on the v3 index of the same corpus,
    alternated ABBA: v3 - v2 per round.
Not part of any library or the build; no bar is read from it.
"""

from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path

CELLS = [("timing-10k", "words", "from"), ("tamil-10k", "words", "கீகசை"), ("tamil-10k", "prefix", "டூகன*")]
ORDER = {1: ["main2", "ctl1", "ctl2", "v3", "main"], 2: ["ctl1", "ctl2", "v3", "main", "main2"]}
ALIAS = {"vctl1": "ctl1", "vctl2": "ctl2", "head": "v3"}
RUNS = [("builder 1", "phase2/run1.jsonl", 1), ("builder 2", "phase2/run2.jsonl", 2),
        ("verifier 1", "verifier/run1.jsonl", 1), ("verifier 2", "verifier/run2.jsonl", 2)]


def find_cells(path: Path) -> dict:
    out = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        row = json.loads(line)
        variant = ALIAS.get(row["variant"], row["variant"])
        corpus = Path(row["index"]).name
        for cell in row["find"]:
            out[(variant, row["round"], corpus, cell["mode"], cell["query"])] = (cell["p50_ms"], cell["min_ms"])
    return out


def main(argv: list[str]) -> int:
    base = Path(argv[1])
    runs = [(label, find_cells(base / name), number) for label, name, number in RUNS]
    ab = find_cells(base / "rework/format-ab.jsonl")
    for corpus, mode, query in CELLS:
        print(f"## {corpus} find {mode} `{query}`\n")
        print("p50 / min ms by position in the run:\n")
        by_position = {p: [] for p in range(5)}
        for label, cells, number in runs:
            parts = []
            for position, variant in enumerate(ORDER[number]):
                p50, low = cells[(variant, number, corpus, mode, query)]
                by_position[position].append(p50)
                parts.append(f"{position + 1} {variant} {p50:.4f} / {low:.4f}")
            main_p50 = cells[("main", number, corpus, mode, query)][0]
            head = cells[("v3", number, corpus, mode, query)][0] - main_p50
            twin = cells[("main2", number, corpus, mode, query)][0] - main_p50
            print(f"- {label}: " + "; ".join(parts) + f" (head - main {head:+.4f}, main2 - main {twin:+.4f})")
        means = " ".join(f"{p + 1}: {statistics.mean(v):.4f}" for p, v in by_position.items())
        print(f"\nmean p50 by position over the four runs: {means}\n")
        rounds = sorted({key[1] for key in ab if key[2] == corpus})
        deltas = []
        for r in rounds:
            v2 = ab[("head-v2", r, corpus, mode, query)]
            v3 = ab[("head-v3", r, corpus, mode, query)]
            deltas.append((r, v2, v3, v3[0] - v2[0]))
        print("this branch's library, v2 index against v3 index (ABBA; p50 / min ms):\n")
        for r, v2, v3, d in deltas:
            first = "v2 first" if r % 2 else "v3 first"
            print(f"- round {r} ({first}): v2 {v2[0]:.4f} / {v2[1]:.4f}, v3 {v3[0]:.4f} / {v3[1]:.4f}, v3 - v2 {d:+.4f}")
        print(f"\nmedian v3 - v2: {statistics.median(d for *_, d in deltas):+.4f} ms\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
"""S6-T23 Part 1: index size and time for folders, with main's `searchd`, before and after the rename prototype.

    python3 -I index_cost.py SEARCHD OUT_DIR ROUNDS LABEL=FOLDER [LABEL=FOLDER ...] > cost.json

OUT_DIR must not exist. For each round, in turn for every folder (so the folders interleave and share the machine's
state): `searchd index FOLDER --out OUT_DIR/<label>-<round> --filename-index` into a new directory (wall time of the
process), then `searchd search FOLDER <query> --evidence --search-field both` (the in-memory build plus one query,
nothing written). Reports per folder: files indexed and the report line, the index directory's bytes per file
(identical every round; checked), and the median and range of both wall times. The query is a word of the judged
set that occurs in a log line, so it is answered from the newly read files too ("reminder").
"""
from __future__ import annotations

import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path


def wall(cmd: list[str]) -> tuple[float, bytes]:
    start = time.perf_counter()
    done = subprocess.run(cmd, capture_output=True)
    ms = (time.perf_counter() - start) * 1000
    if done.returncode != 0:
        raise SystemExit(f"{cmd[1]} exited {done.returncode}: {done.stderr.decode(errors='replace')}")
    return ms, done.stdout


def dir_bytes(path: Path) -> dict:
    return {p.name: p.stat().st_size for p in sorted(path.iterdir()) if p.is_file()}


def main(argv: list[str]) -> int:
    searchd, out, rounds = argv[0], Path(argv[1]), int(argv[2])
    folders = [tuple(a.split("=", 1)) for a in argv[3:]]
    out.mkdir(parents=True)
    rows = {label: {"index_ms": [], "search_ms": [], "sizes": None} for label, _ in folders}
    for r in range(rounds):
        for label, folder in folders:
            target = out / f"{label}-{r}"
            ms, stdout = wall([searchd, "index", folder, "--out", str(target), "--filename-index"])
            rows[label]["index_ms"].append(ms)
            line = stdout.decode().strip()
            rows[label]["report"] = line[line.index(":") + 2:] if ":" in line else line
            sizes = dir_bytes(target)
            sizes.pop("WRITER.LOCK", None)
            if rows[label]["sizes"] not in (None, sizes):
                raise SystemExit(f"{label}: index sizes differ between rounds")
            rows[label]["sizes"] = sizes
            ms, _ = wall([searchd, "search", folder, "reminder", "--evidence", "--search-field", "both"])
            rows[label]["search_ms"].append(ms)
    result = {"searchd": os.path.basename(searchd), "rounds": rounds, "folders": {}}
    for label, folder in folders:
        row = rows[label]
        result["folders"][label] = {
            "report": row["report"],
            "index_bytes": sum(row["sizes"].values()),
            "sections": row["sizes"],
            "index_ms_median": round(statistics.median(row["index_ms"]), 1),
            "index_ms_range": [round(min(row["index_ms"]), 1), round(max(row["index_ms"]), 1)],
            "search_ms_median": round(statistics.median(row["search_ms"]), 1),
            "search_ms_range": [round(min(row["search_ms"]), 1), round(max(row["search_ms"]), 1)],
        }
    print(json.dumps(result, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""S6-T8 (rulings on the Report, item 1a): where a first publish from the old
format and the next one-file update spend their time, by the writer's own
stage timers (`SEARCH_SIMPLI_APPLY_STAGES=1`, S4-T4: one `apply-stages`
JSON line of milliseconds on stderr).

    python3 -I stages.py SEARCHD INDEX CORPUS WORK_DIR [ROUNDS]

The same steps as migrate.py: for each of ROUNDS (default 3) fresh copies of
the index and the corpus under WORK_DIR (which must not exist), append one
line to the first file and run `searchd index --update --keep-generations 2
--filename-index`, then a second one-line update. Prints one JSON object:
each update's stage line and its wall time in ms. A 5-minute load of 4.0 or
more refuses to run. Not part of any library or the build.
"""

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path


def run(argv) -> tuple[float, dict]:
    env = dict(os.environ, SEARCH_SIMPLI_APPLY_STAGES="1")
    started = time.perf_counter()
    done = subprocess.run(argv, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env)
    elapsed = (time.perf_counter() - started) * 1000
    if done.returncode != 0:
        raise SystemExit(f"{argv[1]} failed ({done.returncode}): {done.stderr.decode()[:300]}")
    lines = [l for l in done.stderr.decode().splitlines() if l.startswith("apply-stages ")]
    if len(lines) != 1:
        raise SystemExit(f"expected one apply-stages line, got {len(lines)}")
    return elapsed, json.loads(lines[0][len("apply-stages "):])


def main() -> int:
    searchd, index, corpus, work = (Path(a) for a in sys.argv[1:5])
    rounds = int(sys.argv[5]) if len(sys.argv) > 5 else 3
    if work.exists():
        raise SystemExit("WORK_DIR must not exist")
    load_before = os.getloadavg()
    if load_before[1] >= 4.0:
        raise SystemExit(f"5-minute load {load_before[1]:.2f} is 4.0 or more; not timing")
    first = sorted(p for p in corpus.rglob("*") if p.is_file())[0]
    relative = first.relative_to(corpus)
    out = {"first": [], "second": []}
    for round_no in range(rounds):
        base = work / f"r{round_no}"
        base.mkdir(parents=True)
        index_copy, corpus_copy = base / "index", base / "corpus"
        shutil.copytree(index, index_copy)
        shutil.copytree(corpus, corpus_copy)
        for i, kind in enumerate(("first", "second")):
            with open(corpus_copy / relative, "a", encoding="utf-8") as f:
                f.write(f"An added line for timing update {i}.\n")
            wall, stages = run([str(searchd), "index", str(corpus_copy), "--out", str(index_copy),
                                "--update", "--keep-generations", "2", "--filename-index"])
            out[kind].append({"wall_ms": round(wall, 3), "stages": stages})
    out["load_before"] = [round(x, 2) for x in load_before]
    out["load_after"] = [round(x, 2) for x in os.getloadavg()]
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

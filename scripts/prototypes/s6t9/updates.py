#!/usr/bin/env python3
"""S6-T9 (ruling 4): the first publish from main's format, a one-file update
after it, and the planning of an unchanged update, by one searchd.

    python3 -I updates.py SEARCHD INDEX CORPUS WORK_DIR [ROUNDS]

For each of ROUNDS (default 3) fresh copies of INDEX (main's v2.5 index) and
CORPUS under WORK_DIR (which must not exist), three `searchd index --update
--keep-generations 2 --filename-index` runs, each timed (wall, ms) with the
writer's stage timers on (`SEARCH_SIMPLI_APPLY_STAGES=1`, one
`apply-stages` JSON line on stderr):

- first: one line appended to the first file (with this branch's searchd
  the publish that turns a v2.5 generation into v2.6);
- second: one more line appended (a one-file update reading the new state);
- unchanged: nothing changed (the planning reads the state and finds no
  work; it still publishes a generation).

`plan_ms` of each run is the sum of the stages `parse_committed` (the state
decode), `load_previous` and `changes` (the folder compared with the state).
Prints one JSON object. A 5-minute load of 4.0 or more refuses to time.
Not part of any library or the build.
"""

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

PLAN = ("parse_committed", "load_previous", "changes")


def run(argv) -> dict:
    env = dict(os.environ, SEARCH_SIMPLI_APPLY_STAGES="1")
    started = time.perf_counter()
    done = subprocess.run(argv, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env)
    elapsed = (time.perf_counter() - started) * 1000
    if done.returncode != 0:
        raise SystemExit(f"{argv[1]} failed ({done.returncode}): {done.stderr.decode()[:300]}")
    lines = [l for l in done.stderr.decode().splitlines() if l.startswith("apply-stages ")]
    if len(lines) != 1:
        raise SystemExit(f"expected one apply-stages line, got {len(lines)}")
    stages = json.loads(lines[0][len("apply-stages "):])
    return {"wall_ms": round(elapsed, 3), "plan_ms": round(sum(stages.get(k, 0.0) for k in PLAN), 3),
            "parse_committed_ms": stages.get("parse_committed"), "stages": stages}


def flags(index: Path) -> str:
    return hex(int.from_bytes((index / "MANIFEST").read_bytes()[10:12], "little"))


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
    out = {"index": index.name, "first": [], "second": [], "unchanged": [], "flags_after": None}
    for round_no in range(rounds):
        base = work / f"r{round_no}"
        base.mkdir(parents=True)
        index_copy, corpus_copy = base / "index", base / "corpus"
        shutil.copytree(index, index_copy)
        shutil.copytree(corpus, corpus_copy)
        argv = [str(searchd), "index", str(corpus_copy), "--out", str(index_copy),
                "--update", "--keep-generations", "2", "--filename-index"]
        for i, kind in enumerate(("first", "second", "unchanged")):
            if kind != "unchanged":
                with open(corpus_copy / relative, "a", encoding="utf-8") as f:
                    f.write(f"An added line for timing update {i}.\n")
            out[kind].append(run(argv))
        out["flags_after"] = flags(index_copy)
    out["load_before"] = [round(x, 2) for x in load_before]
    out["load_after"] = [round(x, 2) for x in os.getloadavg()]
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

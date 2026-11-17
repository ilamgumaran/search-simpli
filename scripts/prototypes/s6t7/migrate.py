#!/usr/bin/env python3
"""S6-T7 Phase 2: the first update of an index from main by this branch's writer
(S6-T4's migrate.py with --filename-index and the sections' formats).

    python3 -I migrate.py SEARCHD INDEX CORPUS WORK_DIR [ROUNDS]

For each of ROUNDS (default 3) fresh copies of the index and the corpus
under WORK_DIR (which must not exist): append one line to the first file and
time `searchd index --update --keep-generations 2 --filename-index` (with
this branch's searchd the publish that turns a record v4 / `HYBSRC01`
generation into record v5 / `HYBSRC02`), then a second one-line update.
Prints one JSON object with each time in ms and the documents version and
source magic after the first update. The 5-minute load is printed before and after; a load of 4.0
or more refuses to time. Not part of any library or the build.
"""

import json
import os
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path


def run(argv) -> float:
    started = time.perf_counter()
    done = subprocess.run(argv, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    elapsed = (time.perf_counter() - started) * 1000
    if done.returncode != 0:
        raise SystemExit(f"{argv[1]} failed ({done.returncode}): {done.stderr.decode()[:300]}")
    return elapsed


def magics(index: Path) -> dict:
    generation = int.from_bytes((index / "MANIFEST").read_bytes()[12:20], "little")
    documents = (index / f"documents-{generation}.hybseg").read_bytes()[:10]
    return {"generation": generation, "documents_version": int.from_bytes(documents[8:10], "little"),
            "source_magic": (index / f"source-{generation}.hybsrc").read_bytes()[:8].decode()}


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
    migrate, steady, after = [], [], None
    for round_no in range(rounds):
        base = work / f"r{round_no}"
        base.mkdir(parents=True)
        index_copy, corpus_copy = base / "index", base / "corpus"
        shutil.copytree(index, index_copy)
        shutil.copytree(corpus, corpus_copy)
        for i, sink in enumerate((migrate, steady)):
            with open(corpus_copy / relative, "a", encoding="utf-8") as f:
                f.write(f"An added line for timing update {i}.\n")
            sink.append(run([str(searchd), "index", str(corpus_copy), "--out", str(index_copy),
                             "--update", "--keep-generations", "2", "--filename-index"]))
            if i == 0 and after is None:
                after = magics(index_copy)
    out = {"index": index.name, "first_update_ms": [round(x, 2) for x in migrate],
           "first_update_median_ms": round(statistics.median(migrate), 2),
           "second_update_ms": [round(x, 2) for x in steady],
           "second_update_median_ms": round(statistics.median(steady), 2),
           "magics_after_first": after, "load_before": [round(x, 2) for x in load_before],
           "load_after": [round(x, 2) for x in os.getloadavg()]}
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

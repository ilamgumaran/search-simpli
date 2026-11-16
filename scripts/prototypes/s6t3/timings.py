#!/usr/bin/env python3
"""S6-T3: whole-process baselines on one index, for the effects in docs/index-size.md.

    python3 -I scripts/prototypes/s6t3/timings.py SEARCHD INDEX_DIR CORPUS_DIR WORK_DIR [ROUNDS]

Each operation is a fresh `searchd` process, so every number includes the
open (reading the manifest, the documents and the lexical sections in full);
the median and the minimum of ROUNDS runs (default 7) are printed in ms.
Operations: `query` of the first file's heading, `find` of it as words and
as a phrase, `read-span` of that file's lines 1-5, and a one-file update
(`index --update --keep-generations 2` after appending a line to that file)
on copies of the index and the corpus made under WORK_DIR (a fresh,
non-existent directory). The 1-, 5- and 15-minute load averages are printed
before and after; the caller refuses to time when the 5-minute value is 4.0
or more. Prints one JSON object.
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


def summary(values) -> dict:
    return {"median_ms": round(statistics.median(values), 2), "min_ms": round(min(values), 2),
            "runs": len(values)}


def main() -> int:
    searchd, index, corpus, work = (Path(a) for a in sys.argv[1:5])
    rounds = int(sys.argv[5]) if len(sys.argv) > 5 else 7
    if work.exists():
        raise SystemExit("WORK_DIR must not exist")
    load_before = os.getloadavg()
    if load_before[1] >= 4.0:
        raise SystemExit(f"5-minute load {load_before[1]:.2f} is 4.0 or more; not timing")
    first = sorted(p for p in corpus.rglob("*") if p.is_file())[0]
    relative = first.relative_to(corpus).as_posix()
    heading = next(line for line in first.read_text(encoding="utf-8").splitlines() if line.startswith("# "))
    words = heading[2:].strip()
    out = {"index": index.name, "query_text": "<first file's heading>", "words": len(words.split()),
           "load_before": [round(x, 2) for x in load_before]}
    ops = {
        "query": [str(searchd), "query", str(index), words],
        "find_words": [str(searchd), "find", str(index), words, "--mode", "words"],
        "find_phrase": [str(searchd), "find", str(index), words, "--mode", "phrase"],
        "read_span": [str(searchd), "read-span", str(index), "r-legacy", relative, "1", "5"],
    }
    for name, argv in ops.items():
        run(argv)  # one warm-up run (page cache)
        out[name] = summary([run(argv) for _ in range(rounds)])
    work.mkdir(parents=True)
    index_copy, corpus_copy = work / "index", work / "corpus"
    shutil.copytree(index, index_copy)
    shutil.copytree(corpus, corpus_copy)
    target = corpus_copy / relative
    updates = []
    for i in range(max(3, rounds // 2)):
        with open(target, "a", encoding="utf-8") as f:
            f.write(f"An added line for timing update {i}.\n")
        updates.append(run([str(searchd), "index", str(corpus_copy), "--out", str(index_copy),
                            "--update", "--keep-generations", "2"]))
    out["one_file_update"] = summary(updates)
    out["load_after"] = [round(x, 2) for x in os.getloadavg()]
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

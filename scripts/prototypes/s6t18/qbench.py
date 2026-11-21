#!/usr/bin/env python3
"""S6-T18 ruling 4: `searchd query` timed as a process, one build over one index.

    python3 -I qbench.py SEARCHD INDEX QUERIES.json BUILD CORPUS RUN OUT.jsonl

For each cell query (QUERIES.json's `queries[8:15]`, from scripts/prototypes/s6t9/bench.py `queries`: the corpus's
words of document-frequency rank 1, 10, 100 and 1,000, the two two-word queries and the first file's stem), WARM
untimed then CALLS timed runs of `SEARCHD query INDEX "<q>"` (the default: content, top 10, plain text). Each run
is one process: `os.posix_spawn` with stdout to a pipe and stderr to /dev/null, the pipe read to its end, then
`os.wait4`; wall time from just before the spawn to just after the wait (`time.perf_counter_ns`), CPU time (user +
system) and the peak resident size (`ru_maxrss`, bytes on macOS) from the child's rusage. One JSON row per cell:
p50 and min of the wall times, p50 of the CPU times, the largest `ru_maxrss`, the answers' distinct SHA-256 (one
expected) and the exit statuses. Times in ms. Not part of any build.
"""
from __future__ import annotations

import hashlib
import json
import os
import statistics
import sys
import time

WARM = 3
CALLS = 30


def once(searchd: str, index: str, query: str) -> tuple[float, float, int, bytes, int]:
    read_end, write_end = os.pipe()
    devnull = os.open(os.devnull, os.O_WRONLY)
    actions = [(os.POSIX_SPAWN_DUP2, write_end, 1), (os.POSIX_SPAWN_DUP2, devnull, 2),
               (os.POSIX_SPAWN_CLOSE, read_end)]
    start = time.perf_counter_ns()
    pid = os.posix_spawn(searchd, [searchd, "query", index, query], {}, file_actions=actions)
    os.close(write_end)
    chunks = []
    while True:
        chunk = os.read(read_end, 65536)
        if not chunk:
            break
        chunks.append(chunk)
    _, status, usage = os.wait4(pid, 0)
    end = time.perf_counter_ns()
    os.close(read_end)
    os.close(devnull)
    cpu = (usage.ru_utime + usage.ru_stime) * 1000.0
    return (end - start) / 1e6, cpu, usage.ru_maxrss, b"".join(chunks), os.waitstatus_to_exitcode(status)


def main(argv: list[str]) -> int:
    searchd, index, queries_path, build, corpus, run, out = argv[1:8]
    queries = json.load(open(queries_path, encoding="utf-8"))["queries"][8:15]
    load_before = list(os.getloadavg())
    rows = []
    for query in queries:
        for _ in range(WARM):
            once(searchd, index, query)
        walls, cpus, peaks, answers, codes = [], [], [], set(), set()
        for _ in range(CALLS):
            wall, cpu, peak, answer, code = once(searchd, index, query)
            walls.append(wall)
            cpus.append(cpu)
            peaks.append(peak)
            answers.add(hashlib.sha256(answer).hexdigest())
            codes.add(code)
        rows.append({"build": build, "corpus": corpus, "run": int(run), "query": query, "calls": CALLS,
                     "warm": WARM, "p50_ms": statistics.median(walls), "min_ms": min(walls),
                     "cpu_p50_ms": statistics.median(cpus), "maxrss_max": max(peaks),
                     "maxrss_p50": statistics.median(peaks), "answers": sorted(answers), "exit": sorted(codes),
                     "load_before": load_before, "at": time.strftime("%Y-%m-%d %H:%M:%S")})
    with open(out, "a", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

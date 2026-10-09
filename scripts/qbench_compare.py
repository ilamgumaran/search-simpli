#!/usr/bin/env python3
"""Interleaved `ss_query` latency of an old and a new library (S2-T4 bar c).

    python3 -I scripts/qbench_compare.py OLD_LIB NEW_LIB SNAPSHOT [CALLS] [ROUNDS] [QUERY ...]

Same harness as `qbench.py` (one `ss_open` per library, lexical top-5 through
ctypes, `perf_counter`), but the three variants -- old library, new library
with the default options, new library with `"profile": true` -- run in turn in
every round, so that drift in machine load hits all three equally. Each
round contributes one p50 per variant; the table shows the median of those
per-round p50s (ms) and the new/old ratios; the `best` columns repeat the
comparison with the minimum per-round p50 (least disturbed by other load). With no queries it runs the four
research-doc queries.
"""

from __future__ import annotations

import statistics
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import qbench  # noqa: E402

LEXICAL = b'{"retrieval_mode":"lexical"}'
PROFILE = b'{"retrieval_mode":"lexical","profile":true}'


def p50(lib, handle, text: bytes, options: bytes, calls: int) -> float:
    samples = []
    for _ in range(calls):
        start = time.perf_counter()
        pointer = lib.ss_query(handle, text, None, 0, 5, options)
        samples.append((time.perf_counter() - start) * 1000.0)
        if not pointer:
            raise RuntimeError(lib.ss_last_error().decode())
        lib.ss_free(pointer)
    samples.sort()
    return samples[(len(samples) - 1) // 2]


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        print(__doc__)
        return 2
    old, new = qbench.load(argv[1]), qbench.load(argv[2])
    old_handle, new_handle = old.ss_open(argv[3].encode()), new.ss_open(argv[3].encode())
    calls = int(argv[4]) if len(argv) > 4 else 400
    rounds = int(argv[5]) if len(argv) > 5 else 15
    print(f"{'query':50} {'old':>8} {'new':>8} {'new+prof':>9} {'new/old':>8} {'prof/old':>9} | {'best new/old':>12} {'best prof/old':>13}")
    for query in argv[6:] or qbench.RESEARCH_QUERIES:
        text = query.encode()
        for lib, handle, options in ((old, old_handle, LEXICAL), (new, new_handle, LEXICAL), (new, new_handle, PROFILE)):
            p50(lib, handle, text, options, 50)  # warm up
        runs = {"old": [], "new": [], "prof": []}
        for _ in range(rounds):
            runs["old"].append(p50(old, old_handle, text, LEXICAL, calls))
            runs["new"].append(p50(new, new_handle, text, LEXICAL, calls))
            runs["prof"].append(p50(new, new_handle, text, PROFILE, calls))
        o, n, p = (statistics.median(runs[k]) for k in ("old", "new", "prof"))
        bo, bn, bp = (min(runs[k]) for k in ("old", "new", "prof"))
        print(f"{query[:50]!r:50} {o:8.4f} {n:8.4f} {p:9.4f} {n / o - 1:+8.1%} {p / o - 1:+9.1%} | {bn / bo - 1:+12.1%} {bp / bo - 1:+13.1%}")
    old.ss_close(old_handle)
    new.ss_close(new_handle)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

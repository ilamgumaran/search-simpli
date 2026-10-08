#!/usr/bin/env python3
"""In-process `ss_query` latency through the shipped library (ctypes).

The harness of docs/research/2026-10-luxir-learnings.md Appendix A (M2): one
`ss_open`, then N timed `ss_query(handle, q, NULL, 0, 5, '{"retrieval_mode":
"lexical"}')` calls per query, reporting min / p50 / p95 / max in ms.

    python3 -I scripts/qbench.py LIB SNAPSHOT_DIR [N] [QUERY ...]

With no queries it runs the four research-doc queries. `tests/test_query_latency.py`
imports `measure` from here.
"""

from __future__ import annotations

import ctypes
import json
import sys
import time

RESEARCH_QUERIES = [
    "benico",
    "hybrid retrieval",
    "how does the hybrid retrieval work for a search",
    "the and of to in",
]
LEXICAL = json.dumps({"retrieval_mode": "lexical"}).encode()


def load(path: str):
    lib = ctypes.CDLL(path)
    lib.ss_open.argtypes = [ctypes.c_char_p]
    lib.ss_open.restype = ctypes.c_void_p
    lib.ss_close.argtypes = [ctypes.c_void_p]
    lib.ss_close.restype = None
    lib.ss_query.argtypes = [
        ctypes.c_void_p,
        ctypes.c_char_p,
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_size_t,
        ctypes.c_char_p,
    ]
    lib.ss_query.restype = ctypes.c_void_p
    lib.ss_free.argtypes = [ctypes.c_void_p]
    lib.ss_free.restype = None
    lib.ss_last_error.restype = ctypes.c_char_p
    return lib


def measure(lib, handle, query: str, calls: int) -> dict:
    """Time `calls` lexical top-5 queries; returns milliseconds."""
    text = query.encode()
    samples = []
    for _ in range(calls):
        start = time.perf_counter()
        pointer = lib.ss_query(handle, text, None, 0, 5, LEXICAL)
        samples.append((time.perf_counter() - start) * 1000.0)
        if not pointer:
            raise RuntimeError(lib.ss_last_error().decode())
        lib.ss_free(pointer)
    samples.sort()
    return {
        "min": samples[0],
        "p50": samples[(len(samples) - 1) // 2],
        "p95": samples[(len(samples) - 1) * 95 // 100],
        "max": samples[-1],
    }


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__)
        return 2
    lib = load(argv[1])
    handle = lib.ss_open(argv[2].encode())
    if not handle:
        print("ss_open failed:", lib.ss_last_error().decode())
        return 1
    calls = int(argv[3]) if len(argv) > 3 else 200
    for query in argv[4:] or RESEARCH_QUERIES:
        m = measure(lib, handle, query, calls)
        print(f"query {query!r:55} min_ms={m['min']:.3f} p50_ms={m['p50']:.3f} p95_ms={m['p95']:.3f} max_ms={m['max']:.3f}")
    lib.ss_close(handle)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

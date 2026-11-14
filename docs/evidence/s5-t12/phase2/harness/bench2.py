#!/usr/bin/env python3
"""S5-T12 Phase 2 bench: warm `ss_query` latency per query and workload.

    python3 -I bench2.py LIB ONE_ROOT_SNAPSHOT TWO_ROOT_SNAPSHOT VARIANT ROUND OUT_JSONL

Phase 1's bench (`bench.py`: one library per process, an untimed answer
hashed, 20 warm-ups, the p50 and minimum of 300 calls, `top_k` 10, lexical)
over five workloads:

- `content` and `both` on the one-root snapshot (Phase 1's set);
- `both-all` on the two-root snapshot, every root allowed (no `roots`);
- `content-scoped` and `both-scoped` on it, `"roots": ["r-left"]` (the
  mask hides `r-right`, 9,959 of 19,959 chunks).
"""

from __future__ import annotations

import ctypes
import hashlib
import json
import sys
import time

QUERIES = [
    "bazecha",
    "benico",
    "system",
    "hashing",
    "hybrid retrieval",
    "retrieval hybrid",
    "system systems",
    "systems system",
]
WORKLOADS = [
    ("content", "one", {"search_field": "content"}),
    ("both", "one", {"search_field": "both"}),
    ("both-all", "two", {"search_field": "both"}),
    ("content-scoped", "two", {"search_field": "content", "roots": ["r-left"]}),
    ("both-scoped", "two", {"search_field": "both", "roots": ["r-left"]}),
]
TOP_K = 10
WARM = 20
CALLS = 300


def load(path: str):
    lib = ctypes.CDLL(path)
    lib.ss_open.argtypes = [ctypes.c_char_p]
    lib.ss_open.restype = ctypes.c_void_p
    lib.ss_close.argtypes = [ctypes.c_void_p]
    lib.ss_close.restype = None
    lib.ss_query.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_char_p]
    lib.ss_query.restype = ctypes.c_void_p
    lib.ss_free.argtypes = [ctypes.c_void_p]
    lib.ss_free.restype = None
    lib.ss_last_error.restype = ctypes.c_char_p
    return lib


def main(argv: list[str]) -> int:
    lib_path, one, two, variant, round_no, out_path = argv[1:7]
    lib = load(lib_path)
    handles = {}
    for name, path in (("one", one), ("two", two)):
        handles[name] = lib.ss_open(path.encode())
        if not handles[name]:
            raise SystemExit("ss_open failed: " + lib.ss_last_error().decode())
    rows = []
    for workload, snapshot, extra in WORKLOADS:
        handle = handles[snapshot]
        options = json.dumps({"retrieval_mode": "lexical", **extra}).encode()
        for query in QUERIES:
            text = query.encode()
            pointer = lib.ss_query(handle, text, None, 0, TOP_K, options)
            if not pointer:
                raise SystemExit(f"ss_query failed ({query!r}, {workload}): " + lib.ss_last_error().decode())
            answer = ctypes.string_at(pointer)
            lib.ss_free(pointer)
            parsed = json.loads(answer)
            warnings = [w.get("code") for w in parsed.get("warnings", []) if isinstance(w, dict)]
            for _ in range(WARM):
                lib.ss_free(lib.ss_query(handle, text, None, 0, TOP_K, options))
            samples = []
            for _ in range(CALLS):
                start = time.perf_counter()
                pointer = lib.ss_query(handle, text, None, 0, TOP_K, options)
                samples.append((time.perf_counter() - start) * 1000.0)
                lib.ss_free(pointer)
            samples.sort()
            rows.append({
                "variant": variant,
                "round": int(round_no),
                "field": workload,
                "query": query,
                "p50_ms": samples[(len(samples) - 1) // 2],
                "min_ms": samples[0],
                "answer_sha256": hashlib.sha256(answer).hexdigest(),
                "warnings": warnings,
            })
    for handle in handles.values():
        lib.ss_close(handle)
    with open(out_path, "a", encoding="utf-8") as out:
        for row in rows:
            out.write(json.dumps(row) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

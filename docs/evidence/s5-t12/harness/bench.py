#!/usr/bin/env python3
"""S5-T12 Phase 1 bench: warm `ss_query` latency per query and field.

    python3 -I bench.py LIB SNAPSHOT VARIANT ROUND OUT_JSONL

One library per process. One `ss_open`; for each query and field
(`content`, `both`): one untimed call whose answer is hashed (sha256 of the
returned JSON, so variants can be compared answer for answer) and whose
warnings are kept, then 20 warm-ups, then 300 timed calls; the p50 and the
minimum are written, in ms. `top_k` 10, lexical (S5-T8's method).
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
FIELDS = ["content", "both"]
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
    lib_path, snapshot, variant, round_no, out_path = argv[1:6]
    lib = load(lib_path)
    handle = lib.ss_open(snapshot.encode())
    if not handle:
        raise SystemExit("ss_open failed: " + lib.ss_last_error().decode())
    rows = []
    for field in FIELDS:
        options = json.dumps({"retrieval_mode": "lexical", "search_field": field}).encode()
        for query in QUERIES:
            text = query.encode()
            pointer = lib.ss_query(handle, text, None, 0, TOP_K, options)
            if not pointer:
                raise SystemExit(f"ss_query failed ({query!r}, {field}): " + lib.ss_last_error().decode())
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
                "field": field,
                "query": query,
                "p50_ms": samples[(len(samples) - 1) // 2],
                "min_ms": samples[0],
                "answer_sha256": hashlib.sha256(answer).hexdigest(),
                "warnings": warnings,
            })
    lib.ss_close(handle)
    with open(out_path, "a", encoding="utf-8") as out:
        for row in rows:
            out.write(json.dumps(row) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

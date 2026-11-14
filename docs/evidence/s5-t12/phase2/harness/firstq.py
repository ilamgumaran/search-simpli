#!/usr/bin/env python3
"""S5-T12: S5-T8's bound "the first `content` query after an open <= +0.10 ms"
with S5-T8's method: 15 fresh handles per query, the median of the first
query's time, `top_k` 10, lexical, `content`.
    python3 -I firstq.py LIB SNAPSHOT VARIANT ROUND SNAPSHOT_NAME OUT_JSONL"""
from __future__ import annotations
import ctypes, json, statistics, sys, time
QUERIES = ["hybrid retrieval", "system", "hashing", "opratin"]
HANDLES = 15
lib_path, snapshot, variant, round_no, snapshot_name, out = sys.argv[1:7]
lib = ctypes.CDLL(lib_path)
lib.ss_open.argtypes = [ctypes.c_char_p]; lib.ss_open.restype = ctypes.c_void_p
lib.ss_close.argtypes = [ctypes.c_void_p]; lib.ss_close.restype = None
lib.ss_query.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_char_p]
lib.ss_query.restype = ctypes.c_void_p
lib.ss_free.argtypes = [ctypes.c_void_p]
options = json.dumps({"retrieval_mode": "lexical", "search_field": "content"}).encode()
rows = []
for q in QUERIES:
    times = []
    for _ in range(HANDLES):
        h = lib.ss_open(snapshot.encode())
        if not h:
            raise SystemExit("ss_open failed")
        start = time.perf_counter()
        p = lib.ss_query(h, q.encode(), None, 0, 10, options)
        times.append((time.perf_counter() - start) * 1000.0)
        if not p:
            raise SystemExit("ss_query failed")
        lib.ss_free(p)
        lib.ss_close(h)
    rows.append({"variant": variant, "round": int(round_no), "field": "first-content-" + snapshot_name, "query": q,
                 "p50_ms": statistics.median(times), "min_ms": min(times), "answer_sha256": "", "warnings": []})
with open(out, "a", encoding="utf-8") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")

#!/usr/bin/env python3
"""S6-T4 Phase 1 bench: one library, one index, one process (ctypes).

    python3 -I bench.py queries CORPUS_DIR OUT.json
    python3 -I bench.py j2queries JUDGMENTS.json OUT.json
    python3 -I bench.py answers LIB INDEX QUERIES.json OUT.json
    python3 -I bench.py bench LIB INDEX QUERIES.json VARIANT ROUND OUT.jsonl [KNOB=VALUE ...]

`queries` derives a deterministic query set from a generated corpus: the
S5-T8/S5-T12 timing queries plus corpus words by document frequency rank
(1st, 10th, 100th, 1000th), two two-word queries, a file-name query, and
`find` phrases (three adjacent words) and prefixes. `j2queries` takes the J2
pack's queries (every request names the three roots).

`answers` runs every query under `content`, `filename` and `both` and every
`find` once and writes the sha256 of each answer (and the answers), so two
library/index pairs can be compared answer for answer.

`bench` (one library per process; KNOB=VALUE pairs are set in the
environment before `ss_open`, for the prototype's lazy decode):
  - open: 3 warm-up then 30 timed `ss_open` + `ss_close` pairs, p50 and min;
  - the first `ss_query` (the third query, content) and then the first
    `ss_find` (the first find) after an open, 11 opens, p50 and min;
  - memory: `ri_phys_footprint` (proc_pid_rusage) before `ss_open`, after it,
    after the query set (every query and field once, every find once),
    after `ss_close`;
  - warm query: per query and field, one untimed call, WARM warm-ups, CALLS
    timed calls, p50 and min (top_k 10, lexical, S5-T8's method);
  - find: per find request, WARM warm-ups, FIND_CALLS timed, p50 and min;
  - the lazy decode's counters when the library exports them.
All times in ms. Not part of any library or the build.
"""

from __future__ import annotations

import collections
import ctypes
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path

TIMING_QUERIES = ["bazecha", "benico", "system", "hashing", "hybrid retrieval",
                  "retrieval hybrid", "system systems", "systems system"]
FIELDS = ["content", "filename", "both"]
TOP_K = 10
WARM = 20
CALLS = 300
FIND_CALLS = 100
OPENS = 30
FIRSTS = 11
J2_CALLS = 30


class RusageInfoV0(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16), ("ri_user_time", ctypes.c_uint64),
                ("ri_system_time", ctypes.c_uint64), ("ri_pkg_idle_wkups", ctypes.c_uint64),
                ("ri_interrupt_wkups", ctypes.c_uint64), ("ri_pageins", ctypes.c_uint64),
                ("ri_wired_size", ctypes.c_uint64), ("ri_resident_size", ctypes.c_uint64),
                ("ri_phys_footprint", ctypes.c_uint64), ("ri_proc_start_abstime", ctypes.c_uint64),
                ("ri_proc_exit_abstime", ctypes.c_uint64)]


def footprint() -> int:
    libc = ctypes.CDLL(None)
    info = RusageInfoV0()
    if libc.proc_pid_rusage(os.getpid(), 0, ctypes.byref(info)) != 0:
        raise OSError("proc_pid_rusage failed")
    return int(info.ri_phys_footprint)


def load(path: str):
    lib = ctypes.CDLL(path)
    lib.ss_open.argtypes = [ctypes.c_char_p]
    lib.ss_open.restype = ctypes.c_void_p
    lib.ss_close.argtypes = [ctypes.c_void_p]
    lib.ss_close.restype = None
    lib.ss_query.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
                             ctypes.c_size_t, ctypes.c_char_p]
    lib.ss_query.restype = ctypes.c_void_p
    lib.ss_find.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.ss_find.restype = ctypes.c_void_p
    lib.ss_status.argtypes = [ctypes.c_void_p]
    lib.ss_status.restype = ctypes.c_void_p
    lib.ss_free.argtypes = [ctypes.c_void_p]
    lib.ss_free.restype = None
    lib.ss_last_error.restype = ctypes.c_char_p
    return lib


def lazy_stats(lib, handle) -> dict | None:
    try:
        fn = lib.ss_proto_lazy_stats
    except AttributeError:
        return None
    fn.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint64), ctypes.POINTER(ctypes.c_uint64)]
    fn.restype = None
    decodes, cached = ctypes.c_uint64(), ctypes.c_uint64()
    fn(handle, ctypes.byref(decodes), ctypes.byref(cached))
    return {"decodes": decodes.value, "cached_bytes": cached.value}


# ------------------------------------------------------------- queries ---

# Letters with their combining marks (Tamil vowel signs are category M).
WORD = re.compile(r"(?:[^\W\d_][\u0300-\u036f\u0b80-\u0bff]*)+", re.UNICODE)


def derive_queries(corpus: Path) -> dict:
    files = sorted(p for p in corpus.rglob("*") if p.is_file())
    df = collections.Counter()
    first_text = None
    for path in files:
        text = path.read_text(encoding="utf-8")
        if first_text is None:
            first_text = text
        df.update({w.lower() for w in WORD.findall(text) if len(w) >= 3})
    ranked = [w for w, _ in sorted(df.items(), key=lambda kv: (-kv[1], kv[0]))]
    pick = [ranked[i] for i in (0, 9, 99, 999) if i < len(ranked)]
    words = list(TIMING_QUERIES) + pick
    if len(pick) >= 4:
        words += [pick[0] + " " + pick[2], pick[1] + " " + pick[3]]
    stem = files[0].stem.replace("-", " ")
    words.append(stem)
    # find: three adjacent words of the first file's body; prefixes.
    body = [w for w in WORD.findall(first_text) if len(w) >= 3]
    phrases = [" ".join(body[i:i + 3]) for i in (5, 20, 40) if i + 3 <= len(body)]
    prefixes = [w[:4] + "*" for w in (pick[1], pick[2], pick[3]) if len(w) >= 5][:3] or [pick[0][:3] + "*"]
    finds = [{"query": q, "mode": "words"} for q in (pick[0], pick[2], pick[0] + " " + pick[2], stem)]
    finds += [{"query": q, "mode": "phrase"} for q in phrases]
    finds += [{"query": q, "mode": "prefix"} for q in prefixes]
    return {"corpus": corpus.name, "files": len(files), "queries": words, "finds": finds, "roots": None}


def j2_queries(judgments: Path) -> dict:
    data = json.loads(judgments.read_text(encoding="utf-8"))
    words, finds = [], []
    for q in data["queries"]:
        if q["mode"].startswith("find:"):
            finds.append({"query": q["query"], "mode": q["mode"].split(":", 1)[1]})
        else:
            words.append(q["query"])
    return {"corpus": "j2", "queries": words, "finds": finds, "roots": list(data["roots"])}


# ------------------------------------------------------------- running ---

def query_options(field: str, roots) -> bytes:
    options = {"retrieval_mode": "lexical", "search_field": field}
    if roots:
        options["roots"] = roots
    return json.dumps(options).encode()


def find_request(item: dict, roots) -> bytes:
    request = {"query": item["query"], "mode": item["mode"], "page_size": TOP_K}
    if roots:
        request["roots"] = roots
    return json.dumps(request, ensure_ascii=False).encode()


def call_query(lib, handle, text: bytes, options: bytes) -> bytes:
    pointer = lib.ss_query(handle, text, None, 0, TOP_K, options)
    if not pointer:
        raise SystemExit(f"ss_query failed ({text!r}): " + lib.ss_last_error().decode())
    answer = ctypes.string_at(pointer)
    lib.ss_free(pointer)
    return answer


def call_find(lib, handle, request: bytes) -> bytes:
    pointer = lib.ss_find(handle, request)
    if not pointer:
        raise SystemExit(f"ss_find failed ({request!r}): " + lib.ss_last_error().decode())
    answer = ctypes.string_at(pointer)
    lib.ss_free(pointer)
    return answer


def fields_for(queries: dict) -> list[str]:
    return ["content", "both"] if queries["roots"] else FIELDS


def cmd_answers(lib_path: str, index: str, queries_path: str, out_path: str) -> int:
    queries = json.loads(Path(queries_path).read_text(encoding="utf-8"))
    lib = load(lib_path)
    handle = lib.ss_open(index.encode())
    if not handle:
        raise SystemExit("ss_open failed: " + lib.ss_last_error().decode())
    roots = queries["roots"]
    rows = {}
    status = ctypes.string_at(lib.ss_status(handle))
    rows["status"] = hashlib.sha256(status).hexdigest()
    for field in fields_for(queries):
        for q in queries["queries"]:
            answer = call_query(lib, handle, q.encode(), query_options(field, roots))
            rows[f"{field}\t{q}"] = hashlib.sha256(answer).hexdigest()
    for item in queries["finds"]:
        answer = call_find(lib, handle, find_request(item, roots))
        rows[f"find:{item['mode']}\t{item['query']}"] = hashlib.sha256(answer).hexdigest()
    lib.ss_close(handle)
    Path(out_path).write_text(json.dumps({"lib": lib_path, "index": index, "status_json": status.decode(),
                                          "answers": rows}, indent=1, ensure_ascii=False), encoding="utf-8")
    print(f"answers: {len(rows)}")
    return 0


def timed(fn, warm: int, calls: int) -> tuple[float, float]:
    for _ in range(warm):
        fn()
    samples = []
    for _ in range(calls):
        start = time.perf_counter()
        fn()
        samples.append((time.perf_counter() - start) * 1000.0)
    samples.sort()
    return samples[(len(samples) - 1) // 2], samples[0]


def cmd_bench(lib_path: str, index: str, queries_path: str, variant: str, round_no: str, out_path: str,
              knobs: list[str]) -> int:
    for knob in knobs:
        key, value = knob.split("=", 1)
        os.environ[key] = value
    queries = json.loads(Path(queries_path).read_text(encoding="utf-8"))
    roots = queries["roots"]
    lib = load(lib_path)
    j2 = bool(roots)
    calls = J2_CALLS if j2 else CALLS
    find_calls = J2_CALLS if j2 else FIND_CALLS
    row = {"variant": variant, "round": int(round_no), "index": index, "knobs": knobs,
           "load_before": [round(x, 2) for x in os.getloadavg()]}

    # Memory first, in a process that has not opened the index yet.
    before = footprint()
    handle = lib.ss_open(index.encode())
    if not handle:
        raise SystemExit("ss_open failed: " + lib.ss_last_error().decode())
    after_open = footprint()
    row["lazy_after_open"] = lazy_stats(lib, handle)
    for field in fields_for(queries):
        for q in queries["queries"]:
            call_query(lib, handle, q.encode(), query_options(field, roots))
    for item in queries["finds"]:
        call_find(lib, handle, find_request(item, roots))
    after_queries = footprint()
    row["lazy_after_queries"] = lazy_stats(lib, handle)
    lib.ss_close(handle)
    after_close = footprint()
    row["memory"] = {"before": before, "open_delta": after_open - before, "queries_delta": after_queries - before,
                     "close_delta": after_close - before}

    # Open time (file cache warm).
    def open_close():
        h = lib.ss_open(index.encode())
        if not h:
            raise SystemExit("ss_open failed: " + lib.ss_last_error().decode())
        lib.ss_close(h)
    p50, low = timed(open_close, 3, OPENS)
    row["open"] = {"p50_ms": p50, "min_ms": low}

    # The first query and the first find after an open (what a lazy open
    # defers: statistics, position checks, list decodes), FIRSTS opens.
    first_q, first_f = [], []
    first_text = queries["queries"][2].encode()
    first_options = query_options("content", roots)
    first_find = find_request(queries["finds"][0], roots)
    for _ in range(FIRSTS):
        h = lib.ss_open(index.encode())
        start = time.perf_counter()
        lib.ss_free(lib.ss_query(h, first_text, None, 0, TOP_K, first_options))
        first_q.append((time.perf_counter() - start) * 1000.0)
        start = time.perf_counter()
        lib.ss_free(lib.ss_find(h, first_find))
        first_f.append((time.perf_counter() - start) * 1000.0)
        lib.ss_close(h)
    first_q.sort()
    first_f.sort()
    row["first_query"] = {"query": queries["queries"][2], "p50_ms": first_q[(FIRSTS - 1) // 2], "min_ms": first_q[0]}
    row["first_find"] = {"find": queries["finds"][0], "p50_ms": first_f[(FIRSTS - 1) // 2], "min_ms": first_f[0]}

    handle = lib.ss_open(index.encode())
    warm = []
    for field in fields_for(queries):
        options = query_options(field, roots)
        for q in queries["queries"]:
            text = q.encode()
            answer = call_query(lib, handle, text, options)
            p50, low = timed(lambda: lib.ss_free(lib.ss_query(handle, text, None, 0, TOP_K, options)), WARM, calls)
            warm.append({"field": field, "query": q, "p50_ms": p50, "min_ms": low,
                         "answer_sha256": hashlib.sha256(answer).hexdigest()})
    finds = []
    for item in queries["finds"]:
        request = find_request(item, roots)
        answer = call_find(lib, handle, request)
        p50, low = timed(lambda: lib.ss_free(lib.ss_find(handle, request)), WARM if not j2 else 5, find_calls)
        finds.append({"mode": item["mode"], "query": item["query"], "p50_ms": p50, "min_ms": low,
                      "answer_sha256": hashlib.sha256(answer).hexdigest()})
    row["lazy_end"] = lazy_stats(lib, handle)
    lib.ss_close(handle)
    row["warm"] = warm
    row["find"] = finds
    row["load_after"] = [round(x, 2) for x in os.getloadavg()]
    with open(out_path, "a", encoding="utf-8") as out:
        out.write(json.dumps(row, ensure_ascii=False) + "\n")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        raise SystemExit(__doc__)
    cmd = argv[1]
    if cmd == "queries":
        Path(argv[3]).write_text(json.dumps(derive_queries(Path(argv[2])), indent=1, ensure_ascii=False),
                                 encoding="utf-8")
        return 0
    if cmd == "j2queries":
        Path(argv[3]).write_text(json.dumps(j2_queries(Path(argv[2])), indent=1, ensure_ascii=False),
                                 encoding="utf-8")
        return 0
    if cmd == "answers":
        return cmd_answers(*argv[2:6])
    if cmd == "bench":
        return cmd_bench(*argv[2:8], argv[8:])
    raise SystemExit(__doc__)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

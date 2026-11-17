#!/usr/bin/env python3
"""S6-T4 Phase 2, ruling 3: every answer, one library and one index (ctypes).

    python3 -I same_answers.py answers LIB INDEX QUERIES.json OUT.jsonl
    python3 -I same_answers.py compare A.jsonl B.jsonl

`answers` opens INDEX with LIB once and writes one JSON line per answer, in
a fixed order: `ss_status`; `ss_roots`; every `ss_list_files` page (1000 a
page, all of them); every query of QUERIES.json (`bench.py queries` /
`j2queries`) under `content`, `filename` and `both` (top_k 10, lexical, the
pack's roots), and `ss_evidence` for the ids each query returned; every
`find` request (page 1, then page 2 by its cursor when there is one); and
`ss_outline` plus `ss_read_span` (lines 1-40) of every listed file. An
answer is the library's JSON, or for a refusal `ERROR: <ss_last_error>`
(so equal refusals compare equal and are counted apart).

`compare` reads two such files and reports, per kind, how many answers
there are, how many differ and how many are refusals; exit 1 on any
difference or a different count. Not part of any library or the build.
"""

from __future__ import annotations

import collections
import ctypes
import json
import sys
from pathlib import Path

FIELDS = ["content", "filename", "both"]
TOP_K = 10
LIST_PAGE = 1000
READ_LINES = 40


def load(path: str):
    lib = ctypes.CDLL(path)
    lib.ss_open.argtypes = [ctypes.c_char_p]
    lib.ss_open.restype = ctypes.c_void_p
    lib.ss_close.argtypes = [ctypes.c_void_p]
    lib.ss_close.restype = None
    lib.ss_query.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
                             ctypes.c_size_t, ctypes.c_char_p]
    lib.ss_query.restype = ctypes.c_void_p
    for name in ("ss_find", "ss_outline", "ss_read_span", "ss_list_files", "ss_roots", "ss_evidence"):
        fn = getattr(lib, name)
        fn.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        fn.restype = ctypes.c_void_p
    lib.ss_status.argtypes = [ctypes.c_void_p]
    lib.ss_status.restype = ctypes.c_void_p
    lib.ss_free.argtypes = [ctypes.c_void_p]
    lib.ss_free.restype = None
    lib.ss_last_error.restype = ctypes.c_char_p
    return lib


def take(lib, pointer) -> str:
    if not pointer:
        return "ERROR: " + lib.ss_last_error().decode("utf-8", "replace")
    answer = ctypes.string_at(pointer).decode("utf-8")
    lib.ss_free(pointer)
    return answer


def dumps(value) -> bytes:
    return json.dumps(value, ensure_ascii=False).encode()


def cmd_answers(lib_path: str, index: str, queries_path: str, out_path: str) -> int:
    queries = json.loads(Path(queries_path).read_text(encoding="utf-8"))
    roots = queries.get("roots")
    lib = load(lib_path)
    handle = lib.ss_open(index.encode())
    if not handle:
        raise SystemExit("ss_open failed: " + lib.ss_last_error().decode())
    rows: list[tuple[str, str, str]] = []

    def call(kind: str, key: str, fn, *args) -> str:
        answer = take(lib, fn(handle, *args))
        rows.append((kind, key, answer))
        return answer

    call("status", "", lib.ss_status)
    call("roots", "", lib.ss_roots, b"{}")
    files: list[tuple[str, str]] = []
    cursor = None
    page = 0
    while True:
        request = {"page_size": LIST_PAGE}
        if cursor:
            request["cursor"] = cursor
        answer = call("list_files", str(page), lib.ss_list_files, dumps(request))
        if answer.startswith("ERROR"):
            break
        value = json.loads(answer)
        files += [(f["root_id"], f["path"]) for f in value["files"]]
        cursor = value.get("next_cursor")
        page += 1
        if not cursor:
            break
    for field in FIELDS:
        options = {"retrieval_mode": "lexical", "search_field": field}
        if roots:
            options["roots"] = roots
        for q in queries["queries"]:
            pointer = lib.ss_query(handle, q.encode(), None, 0, TOP_K, dumps(options))
            answer = take(lib, pointer)
            rows.append(("query", f"{field}\t{q}", answer))
            if answer.startswith("ERROR"):
                continue
            ids = [r["chunk_id"] for r in json.loads(answer).get("results", []) if "chunk_id" in r]
            if ids:
                call("evidence", f"{field}\t{q}", lib.ss_evidence, dumps({"ids": ids}))
    for item in queries["finds"]:
        request = {"query": item["query"], "mode": item["mode"], "page_size": TOP_K}
        if roots:
            request["roots"] = roots
        answer = call("find", f"{item['mode']}\t{item['query']}", lib.ss_find, dumps(request))
        if not answer.startswith("ERROR") and json.loads(answer).get("next_cursor"):
            request["cursor"] = json.loads(answer)["next_cursor"]
            call("find", f"{item['mode']}\t{item['query']}\tpage 2", lib.ss_find, dumps(request))
    for root_id, path in files:
        target = {"root_id": root_id, "path": path}
        call("outline", f"{root_id}\t{path}", lib.ss_outline, dumps(target))
        call("read_span", f"{root_id}\t{path}", lib.ss_read_span,
             dumps({**target, "start_line": 1, "end_line": READ_LINES}))
    lib.ss_close(handle)
    with open(out_path, "w", encoding="utf-8") as out:
        for kind, key, answer in rows:
            out.write(json.dumps({"kind": kind, "key": key, "answer": answer}, ensure_ascii=False) + "\n")
    print(f"answers: {len(rows)} ({len(files)} files)")
    return 0


def read_rows(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f]


def cmd_compare(a_path: str, b_path: str) -> int:
    a, b = read_rows(a_path), read_rows(b_path)
    counts = collections.Counter()
    differ = collections.Counter()
    refused = collections.Counter()
    bad = len(a) != len(b)
    for x, y in zip(a, b):
        kind = x["kind"]
        counts[kind] += 1
        if (x["kind"], x["key"]) != (y["kind"], y["key"]) or x["answer"] != y["answer"]:
            differ[kind] += 1
            if differ[kind] <= 3:
                print(f"DIFFERS {kind} {x['key']!r}", file=sys.stderr)
            bad = True
        elif x["answer"].startswith("ERROR"):
            refused[kind] += 1
    summary = ", ".join(f"{k} {counts[k]} (differ {differ[k]}, refused {refused[k]})" for k in sorted(counts))
    print(f"{'DIFFER' if bad else 'same'}: {len(a)} vs {len(b)} answers: {summary}")
    return 1 if bad else 0


def main(argv: list[str]) -> int:
    if len(argv) >= 6 and argv[1] == "answers":
        return cmd_answers(*argv[2:6])
    if len(argv) == 4 and argv[1] == "compare":
        return cmd_compare(argv[2], argv[3])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

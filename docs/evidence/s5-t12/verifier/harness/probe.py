#!/usr/bin/env python3
"""Untimed probe: warnings and top paths per query and field.
    python3 -I probe.py LIB SNAPSHOT FIELD [ROOTS_JSON] -- QUERY...
"""
import ctypes, json, sys

lib_path, snap, field = sys.argv[1:4]
rest = sys.argv[4:]
roots = None
if rest and rest[0] != "--":
    roots = json.loads(rest[0]); rest = rest[1:]
queries = rest[1:]
lib = ctypes.CDLL(lib_path)
lib.ss_open.argtypes = [ctypes.c_char_p]; lib.ss_open.restype = ctypes.c_void_p
lib.ss_query.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_char_p]
lib.ss_query.restype = ctypes.c_void_p
lib.ss_free.argtypes = [ctypes.c_void_p]
h = lib.ss_open(snap.encode())
opts = {"retrieval_mode": "lexical", "search_field": field}
if roots is not None: opts["roots"] = roots
for q in queries:
    p = lib.ss_query(h, q.encode(), None, 0, 10, json.dumps(opts).encode())
    a = json.loads(ctypes.string_at(p)); lib.ss_free(p)
    w = [{k: v for k, v in x.items() if k in ("code", "term", "members", "expansions")} for x in a.get("warnings", [])]
    hits = a.get("results") or a.get("hits") or []
    print(q, "|", field, "| hits", len(hits), "|", json.dumps(w)[:300])

#!/usr/bin/env python3
"""S6-T7 verifier: probe.py LIB IDX -> one JSON line of hashed answers (generation kept, so old and new differ)."""
import ctypes
import hashlib
import json
import sys

lib = ctypes.CDLL(sys.argv[1])
lib.ss_open.restype = ctypes.c_void_p
lib.ss_open.argtypes = [ctypes.c_char_p]
lib.ss_last_error.restype = ctypes.c_char_p
lib.ss_free.argtypes = [ctypes.c_void_p]
lib.ss_close.argtypes = [ctypes.c_void_p]
lib.ss_status.restype = ctypes.c_void_p
lib.ss_status.argtypes = [ctypes.c_void_p]
for n in ("ss_read_span", "ss_list_files", "ss_outline"):
    getattr(lib, n).restype = ctypes.c_void_p
    getattr(lib, n).argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lib.ss_query.restype = ctypes.c_void_p
lib.ss_query.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_char_p]
h = lib.ss_open(sys.argv[2].encode())
if not h:
    print(json.dumps({"open": (lib.ss_last_error() or b"").decode()}))
    sys.exit(0)


def take(p):
    if not p:
        return "ERR " + (lib.ss_last_error() or b"").decode()
    s = ctypes.string_at(p)
    lib.ss_free(p)
    return s.decode()


res = {"open": "ok", "status": take(lib.ss_status(h)), "query": take(lib.ss_query(h, b"pottery clay week killed", None, 0, 20, b"{}"))}
pages = []
cur = None
while True:
    req = {"page_size": 5000}
    if cur:
        req["cursor"] = cur
    p = lib.ss_list_files(h, json.dumps(req).encode())
    if not p:
        res["list"] = "ERR " + (lib.ss_last_error() or b"").decode()
        break
    j = json.loads(ctypes.string_at(p))
    lib.ss_free(p)
    pages.append(len(j.get("files", [])))
    cur = j.get("next_cursor")
    if not cur:
        res["list"] = pages
        break
first = None
for path in ("zz-killed-note.md",):
    res["read_new"] = take(lib.ss_read_span(h, json.dumps({"root_id": "r-legacy", "path": path, "start_line": 1, "end_line": 50}).encode()))
p = lib.ss_list_files(h, json.dumps({"page_size": 3}).encode())
files = json.loads(ctypes.string_at(p))["files"]
lib.ss_free(p)
for i, f in enumerate(files):
    res[f"read{i}"] = take(lib.ss_read_span(h, json.dumps({"root_id": f["root_id"], "path": f["path"], "start_line": 1, "end_line": 100000}).encode()))
    res[f"outline{i}"] = take(lib.ss_outline(h, json.dumps({"root_id": f["root_id"], "path": f["path"]}).encode()))
lib.ss_close(h)
print(json.dumps(res))

#!/usr/bin/env python3
"""S6-T7 verifier: one library on one (damaged) index through the C ABI; prints one JSON line.

    check.py LIB IDX CORPUS CORPORA FIXTURES

open; one query; then for every file on disk: outline and a whole-file read_span (1..1000000). Each answer is
classified: refused (and the error text), or returned (and whether the returned text equals the file's bytes after
any BOM). A wrong byte returned is `returned_wrong`. The caller runs this in a subprocess (a crash is its exit status).
"""
import ctypes
import json
import sys
from collections import Counter
from pathlib import Path

lib_path, idx, corpus, corpora, fixtures = sys.argv[1:6]
corpora, fixtures = Path(corpora), Path(fixtures)
lib = ctypes.CDLL(lib_path)
lib.ss_open.restype = ctypes.c_void_p
lib.ss_open.argtypes = [ctypes.c_char_p]
lib.ss_close.argtypes = [ctypes.c_void_p]
lib.ss_last_error.restype = ctypes.c_char_p
lib.ss_free.argtypes = [ctypes.c_void_p]
for name in ("ss_outline", "ss_read_span", "ss_find"):
    getattr(lib, name).restype = ctypes.c_void_p
    getattr(lib, name).argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lib.ss_query.restype = ctypes.c_void_p
lib.ss_query.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_char_p]


def disk_files():
    if corpus == "edge":
        base = corpora / "edge"
        return [("r-legacy", p.relative_to(base).as_posix(), p) for p in sorted(base.rglob("*")) if p.is_file()]
    res = []
    for root in ("school", "home", "laptop"):
        base = fixtures / "j2" / root
        res += [(root, p.relative_to(base).as_posix(), p) for p in sorted(base.rglob("*")) if p.is_file()]
    return res


out = {"open": None}
h = lib.ss_open(idx.encode())
if not h:
    out["open"] = "refused: " + (lib.ss_last_error() or b"").decode("utf-8", "replace")
    print(json.dumps(out))
    sys.exit(0)
out["open"] = "ok"


def call(fn, req):
    p = fn(h, json.dumps(req).encode())
    if not p:
        return None, (lib.ss_last_error() or b"").decode("utf-8", "replace")
    s = ctypes.string_at(p)
    lib.ss_free(p)
    return json.loads(s), None


q = lib.ss_query(h, b"week", None, 0, 10, b"{}")
if q:
    lib.ss_free(q)
    out["query"] = "ok"
else:
    out["query"] = "refused: " + (lib.ss_last_error() or b"").decode()
res = Counter()
errors = Counter()
wrong = []
for root, rel, p in disk_files():
    data = p.read_bytes()
    body = data[3:] if data.startswith(b"\xef\xbb\xbf") else data
    base = {"root_id": root, "path": rel}
    r, e = call(lib.ss_outline, base)
    if e:
        res["outline_refused"] += 1
        errors[e] += 1
    else:
        res["outline_ok"] += 1
    r, e = call(lib.ss_read_span, dict(base, start_line=1, end_line=1000000))
    if e:
        res["read_refused"] += 1
        errors[e] += 1
    else:
        got = r["text"].encode("utf-8")
        if got == body:
            res["read_equal"] += 1
        else:
            res["read_returned_wrong"] += 1
            wrong.append(f"{root}/{rel}")
lib.ss_close(h)
out.update(res)
out["errors"] = dict(errors.most_common(6))
out["wrong"] = wrong[:5]
print(json.dumps(out))

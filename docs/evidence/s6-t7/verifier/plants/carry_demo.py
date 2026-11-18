#!/usr/bin/env python3
"""S6-T7 verifier: an update after a same-length edit inside a chunk, written by WRITER_LIB over a head-written index;
every file then read whole with the head library.   carry_demo.py WRITER_LIB HEAD_LIB WORKDIR TAG"""
import ctypes, json, shutil, sys
from collections import Counter
from pathlib import Path
wl, hl, work, tag = sys.argv[1], sys.argv[2], Path(sys.argv[3]), sys.argv[4]
folder = work / f"folder-{tag}"
shutil.copytree(work / "folder", folder)
out = work / f"idx-{tag}"
def lib(p):
    l = ctypes.CDLL(p)
    l.ss_index_folder.restype = ctypes.c_void_p; l.ss_index_folder.argtypes = [ctypes.c_char_p] * 3
    l.ss_open.restype = ctypes.c_void_p; l.ss_open.argtypes = [ctypes.c_char_p]
    l.ss_read_span.restype = ctypes.c_void_p; l.ss_read_span.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    l.ss_last_error.restype = ctypes.c_char_p; l.ss_free.argtypes = [ctypes.c_void_p]
    return l
H, W = lib(hl), lib(wl)
assert H.ss_index_folder(str(out).encode(), str(folder).encode(), b'{"filename_index":true}')
# a same-length edit: the first lowercase 'e' after byte 40 of the first .md file with > 200 bytes becomes 'a'
target = next(f for f in sorted(folder.rglob("*.md")) if f.stat().st_size > 200)
b = bytearray(target.read_bytes()); i = b.index(b"e", 40); b[i] = ord("a"); target.write_bytes(bytes(b))
r = W.ss_index_folder(str(out).encode(), str(folder).encode(), b'{"filename_index":true,"update":true}')
print("update:", json.loads(ctypes.string_at(r)).get("generation") if r else W.ss_last_error())
h = H.ss_open(str(out).encode())
c, errs = Counter(), Counter()
for f in sorted(x for x in folder.rglob("*") if x.is_file()):
    data = f.read_bytes(); n = len(data.splitlines())
    if n == 0: continue
    got = []
    for a in range(1, n + 1, 400):
        q = H.ss_read_span(h, json.dumps({"root_id": "r-legacy", "path": f.relative_to(folder).as_posix(), "start_line": a, "end_line": a + 399}).encode())
        if not q: errs[H.ss_last_error().decode()[:110]] += 1; got = None; break
        got.append(json.loads(ctypes.string_at(q))["text"].encode()); H.ss_free(q)
    c["refused" if got is None else "equal" if b"".join(got) == (data[3:] if data.startswith(b"\xef\xbb\xbf") else data) else "WRONG"] += 1
print(tag, "edited", target.relative_to(folder).as_posix(), dict(c), dict(errs))

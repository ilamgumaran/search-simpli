#!/usr/bin/env python3
"""S6-T7 verifier: index FOLDER with a (planted) writer library through ss_index_folder, then read every file whole
(400-line pieces) with the head library; count equal, refused and wrong.
    writer_demo.py WRITER_LIB READER_LIB FOLDER OUT"""
import ctypes, json, sys
from collections import Counter
from pathlib import Path
w = ctypes.CDLL(sys.argv[1])
w.ss_index_folder.restype = ctypes.c_void_p
w.ss_index_folder.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]
w.ss_last_error.restype = ctypes.c_char_p
folder, out = Path(sys.argv[3]), sys.argv[4]
p = w.ss_index_folder(out.encode(), str(folder).encode(), b'{"filename_index":true}')
if not p:
    print("index refused:", w.ss_last_error()); sys.exit(1)
r = ctypes.CDLL(sys.argv[2])
r.ss_open.restype = ctypes.c_void_p; r.ss_open.argtypes = [ctypes.c_char_p]
r.ss_read_span.restype = ctypes.c_void_p; r.ss_read_span.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
r.ss_last_error.restype = ctypes.c_char_p; r.ss_free.argtypes = [ctypes.c_void_p]
h = r.ss_open(out.encode())
c, errs = Counter(), Counter()
for f in sorted(x for x in folder.rglob("*") if x.is_file()):
    data = f.read_bytes(); body = data[3:] if data.startswith(b"\xef\xbb\xbf") else data
    n = len(data.splitlines()) if data else 0
    if n == 0:
        continue
    got = []
    for a in range(1, n + 1, 400):
        q = r.ss_read_span(h, json.dumps({"root_id": "r-legacy", "path": f.relative_to(folder).as_posix(), "start_line": a, "end_line": a + 399}).encode())
        if not q:
            e = r.ss_last_error().decode(); errs[e[:110]] += 1; got = None; break
        got.append(json.loads(ctypes.string_at(q))["text"].encode()); r.ss_free(q)
    if got is None:
        c["refused"] += 1
    elif b"".join(got) == body:
        c["equal"] += 1
    else:
        c["WRONG"] += 1
print(dict(c), dict(errs.most_common(3)))

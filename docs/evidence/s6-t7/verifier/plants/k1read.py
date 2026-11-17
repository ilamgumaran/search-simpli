import ctypes, json, sys, hashlib
from pathlib import Path
lib = ctypes.CDLL(sys.argv[1])
lib.ss_open.restype = ctypes.c_void_p; lib.ss_open.argtypes = [ctypes.c_char_p]
for n in ("ss_read_span", "ss_outline"):
    getattr(lib, n).restype = ctypes.c_void_p; getattr(lib, n).argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lib.ss_last_error.restype = ctypes.c_char_p; lib.ss_free.argtypes = [ctypes.c_void_p]
h = lib.ss_open(sys.argv[2].encode())
H = hashlib.sha256()
for f in sorted(Path(sys.argv[3]).iterdir()):
    data = f.read_bytes(); n = data.count(b"\n"); got = []
    for a in range(1, n + 1, 400):
        p = lib.ss_read_span(h, json.dumps({"root_id": "r-legacy", "path": f.name, "start_line": a, "end_line": a + 399}).encode())
        s = ctypes.string_at(p); lib.ss_free(p); H.update(s); got.append(json.loads(s)["text"].encode())
    p = lib.ss_outline(h, json.dumps({"root_id": "r-legacy", "path": f.name}).encode()); H.update(ctypes.string_at(p)); lib.ss_free(p)
    print(f.name, "equal" if b"".join(got) == data else "WRONG", end="; ")
print(sys.argv[1].split("/")[-2], H.hexdigest()[:16])

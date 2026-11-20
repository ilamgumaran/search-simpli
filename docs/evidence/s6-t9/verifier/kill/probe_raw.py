"""S6-T9 verifier: the answers the kill sweep compares, raw. probe_raw.py LIB IDX -> JSON {name: answer}
status, a content query, a file-name query and a `both` query (the catalog v6 read), list_files (first page), a find,
read_span of three files (path order: first, 5000th, last)."""
import ctypes, json, sys
lib = ctypes.CDLL(sys.argv[1]); idx = sys.argv[2]
V = ctypes.c_void_p
lib.ss_open.restype = V; lib.ss_open.argtypes = [ctypes.c_char_p]; lib.ss_close.argtypes = [V]
lib.ss_last_error.restype = ctypes.c_char_p; lib.ss_free.argtypes = [V]
for f in ("ss_status",):
    getattr(lib, f).restype = V; getattr(lib, f).argtypes = [V]
for f in ("ss_list_files", "ss_read_span", "ss_find"):
    getattr(lib, f).restype = V; getattr(lib, f).argtypes = [V, ctypes.c_char_p]
lib.ss_query.restype = V
lib.ss_query.argtypes = [V, ctypes.c_char_p, V, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_char_p]
h = lib.ss_open(idx.encode())
if not h:
    print("open failed", lib.ss_last_error()); sys.exit(2)
def take(p):
    if not p:
        return "ERR " + (lib.ss_last_error() or b"").decode()
    s = ctypes.string_at(p).decode(); lib.ss_free(p); return s
out = {"status": take(lib.ss_status(h))}
for field in ("content", "filename", "both"):
    out[f"q_{field}"] = take(lib.ss_query(h, b"pottery doc", None, 0, 8, json.dumps({"retrieval_mode": "lexical", "search_field": field}).encode()))
lf = take(lib.ss_list_files(h, b'{"page_size": 50}'))
out["list_files"] = lf
out["find"] = take(lib.ss_find(h, b'{"query": "killed publish", "mode": "phrase", "page_size": 5}'))
paths = sorted(f["path"] for f in json.loads(lf).get("files", []))
for i, p in enumerate(["group-00/doc-00000.md", "group-05/doc-05000.md", "group-99/doc-09999.md", "zz-killed-note.md"]):
    out[f"span{i}"] = take(lib.ss_read_span(h, json.dumps({"root_id": "r-legacy", "path": p, "start_line": 1, "end_line": 40}).encode()))
lib.ss_close(h)
print(json.dumps(out))

"""S6-T8 verifier: run the find query set through ss_find of one library on one index, every page.
find_dump.py LIB IDX QUERIES.json OUT.jsonl
One line per call: [request, sha256 of the normalised answer or error]. Counts hits and highlight offsets."""
import ctypes, hashlib, json, re, sys
lib_path, idx, qfile, out_path = sys.argv[1:5]
cplen_idx = sys.argv[5] if len(sys.argv) > 5 else idx  # S6-T9 verifier: an index of the same corpus with documents v5 (for an older-format index)
lib = ctypes.CDLL(lib_path)
lib.ss_open.restype = ctypes.c_void_p
lib.ss_open.argtypes = [ctypes.c_char_p]
lib.ss_close.argtypes = [ctypes.c_void_p]
lib.ss_last_error.restype = ctypes.c_char_p
lib.ss_free.argtypes = [ctypes.c_void_p]
lib.ss_find.restype = ctypes.c_void_p
lib.ss_find.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent.parent / "dec"))
import v5dec, pathlib
_d = v5dec.decode_documents((pathlib.Path(cplen_idx) / __import__("re").search(rb"documents-\d+\.hybseg", (pathlib.Path(cplen_idx) / "MANIFEST").read_bytes()).group(0).decode()).read_bytes(), True, check_checksum=False)
CPLEN = {r["id"].decode(): len(r["text"].decode("utf-8")) for r in _d["records"]}
h = lib.ss_open(idx.encode())
if not h:
    print("open failed:", lib.ss_last_error()); sys.exit(2)
GEN = re.compile(rb'"generation":\d+')
CUR = re.compile(rb'"(next_cursor|cursor)":"\d+:')
def norm(b):
    return CUR.sub(lambda m: b'"' + m.group(1) + b'":"G:', GEN.sub(b'"generation":G', b))
qs = json.load(open(qfile))["queries"]
st = {"calls": 0, "errors": 0, "hits": 0, "offsets": 0, "offset_outside_content": 0}
out = open(out_path, "w")
def walk(o):
    if isinstance(o, dict):
        if "match_offsets" in o:
            yield o
        for v in o.values():
            yield from walk(v)
    elif isinstance(o, list):
        for v in o:
            yield from walk(v)
for q in qs:
    cur = None
    ps = 100 if q["kind"] == "frequent" else 20
    for page in range(q["pages"]):
        req = {"query": q["query"], "mode": q["mode"], "page_size": ps}
        if cur:
            req["cursor"] = cur
        p = lib.ss_find(h, json.dumps(req).encode())
        st["calls"] += 1
        if not p:
            st["errors"] += 1
            out.write(json.dumps([q["kind"], {k: v for k, v in req.items() if k != "cursor"}, page, "ERR " + (lib.ss_last_error() or b"").decode()], ensure_ascii=False) + "\n")
            break
        s = ctypes.string_at(p); lib.ss_free(p)
        r = json.loads(s)
        for hit in walk(r):
            st["hits"] += 1
            n = CPLEN[hit["chunk_id"]]
            for a, b in hit["match_offsets"]:
                st["offsets"] += 1
                if not (0 <= a < b <= n):
                    st["offset_outside_content"] += 1
        out.write(json.dumps([q["kind"], {k: v for k, v in req.items() if k != "cursor"}, page, hashlib.sha256(norm(s)).hexdigest()], ensure_ascii=False) + "\n")
        cur = r.get("next_cursor")
        if not cur:
            break
lib.ss_close(h)
print(json.dumps(st))

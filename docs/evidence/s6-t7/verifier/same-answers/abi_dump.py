"""S6-T7 verifier: dump every C ABI answer of one library on one index, with the verifier's own
request set. One JSON line per call: [request-kind, request, sha256 of the answer or the error].
Whole-file read_span pieces are also joined and compared with the corpus bytes on disk.

Usage: abi_dump.py LIB IDX CORPUS CORPORA_ROOT FIXTURES_ROOT OUT [--full]
--full writes the answers themselves instead of their sha256 (small corpora only).
The query/request set is derived from the corpus files on disk (not from the index).
"""
import ctypes
import hashlib
import json
import random
import re
import sys
from pathlib import Path

lib_path, idx, corpus, corpora, fixtures, out_path = sys.argv[1:7]
full = "--full" in sys.argv
corpora, fixtures = Path(corpora), Path(fixtures)
lib = ctypes.CDLL(lib_path)
lib.ss_open.restype = ctypes.c_void_p
lib.ss_open.argtypes = [ctypes.c_char_p]
lib.ss_close.argtypes = [ctypes.c_void_p]
lib.ss_last_error.restype = ctypes.c_char_p
lib.ss_free.argtypes = [ctypes.c_void_p]
for name in ("ss_status",):
    getattr(lib, name).restype = ctypes.c_void_p
    getattr(lib, name).argtypes = [ctypes.c_void_p]
for name in ("ss_find", "ss_outline", "ss_read_span", "ss_list_files", "ss_roots", "ss_evidence"):
    getattr(lib, name).restype = ctypes.c_void_p
    getattr(lib, name).argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lib.ss_query.restype = ctypes.c_void_p
lib.ss_query.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t,
                         ctypes.c_char_p]

h = lib.ss_open(idx.encode())
if not h:
    print("open failed:", lib.ss_last_error())
    sys.exit(2)

GEN = re.compile(rb'"generation":\d+')
CUR = re.compile(rb'"(next_cursor|cursor)":"\d+:')


def norm(b):
    b = GEN.sub(b'"generation":G', b)
    return CUR.sub(lambda m: b'"' + m.group(1) + b'":"G:', b)


out = open(out_path, "w")
stats = {"calls": 0, "errors": 0, "whole_files": 0, "whole_mismatch": 0, "whole_skipped_capacity": 0}


def emit(kind, req, ptr):
    stats["calls"] += 1
    if ptr:
        s = ctypes.string_at(ptr)
        lib.ss_free(ptr)
        ans = norm(s)
        ok = True
    else:
        ans = b"ERR " + (lib.ss_last_error() or b"")
        stats["errors"] += 1
        ok = False
    val = ans.decode("utf-8", "replace") if full else hashlib.sha256(ans).hexdigest()
    out.write(json.dumps([kind, req, val], ensure_ascii=False) + "\n")
    return json.loads(s) if ok else None


def call(kind, fn, req):
    return emit(kind, req, fn(h, json.dumps(req).encode()))


# ---- the corpus on disk: (root_id, rel, disk path)
def disk_files():
    if corpus in ("timing-10k", "prose-10k", "tamil-10k", "edge"):
        base = corpora / corpus
        return [("r-legacy", p.relative_to(base).as_posix(), p) for p in sorted(base.rglob("*")) if p.is_file()]
    if corpus in ("fixtures", "family"):
        base = fixtures if corpus == "fixtures" else fixtures / "family-folder"
        return [("r-legacy", p.relative_to(base).as_posix(), p) for p in sorted(base.rglob("*")) if p.is_file()]
    res = []
    for root in ("school", "home", "laptop"):
        base = fixtures / "j2" / root
        res += [(root, p.relative_to(base).as_posix(), p) for p in sorted(base.rglob("*")) if p.is_file()]
    return res


files = disk_files()
rng = random.Random(7177)

# ---- status, roots, list_files (every page, two page sizes), path_prefix, pending
emit("status", None, lib.ss_status(h))
call("roots", lib.ss_roots, {})
for ps in (1000, 7):
    cur = None
    pages = 0
    while True:
        req = {"page_size": ps}
        if cur:
            req["cursor"] = cur
        r = call("list_files", lib.ss_list_files, req)
        pages += 1
        if not r or not r.get("next_cursor") or (ps == 7 and pages >= 40):
            break
        cur = r["next_cursor"]
call("list_files", lib.ss_list_files, {"status": "pending"})
call("list_files", lib.ss_list_files, {"path_prefix": files[0][1][:3], "root_id": files[0][0]})
call("list_files", lib.ss_list_files, {"status": "bogus"})

# ---- queries: words sampled from the corpus bytes on disk (seeded), pairs, triples, fixed ones
sample = rng.sample(files, min(40, len(files)))
words = []
for _, _, p in sample:
    toks = re.findall(r"\w{3,}", p.read_bytes().decode("utf-8", "replace"))
    if toks:
        words.append(rng.choice(toks))
stems = [Path(rel).stem for _, rel, _ in sample[:6]]
queries = words[:20] + [" ".join(words[i:i + 2]) for i in range(0, 12, 2)] + [" ".join(words[20:23])]
queries += stems + ["பள்ளி", "வீட்டுப்பாடம் நாளை", "the", "", "!!! ...", "zzqqxxnotaword", "ab"]
roots_opt = [None] if corpus != "j2" else [None, ["school"], ["home", "laptop"]]
for q in queries:
    for field in ("content", "filename", "both"):
        for top_k in (10, 100):
            for roots in roots_opt:
                opts = {"retrieval_mode": "lexical", "search_field": field}
                if roots:
                    opts["roots"] = roots
                r = emit("query", [q, top_k, opts], lib.ss_query(h, q.encode(), None, 0, top_k, json.dumps(opts).encode()))
                if r and field == "content" and top_k == 10 and roots is None and r.get("results"):
                    ids = [x["chunk_id"] for x in r["results"][:5]]
                    call("evidence", lib.ss_evidence, {"ids": ids + ["nope"]})
    emit("query-hybrid", q, lib.ss_query(h, q.encode(), None, 0, 5, None))
    emit("query-prefix", q, lib.ss_query(h, q.encode(), None, 0, 5, json.dumps(
        {"retrieval_mode": "lexical", "path_prefix": files[0][1][:2]}).encode()))

# ---- find: words, phrase, prefix, pages and cursors
for q in words[:12] + [f'"{words[0]} {words[1]}"', words[2][:3] + "*", " ".join(words[3:5]), "பள்ளி", "the"]:
    for mode in ("words", "phrase", "prefix"):
        cur = None
        for page in range(3):
            req = {"query": q, "mode": mode, "page_size": 5}
            if cur:
                req["cursor"] = cur
            r = call("find", lib.ss_find, req)
            if not r or not r.get("next_cursor"):
                break
            cur = r["next_cursor"]
call("find", lib.ss_find, {"query": ""})
call("find", lib.ss_find, {"query": "a*b"})

# ---- outline and read_span of every file
from_lines_cache = {}


def line_starts(data):
    off = 3 if data.startswith(b"\xef\xbb\xbf") else 0
    if off == len(data):
        return [len(data)]
    starts = [off]
    i, n = off, len(data)
    while i < n:
        b = data[i]
        brk = 0
        if b == 0x0D:
            brk = 2 if i + 1 < n and data[i + 1] == 0x0A else 1
        elif b in (0x0A, 0x0B, 0x0C, 0x1C, 0x1D, 0x1E):
            brk = 1
        elif b == 0xC2 and i + 1 < n and data[i + 1] == 0x85:
            brk = 2
        elif b == 0xE2 and i + 2 < n and data[i + 1] == 0x80 and data[i + 2] in (0xA8, 0xA9):
            brk = 3
        if brk:
            i += brk
            if i < n:
                starts.append(i)
        else:
            i += 1
    starts.append(n)
    return starts


for root, rel, p in files:
    data = p.read_bytes()
    st = line_starts(data)
    nlines = len(st) - 1
    base = {"root_id": root, "path": rel}
    call("outline", lib.ss_outline, base)
    # whole file in 400-line pieces; joined text must equal the bytes after the BOM
    got = []
    ok_whole = True
    for a in range(1, max(nlines, 1) + 1, 400):
        r = call("read_span", lib.ss_read_span, dict(base, start_line=a, end_line=a + 399))
        if r is None:
            ok_whole = False
            break
        got.append(r["text"].encode("utf-8"))
    if nlines == 0:
        pass
    elif ok_whole:
        stats["whole_files"] += 1
        want = data[st[0]:]
        if b"".join(got) != want:
            stats["whole_mismatch"] += 1
            print("WHOLE MISMATCH", root, rel, flush=True)
    else:
        stats["whole_skipped_capacity"] += 1
    if nlines == 0:
        call("read_span", lib.ss_read_span, dict(base, start_line=1, end_line=1))
        continue
    # first and last line, a clamped end, context at both ends, every line boundary sample
    reqs = [(1, 1, 0), (nlines, nlines, 0), (nlines, nlines + 50, 0), (1, 2, 20), (nlines, nlines, 20),
            (0, 1, 0), (nlines + 1, nlines + 1, 0), (2, 1, 0), (1, 1, 21)]
    # ranges crossing every 3rd line boundary (chunks overlap by 3 lines, so this crosses chunk edges and gaps)
    step = 1 if nlines <= 60 else 3
    for a in range(1, nlines, step):
        reqs.append((a, a + 1, 0))
    for a in rng.sample(range(1, nlines + 1), min(4, nlines)):
        reqs.append((a, min(nlines, a + rng.randint(0, 30)), rng.randint(0, 3)))
    for a, b, c in reqs:
        call("read_span", lib.ss_read_span, dict(base, start_line=a, end_line=b, context_lines=c))
call("read_span", lib.ss_read_span, {"root_id": files[0][0], "path": "no/such/file.md", "start_line": 1, "end_line": 1})
call("outline", lib.ss_outline, {"root_id": files[0][0], "path": "no/such/file.md"})
emit("status-after", None, lib.ss_status(h))
lib.ss_close(h)
out.close()
print(corpus, json.dumps(stats), flush=True)

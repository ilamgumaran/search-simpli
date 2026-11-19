"""S6-T8 verifier: exercise a damaged index through the C ABI (child process per index) and searchd.
check4.py LIB SEARCHD IDX WORDS_JSON CORPUS_DIR_OR_- -> one JSON line.
Paths that read section 5: ss_find words / phrase / prefix (highlights, deduplicate), the eager CLI open,
and the writer's carry (searchd index --update)."""
import ctypes, json, shutil, subprocess, sys
from pathlib import Path

lib_path, searchd, idx, words_json, corpus = sys.argv[1:6]
words = json.loads(words_json)
if sys.argv[-1] == "--child":
    lib = ctypes.CDLL(lib_path)
    lib.ss_open.restype = ctypes.c_void_p
    lib.ss_open.argtypes = [ctypes.c_char_p]
    lib.ss_last_error.restype = ctypes.c_char_p
    lib.ss_free.argtypes = [ctypes.c_void_p]
    lib.ss_find.restype = ctypes.c_void_p
    lib.ss_find.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.ss_query.restype = ctypes.c_void_p
    lib.ss_query.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_char_p]
    res = {}
    h = lib.ss_open(idx.encode())
    if not h:
        print(json.dumps({"open": "ERR " + lib.ss_last_error().decode()}))
        sys.exit(0)
    res["open"] = "ok"
    def ans(p):
        if not p:
            return "ERR " + (lib.ss_last_error() or b"").decode()
        s = ctypes.string_at(p); lib.ss_free(p)
        r = json.loads(s)
        hits = r.get("hits") or r.get("results") or []
        return "ok %d hits" % len(hits)
    w = words[0] if words else "zzz"
    res["query"] = ans(lib.ss_query(h, w.encode(), None, 0, 5, json.dumps({"retrieval_mode": "lexical"}).encode()))
    for mode, q in (("words", w), ("phrase", '"%s"' % w), ("prefix", w[:3] + "*"), ("words", "zzqqxxnotaword")):
        res["find %s %s" % (mode, q)] = ans(lib.ss_find(h, json.dumps({"query": q, "mode": mode, "page_size": 100}).encode()))
    res["find again"] = ans(lib.ss_find(h, json.dumps({"query": w, "page_size": 100}).encode()))
    print(json.dumps(res, ensure_ascii=False))
    sys.exit(0)

out = {"idx": Path(idx).name}
p = subprocess.run([sys.executable, "-I", __file__] + sys.argv[1:6] + ["--child"], capture_output=True, text=True)
out["abi"] = json.loads(p.stdout) if p.returncode == 0 and p.stdout.strip() else {"crash": p.returncode, "stderr": p.stderr[-300:]}
w = words[0] if words else "zzz"
c = subprocess.run([searchd, "find", idx, w, "--json"], capture_output=True, text=True)
out["cli find"] = ("exit %d " % c.returncode) + (c.stderr.strip()[-120:] if c.returncode else "ok")
if corpus != "-":
    wdir = Path(idx + ".upd")
    if not wdir.exists():
        shutil.copytree(idx, wdir)
    u = subprocess.run([searchd, "index", corpus, "--out", str(wdir), "--update", "--filename-index"], capture_output=True, text=True)
    out["writer update"] = ("exit %d " % u.returncode) + (u.stderr.strip()[-120:] if u.returncode else u.stdout.strip().splitlines()[-1][:40])
    if u.returncode == 0:
        p = subprocess.run([sys.executable, "-I", __file__, lib_path, searchd, str(wdir), words_json, "-", "--child"], capture_output=True, text=True)
        out["after update abi"] = json.loads(p.stdout) if p.returncode == 0 and p.stdout.strip() else {"crash": p.returncode}
print(json.dumps(out, ensure_ascii=False))

"""S6-T9 verifier: what one build does with one (damaged) index. observe.py V BUILD IDX CORPUS [--no-update]
Prints one JSON line: CLI `query --search-field filename` and content, ss_open + a file-name ss_query + a content
ss_query (C ABI, with ss_last_error), then the writer (CLI update: `index --update` or `apply` with no change; and
ss_index_folder with update), and whether the index's files are byte-identical before and after."""
import ctypes, hashlib, json, os, subprocess, sys
V, build, idx, corpus = sys.argv[1:5]
no_update = "--no-update" in sys.argv
S = f"{V}/bin/{build}/bin/searchd"
F = f"{V}/src.noindex/main/fixtures"
folder = {"family": f"{F}/family-folder", "fixtures": F}.get(corpus, f"{V}/corpora.noindex/{corpus}")
Q = {"j2": "pottery", "family": "README", "fixtures": "guide", "timing-10k": "doc", "prose-10k": "books", "tamil-10k": "doc"}[corpus]
env = dict(os.environ); env.pop("SEARCH_SIMPLI_LIBRARY_PATH", None)


def tree(d):
    h = hashlib.sha256()
    for a, ds, fs in os.walk(d):
        ds.sort()
        for f in sorted(fs):
            p = os.path.join(a, f)
            h.update(os.path.relpath(p, d).encode() + b"\0" + open(p, "rb").read())
    return h.hexdigest()[:16]


def cli(args):
    p = subprocess.run([S] + args, capture_output=True, text=True, env=env)
    err = p.stderr.strip().splitlines()
    out = p.stdout.strip()
    return {"rc": p.returncode, "err": err[-1][:160] if err else "", "out_sha": hashlib.sha256(out.encode()).hexdigest()[:12]}


before = tree(idx)
res = {"build": build, "idx": os.path.basename(idx), "corpus": corpus}
res["cli_query_filename"] = cli(["query", idx, Q, "--json", "--top-k", "5", "--search-field", "filename"])
res["cli_query_content"] = cli(["query", idx, Q, "--json", "--top-k", "5"])
lib = ctypes.CDLL(f"{V}/libs/{build}/libsearch_simpli.dylib")
lib.ss_open.restype = ctypes.c_void_p; lib.ss_open.argtypes = [ctypes.c_char_p]
lib.ss_close.argtypes = [ctypes.c_void_p]; lib.ss_last_error.restype = ctypes.c_char_p
lib.ss_query.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_char_p]
lib.ss_query.restype = ctypes.c_void_p; lib.ss_free.argtypes = [ctypes.c_void_p]
lib.ss_index_folder.restype = ctypes.c_void_p; lib.ss_index_folder.argtypes = [ctypes.c_char_p] * 3
lib.ss_apply_changes.restype = ctypes.c_void_p; lib.ss_apply_changes.argtypes = [ctypes.c_char_p] * 3
h = lib.ss_open(idx.encode())
if not h:
    res["abi_open"] = "refused: " + (lib.ss_last_error() or b"").decode()[:160]
else:
    res["abi_open"] = "ok"
    for field in ("filename", "content"):
        p = lib.ss_query(h, Q.encode(), None, 0, 5, json.dumps({"retrieval_mode": "lexical", "search_field": field}).encode())
        if p:
            res[f"abi_{field}"] = "ok " + hashlib.sha256(ctypes.string_at(p)).hexdigest()[:12]; lib.ss_free(p)
        else:
            res[f"abi_{field}"] = "refused: " + (lib.ss_last_error() or b"").decode()[:160]
    lib.ss_close(h)
if not no_update:
    if corpus == "j2":
        res["cli_update"] = cli(["apply", idx, "--changes", f"{V}/corpora.noindex/chg/j2-empty.json", "--filename-index"])
        mid = tree(idx)
        p = lib.ss_apply_changes(idx.encode(), open(f"{V}/corpora.noindex/chg/j2-empty.json", "rb").read(), b'{"filename_index": true}')
    else:
        res["cli_update"] = cli(["index", folder, "--out", idx, "--update", "--filename-index"])
        mid = tree(idx)
        p = lib.ss_index_folder(idx.encode(), folder.encode(), b'{"update": true, "filename_index": true}')
    res["abi_update"] = ("ok " + ctypes.string_at(p).decode()[:80]) if p else "refused: " + (lib.ss_last_error() or b"").decode()[:160]
    if p:
        lib.ss_free(p)
    res["unchanged_after_cli_update"] = mid == before
after = tree(idx)
res["unchanged_after_all"] = after == before
print(json.dumps(res, ensure_ascii=False))

#!/usr/bin/env python3
"""S6-T8 verifier (S6-T7 verifier's oldlib.py, the S6-T8 fixture and indexes): main's (old) library and searchd against copies of head-written indexes.

    oldlib.py V OUTDIR

Targets (each a fresh copy under OUTDIR): the committed fixture tests/fixtures/index-lex4-s6t8 (no WRITER.LOCK),
head's family index, head's J2 index. On each: every file's sha256 before; then, each on its own copy,
(a) C ABI ss_open, (b) ss_index_folder (filename_index), (c) ss_apply_changes (one add), (d) searchd query,
(e) searchd index --update, (f) searchd apply; the answer or error; every file's sha256 after; the differences.
"""
import ctypes
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

V, OUT = Path(sys.argv[1]), Path(sys.argv[2])
BUILD = sys.argv[3] if len(sys.argv) > 3 else "main"  # main, pre7 (before S6-T7) or pre4 (before S6-T4)
H = V / "src.noindex/head"
lib = ctypes.CDLL(str(V / "libs" / BUILD / "libsearch_simpli.dylib"))
lib.ss_open.restype = ctypes.c_void_p
lib.ss_open.argtypes = [ctypes.c_char_p]
lib.ss_last_error.restype = ctypes.c_char_p
lib.ss_free.argtypes = [ctypes.c_void_p]
for n in ("ss_index_folder", "ss_apply_changes"):
    getattr(lib, n).restype = ctypes.c_void_p
    getattr(lib, n).argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]
searchd = str(V / "bin" / BUILD / "bin/searchd")
change = json.dumps({"changes": [{"op": "add", "root_id": "r-legacy", "path": "zz-verifier-note.md",
                                  "content_base64": "IyBOb3RlCgpBIG5ldyBub3RlLgo="}]})
change_j2 = json.dumps({"changes": [{"op": "add", "root_id": "school", "path": "zz-verifier-note.md",
                                     "content_base64": "IyBOb3RlCgpBIG5ldyBub3RlLgo="}]})


def snap(d):
    return {p.name: (p.stat().st_size, hashlib.sha256(p.read_bytes()).hexdigest()) for p in sorted(d.iterdir()) if p.is_file()}


def diff(a, b):
    out = []
    for k in sorted(set(a) | set(b)):
        if a.get(k) != b.get(k):
            out.append(f"{k}: {a.get(k, 'absent')} -> {b.get(k, 'absent')}")
    return out


def err():
    return (lib.ss_last_error() or b"").decode("utf-8", "replace")


targets = {"fixture-v25": H / "tests/fixtures/index-lex4-s6t8", "timing-10k": V / "idx.noindex/head/timing-10k", "edge": V / "idx.noindex/head/edge", "family": V / "idx.noindex/head/family", "j2": V / "idx.noindex/head/j2"}
folder = {"fixture-v25": H / "fixtures/family-folder", "timing-10k": V / "corpora.noindex/timing-10k", "edge": V / "corpora.noindex/edge", "family": H / "fixtures/family-folder", "j2": H / "fixtures/family-folder"}
rows = []
for t, src in targets.items():
    for step in ("abi_open", "abi_index_folder", "abi_apply_changes", "cli_query", "cli_index_update", "cli_apply"):
        d = OUT / f"{t}-{step}"
        shutil.copytree(src, d)
        before = snap(d)
        if step == "abi_open":
            h = lib.ss_open(str(d).encode())
            res = "OPENED (not refused)" if h else "refused: " + err()
        elif step == "abi_index_folder":
            p = lib.ss_index_folder(str(d).encode(), str(folder[t]).encode(), b'{"filename_index":true}')
            res = ("WROTE: " + ctypes.string_at(p).decode()[:200]) if p else "refused: " + err()
        elif step == "abi_apply_changes":
            p = lib.ss_apply_changes(str(d).encode(), (change_j2 if t == "j2" else change).encode(), b'{"filename_index":true}')
            res = ("WROTE: " + ctypes.string_at(p).decode()[:200]) if p else "refused: " + err()
        else:
            if step == "cli_query":
                cmd = [searchd, "query", str(d), "week", "--json"]
            elif step == "cli_index_update":
                cmd = [searchd, "index", str(folder[t]), "--out", str(d), "--update", "--filename-index"]
            else:
                cf = OUT / f"{t}-change.json"
                cf.write_text(change_j2 if t == "j2" else change)
                cmd = [searchd, "apply", str(d), "--changes", str(cf), "--filename-index"]
            p = subprocess.run(cmd, capture_output=True, text=True)
            res = f"exit {p.returncode}: " + (p.stderr.strip() or p.stdout.strip())[-200:]
        after = snap(d)
        row = {"target": t, "step": step, "result": res, "changed_files": diff(before, after)}
        rows.append(row)
        print(json.dumps(row))
(OUT / "oldlib.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))

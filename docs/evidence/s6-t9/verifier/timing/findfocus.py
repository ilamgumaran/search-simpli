"""S6-T9 verifier, after the five runs (information only, decides nothing): the three timing-10k find cells that fail
the rule, and two that do not, interleaved: ROUNDS rounds, each build in a rotated order, one process per build and round
on its own index copy; per cell 20 warm-ups and 300 timed calls, p50 (us).   findfocus.py V ROUNDS OUT.jsonl"""
import json, os, subprocess, sys
V, rounds, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
B = ["main", "head", "main2", "cf", "cq"]
CELLS = [("prefix", "bada*"), ("words", "Database"), ("words", "Distributed"), ("prefix", "belo*"), ("words", "from")]
child = r'''
import ctypes, json, sys, time
lib = ctypes.CDLL(sys.argv[1]); lib.ss_open.restype = ctypes.c_void_p; lib.ss_open.argtypes = [ctypes.c_char_p]
lib.ss_find.restype = ctypes.c_void_p; lib.ss_find.argtypes = [ctypes.c_void_p, ctypes.c_char_p]; lib.ss_free.argtypes = [ctypes.c_void_p]
h = lib.ss_open(sys.argv[2].encode()); res = {}
for mode, q in json.loads(sys.argv[3]):
    req = json.dumps({"query": q, "mode": mode, "page_size": 10}).encode()
    for _ in range(20): lib.ss_free(lib.ss_find(h, req))
    s = []
    for _ in range(300):
        t = time.perf_counter(); lib.ss_free(lib.ss_find(h, req)); s.append((time.perf_counter() - t) * 1e6)
    s.sort(); res[f"{mode} {q}"] = s[149]
print(json.dumps(res))
'''
with open(out, "a") as f:
    for r in range(rounds):
        order = B[r % len(B):] + B[:r % len(B)]
        for b in order:
            g = subprocess.run(["bash", f"{V}/tim/gate.sh", f"findfocus r{r} {b}"], capture_output=True)
            if g.returncode != 0:
                raise SystemExit("gate refused")
            p = subprocess.run([sys.executable, "-I", "-c", child, f"{V}/libs/{b}/libsearch_simpli.dylib",
                                f"{V}/idx.noindex/oc/{b}/timing-10k", json.dumps(CELLS)], capture_output=True, text=True, check=True)
            f.write(json.dumps({"round": r, "build": b, "p50_us": json.loads(p.stdout)}) + "\n")
print("done")

#!/usr/bin/env python3
"""S6-T7 verifier: first publish from main's format and one-file update, one searchd.

    upd.py V VARIANT CORPUS TRIALS RUN OUT.jsonl
Per trial: an APFS clone (cp -c) of main's index and of the corpus under work.noindex/; one line
appended to the first file (by path order); timed `searchd index FOLDER --out IDX --update
--keep-generations 2 --filename-index` = "first" (for the head: v4 -> text once; for every other
build: v4 -> v4); then one line appended to the 100th file; timed again = "update" (head: v5 -> v5).
Wall ms per process (perf_counter around subprocess.run). Every cloned file is read once, untimed, before the first step
(from run 1 retaken: the first attempt of run 1 measured cold reads of the clones). The clones are removed by literal path
by the caller's next trial (the directory is reused).
"""
import json
import os
import subprocess
import sys
import time

V, variant, corpus, trials, run_no, out_path = sys.argv[1:7]
F = f"{V}/src.noindex/head/fixtures"
src_corpus = {"family": f"{F}/family-folder"}.get(corpus, f"{V}/corpora.noindex/{corpus}")
searchd = f"{V}/bin/{variant}/bin/searchd"
work = f"{V}/work.noindex/{variant}-{corpus}"
row = {"variant": variant, "corpus": corpus, "run": int(run_no), "load_before": [round(x, 2) for x in os.getloadavg()],
       "t_start": time.strftime("%H:%M:%S"), "trials": []}
for t in range(int(trials)):
    d = f"{work}/t{t}"
    if os.path.exists(d):
        raise SystemExit(f"{d} exists; clear work.noindex first")
    os.makedirs(d)
    subprocess.run(["cp", "-c", "-R", f"{V}/idx.noindex/main/{corpus}", f"{d}/idx"], check=True)
    subprocess.run(["cp", "-c", "-R", src_corpus, f"{d}/folder"], check=True)
    files = sorted(os.path.join(a, f) for a, _, fs in os.walk(f"{d}/folder") for f in fs)
    # warm the page cache: a clone is a new file to the cache, so read every byte of the copies once (untimed)
    for a, _, fs in list(os.walk(f"{d}/folder")) + list(os.walk(f"{d}/idx")):
        for f in fs:
            with open(os.path.join(a, f), "rb") as fh:
                fh.read()
    res = {}
    for step, target in (("first", files[0]), ("update", files[min(100, len(files) - 1)])):
        with open(target, "ab") as fh:
            fh.write(f"\nverifier line {step} {t}\n".encode())
        t0 = time.perf_counter()
        p = subprocess.run([searchd, "index", f"{d}/folder", "--out", f"{d}/idx", "--update", "--keep-generations", "2",
                            "--filename-index"], capture_output=True, text=True)
        ms = (time.perf_counter() - t0) * 1000
        if p.returncode != 0:
            raise SystemExit(f"{step} failed: {p.stderr}")
        rep = json.loads(p.stdout.strip().splitlines()[-1])
        res[step] = {"ms": ms, "changed": rep.get("changed"), "unchanged": rep.get("unchanged"), "generation": rep.get("generation")}
    man = open(f"{d}/idx/MANIFEST", "rb").read()
    res["bit6_after"] = bool(int.from_bytes(man[10:12], "little") & 0x40)
    row["trials"].append(res)
row["load_after"] = [round(x, 2) for x in os.getloadavg()]
row["t_end"] = time.strftime("%H:%M:%S")
with open(out_path, "a") as out:
    out.write(json.dumps(row) + "\n")
print(variant, corpus, [(round(x["first"]["ms"], 1), round(x["update"]["ms"], 1)) for x in row["trials"]])

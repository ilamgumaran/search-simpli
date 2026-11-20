#!/usr/bin/env python3
"""S6-T9 verifier (after the S6-T8 verifier's upd.py): first publish from main's format, a one-file update after it, and
an unchanged update (planning that finds no work), one searchd, TRIALS trials.
    upd.py V VARIANT CORPUS TRIALS RUN OUT.jsonl
Per trial: an APFS clone (cp -c) of main's index (v2.5) and of the corpus under work.noindex/r<RUN>/; every cloned
file read once, untimed; then three timed `searchd index FOLDER --out IDX --update --keep-generations 2
--filename-index` runs, each with the writer's stage timers on (SEARCH_SIMPLI_APPLY_STAGES=1, one `apply-stages` JSON
line on stderr):
  first     one line appended to the first file by path order (the head: v2.5 -> v2.6; every other build v2.5 -> v2.5)
  update    one line appended to the 100th file (the head reads its HYBSTA03 state)
  unchanged nothing changed (the planning reads the state and finds no work)
Wall ms per process (perf_counter around subprocess.run); plan_ms = parse_committed + load_previous + changes;
open_plan_ms = open_previous + plan_ms. Nothing is removed.
"""
import json
import os
import subprocess
import sys
import time

V, variant, corpus, trials, run_no, out_path = sys.argv[1:7]
F = f"{V}/src.noindex/main/fixtures"
src_corpus = {"family": f"{F}/family-folder", "fixtures": F}.get(corpus, f"{V}/corpora.noindex/{corpus}")
searchd = f"{V}/bin/{variant}/bin/searchd"
work = f"{V}/work.noindex/r{run_no}/{variant}-{corpus}"
PLAN = ("parse_committed", "load_previous", "changes")
row = {"variant": variant, "corpus": corpus, "run": run_no, "load_before": [round(x, 2) for x in os.getloadavg()],
       "t_start": time.strftime("%H:%M:%S"), "trials": []}
env = dict(os.environ, SEARCH_SIMPLI_APPLY_STAGES="1")
env.pop("SEARCH_SIMPLI_LIBRARY_PATH", None)
for t in range(int(trials)):
    d = f"{work}/t{t}"
    if os.path.exists(d):
        raise SystemExit(f"{d} exists")
    os.makedirs(d)
    subprocess.run(["cp", "-c", "-R", f"{V}/idx.noindex/main/{corpus}", f"{d}/idx"], check=True)
    subprocess.run(["cp", "-c", "-R", src_corpus, f"{d}/folder"], check=True)
    files = sorted(os.path.join(a, f) for a, _, fs in os.walk(f"{d}/folder") for f in fs)
    for a, _, fs in list(os.walk(f"{d}/folder")) + list(os.walk(f"{d}/idx")):
        for f in fs:
            with open(os.path.join(a, f), "rb") as fh:
                fh.read()
    res = {}
    for step, target in (("first", files[0]), ("update", files[min(100, len(files) - 1)]), ("unchanged", None)):
        if target:
            with open(target, "ab") as fh:
                fh.write(f"\nverifier line {step} {t}\n".encode())
        t0 = time.perf_counter()
        p = subprocess.run([searchd, "index", f"{d}/folder", "--out", f"{d}/idx", "--update", "--keep-generations", "2",
                            "--filename-index"], capture_output=True, text=True, env=env)
        ms = (time.perf_counter() - t0) * 1000
        if p.returncode != 0:
            raise SystemExit(f"{step} failed: {p.stderr[:400]}")
        lines = [l for l in p.stderr.splitlines() if l.startswith("apply-stages ")]
        stages = json.loads(lines[-1][len("apply-stages "):]) if lines else {}
        rep = json.loads(p.stdout.strip().splitlines()[-1])
        plan = sum(stages.get(k, 0.0) for k in PLAN)
        res[step] = {"ms": ms, "plan_ms": plan, "open_plan_ms": plan + stages.get("open_previous", 0.0),
                     "parse_committed_ms": stages.get("parse_committed"), "stages": stages,
                     "changed": rep.get("changed"), "added": rep.get("added"), "removed": rep.get("removed"),
                     "unchanged": rep.get("unchanged"), "generation": rep.get("generation")}
    man = open(f"{d}/idx/MANIFEST", "rb").read()
    res["flags_after"] = hex(int.from_bytes(man[10:12], "little"))
    row["trials"].append(res)
row["load_after"] = [round(x, 2) for x in os.getloadavg()]
row["t_end"] = time.strftime("%H:%M:%S")
with open(out_path, "a") as out:
    out.write(json.dumps(row) + "\n")
print(variant, corpus, [(round(x["first"]["ms"], 1), round(x["update"]["ms"], 1), round(x["unchanged"]["plan_ms"], 2))
                        for x in row["trials"]])

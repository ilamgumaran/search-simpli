#!/usr/bin/env python3
"""S6-T7 verifier: every damage case -> a damaged copy under dmg.noindex/RUN/CASE, checked with LIB in a subprocess.
    runall.py RUN LIB [case...]   -> dmg/results-RUN.jsonl"""
import json, subprocess, sys
from pathlib import Path
V = Path(__file__).resolve().parent.parent
run, lib = sys.argv[1], sys.argv[2]
cases = [l.split("\t") for l in subprocess.run([sys.executable, "-I", str(V / "dmg/dmg.py"), "list"], capture_output=True, text=True, check=True).stdout.splitlines()]
want = set(sys.argv[3:])
src = {"d_shared_256": ("head/edge", "edge"), "d_retained_nosource": ("nosrc-head/j2", "j2"), "m_bit6_on_v4": ("main/j2", "j2")}
out = open(V / f"dmg/results-{run}.jsonl", "a")
for name, kind, note in cases:
    if want and name not in want:
        continue
    ix, corpus = src.get(name, ("head/j2", "j2"))
    d = V / "dmg.noindex" / run / name
    p = subprocess.run([sys.executable, "-I", str(V / "dmg/dmg.py"), str(V / "idx.noindex" / ix), str(d), name], capture_output=True, text=True)
    row = {"case": name, "kind": kind, "note": note, "index": ix}
    if p.returncode != 0:
        row["make_error"] = (p.stderr or p.stdout).strip().splitlines()[-1:]
    else:
        c = subprocess.run([sys.executable, "-I", str(V / "dmg/check.py"), lib, str(d), corpus, str(V / "corpora.noindex"), str(V / "src.noindex/head/fixtures")], capture_output=True, text=True)
        row["exit"] = c.returncode
        row["result"] = json.loads(c.stdout) if c.returncode == 0 and c.stdout.strip() else c.stderr[-400:]
    out.write(json.dumps(row) + "\n")
    r = row.get("result", row.get("make_error"))
    if isinstance(r, dict):
        brief = {k: v for k, v in r.items() if k not in ("errors",)}
        print(name, "|", json.dumps(brief), "|", list(r.get("errors", {}))[:2])
    else:
        print(name, "| ERROR", r)

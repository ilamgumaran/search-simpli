#!/usr/bin/env python3
"""Spot check: one J2 index built by each searchd (diff of every file), then 20 J2
queries (`query --json`) and 5 `find --json` through each build on its own index.
Usage: v_spot.py SCRATCH J2_FOLDER JUDGMENTS"""
import filecmp
import json
import subprocess
import sys
from pathlib import Path

S, folder, judgments = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
builds = {"main": S / "main-out-rs/bin/searchd", "head": S / "head-out-rs/bin/searchd"}
for name, binary in builds.items():
    out = S / f"spot-index-{name}"
    if out.exists():
        sys.exit(f"{out} exists")
    p = subprocess.run([str(binary), "index", folder, "--out", str(out), "--filename-index"], capture_output=True)
    print(name, "index exit", p.returncode, p.stdout.decode()[:160].strip())


def walk(root):
    return sorted(str(p.relative_to(root)) for p in root.rglob("*") if p.is_file())


a, b = S / "spot-index-main", S / "spot-index-head"
fa, fb = walk(a), walk(b)
print("file lists equal:", fa == fb, len(fa), "files,", sum((a / f).stat().st_size for f in fa), "B")
same = [f for f in fa if f in fb and filecmp.cmp(a / f, b / f, shallow=False)]
print("files byte-identical:", len(same), "of", len(fa))

data = json.load(open(judgments, encoding="utf-8"))
queries = []
def collect(x):
    if isinstance(x, dict):
        for k, v in x.items():
            if k in ("query", "text") and isinstance(v, str):
                queries.append(v)
            else:
                collect(v)
    elif isinstance(x, list):
        for v in x:
            collect(v)
collect(data)
queries = list(dict.fromkeys(queries))[:20]
diff = 0
for q in queries:
    outs = {}
    for name, binary in builds.items():
        p = subprocess.run([str(binary), "query", str(S / f"spot-index-{name}"), q, "--json", "--top-k", "10"], capture_output=True)
        outs[name] = (p.returncode, p.stdout, p.stderr)
    if outs["main"] != outs["head"]:
        diff += 1
        print("DIFFERS:", q)
print(f"{len(queries)} queries, {diff} differ; bytes of answers {sum(len(subprocess.run([str(builds['head']), 'query', str(b), q, '--json'], capture_output=True).stdout) for q in queries[:3])} (first 3)")
fdiff = 0
for q in queries[:5]:
    outs = {name: subprocess.run([str(binary), "find", str(S / f"spot-index-{name}"), q.split()[0], "--json"], capture_output=True)[1:] if False else
            subprocess.run([str(binary), "find", str(S / f"spot-index-{name}"), q.split()[0], "--json"], capture_output=True).stdout
            for name, binary in builds.items()}
    if outs["main"] != outs["head"]:
        fdiff += 1
print(f"5 finds, {fdiff} differ")

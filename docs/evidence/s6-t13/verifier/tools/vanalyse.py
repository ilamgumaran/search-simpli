"""S6-T13 verifier: cells by the rule of 2026-11-17 from open.jsonl.   python3 -I vanalyse.py OPEN.jsonl"""
import json, statistics, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
builds = ["main", "main2", "head", "ca2", "cb2"]; controls = ["main2", "ca2", "cb2"]
for metric in ("wall_med", "cpu_med"):
    print(f"## {metric} (ms)\n| corpus | main median | head - main | main2 / ca2 / cb2 - main | T | head - worst control | rule | band |")
    print("| --- | ---: | ---: | --- | ---: | ---: | --- | ---: |")
    for corpus in ("timing-10k", "prose-10k", "tamil-10k"):
        v = {(r["build"], r["run"]): r[metric] for r in rows if r["corpus"] == corpus}
        runs = sorted({k[1] for k in v}); assert len(runs) == 5 and all((b, r) in v for b in builds for r in runs)
        m = statistics.median(v[("main", r)] for r in runs); t = max(0.010, 0.01 * m)
        d = {b: statistics.median(v[(b, r)] - v[("main", r)] for r in runs) for b in builds}
        worst = max(d[c] for c in controls); fail = d["head"] >= t and d["head"] - worst >= t
        band = sum(all(v[("head", r)] > v[(b, r)] for b in builds if b != "head") for r in runs)
        print(f"| {corpus} | {m:.4f} | {d['head']:+.4f} ({100*d['head']/m:+.2f} %) | {d['main2']:+.4f} / {d['ca2']:+.4f} / {d['cb2']:+.4f} "
              f"| {t:.4f} | {d['head']-worst:+.4f} | {'FAIL' if fail else 'pass'} | {band}/5 |")
    print()
print("## per run, wall_med (ms)")
for corpus in ("timing-10k", "prose-10k", "tamil-10k"):
    for r in sorted({x["run"] for x in rows}):
        val = {x["build"]: x["wall_med"] for x in rows if x["corpus"] == corpus and x["run"] == r}
        print(f"{corpus} run{r}: " + "  ".join(f"{b} {val[b]:.4f}" for b in builds))

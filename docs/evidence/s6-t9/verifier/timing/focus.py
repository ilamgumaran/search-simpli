"""S6-T9 verifier: per-run p50 (us) of named cells for every build, from analysis.json.  focus.py TIMDIR 'corpus<TAB>cell' ..."""
import json, sys
a = json.load(open(sys.argv[1] + "/analysis.json"))["cells"]
B = ("main", "main2", "head", "cq", "co", "cf", "cm", "cs")
for k in sys.argv[2:]:
    e = a.get(k)
    if not e:
        print("missing", k); continue
    print(f"{k.replace(chr(9), ' | ')}: head-main {e['head_minus_main']*1000:+.1f} us, T {e['T']*1000:.1f}, rule top {e['sets']['rule']['top']*1000:+.1f}, "
          f"placed top {e['sets']['placed']['top']*1000:+.1f}, main2 {e['controls']['main2']*1000:+.1f}; rule {'FAIL' if e['sets']['rule']['fail'] else 'pass'}, "
          f"placed {'FAIL' if e['sets']['placed']['fail'] else 'pass'}, main2 {'FAIL' if e['sets']['main2']['fail'] else 'pass'}; band {e['band']}/5")
    for r, row in sorted(e["per_run"].items()):
        print(f"    run{r}: " + " ".join(f"{b} {row[b]*1000:8.1f}" for b in B))

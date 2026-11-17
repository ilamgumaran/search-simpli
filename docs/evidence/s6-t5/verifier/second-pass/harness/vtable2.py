"""S6-T5 second verification: the timing tables from analysis.json and nwarn.json.
Prediction top (the Report's, stated before the first measurement): filename 0.6 µs, both 1.0 µs, plus 0.2 µs per warning written."""
import json, sys, statistics
a = json.load(open(sys.argv[1])); nw = json.load(open(sys.argv[2]))
us = lambda x: f"{x * 1000:+.2f}"
def pred(c):
    n = len(nw[f"{c['corpus']}|{c['cell']}"])
    return (0.6 if c["field"] == "filename" else 1.0) + 0.2 * n, n
print("| Field | Cells | five-run median d, µs (min .. max) | clause (1) | clause (2) | both clauses pass | within the prediction (of those failing) |")
print("|---|---:|---|---:|---:|---:|---|")
for f in ("content", "find", "filename", "both"):
    cs = [c for c in a["all"] if c["field"] == f]
    ds = [c["median_d_us"] for c in cs]
    f1 = sum("(1)" in c["fails"] for c in cs); f2 = sum("(2)" in c["fails"] for c in cs)
    ok = sum(c["fails"] == "no" for c in cs)
    if f in ("content", "find"):
        w = "— (code path unchanged: clause (1) decides)"
    else:
        fl = [c for c in cs if c["fails"] != "no"]
        w = f"{sum(c['median_d_us'] <= pred(c)[0] for c in fl)} of {len(fl)}"
    print(f"| `{f}` | {len(cs)} | {min(ds):+.2f} .. {max(ds):+.2f} | {f1} | {f2} | {ok} | {w} |")
print()
print("Unchanged code paths (`content`, `find`): every cell beyond clause (1) or (2)")
print()
print("| Corpus | Cell | `main` median, µs | head − `main`, µs | `main2` | `ctl1` | `ctl2` | runs above band | decides |")
print("|---|---|---:|---:|---:|---:|---:|---:|---|")
for c in a["all"]:
    if c["field"] in ("content", "find") and c["fails"] != "no":
        print(f"| {c['corpus']} | `{c['cell']}` | {c['main_median']*1000:.1f} | {c['median_d_us']:+.2f} | {us(c['median_main2'])} | {us(c['median_ctl1'])} | {us(c['median_ctl2'])} | {c['above_band_runs']} | {'**fails clause (1)**' if '(1)' in c['fails'] else 'clause (2) only: reported, does not fail'} |")
print()
print("Changed code paths (`both`, `filename`): every cell failing a clause")
print()
print("| Corpus | Cell | `main` median, µs | head − `main`, µs | `main2` | `ctl1` | `ctl2` | runs above band | clauses failed | warnings | prediction top, µs | within |")
print("|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---|")
for c in a["all"]:
    if c["field"] in ("both", "filename") and c["fails"] != "no":
        p, n = pred(c)
        print(f"| {c['corpus']} | `{c['cell']}` | {c['main_median']*1000:.1f} | {c['median_d_us']:+.2f} | {us(c['median_main2'])} | {us(c['median_ctl1'])} | {us(c['median_ctl2'])} | {c['above_band_runs']} | {c['fails']} | {n} | {p:.1f} | {'yes' if c['median_d_us'] <= p else '**no**'} |")

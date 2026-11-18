#!/usr/bin/env python3
"""S6-T7 verifier: markdown tables from analysis.json (tables.py analysis.json > tables.md)."""
import json
import sys

a = json.load(open(sys.argv[1]))
cells = a["cells"]
order = ["j2", "family", "fixtures", "timing-10k", "prose-10k", "tamil-10k"]


def ms(x):
    return f"{x:.4f}" if abs(x) < 1 else f"{x:.3f}" if abs(x) < 100 else f"{x:.1f}"


def row(c, unit="ms"):
    ctl = c["ctl"]
    if unit == "B":
        return (f"| {c['corpus']} | {c['cell']} | {c['main_median']:,.0f} | {c['median_d']:+,.0f} ({c['pct']:+.2f} %) | "
                f"{ctl['main2']:+,.0f} / {ctl['ctl1']:+,.0f} / {ctl['ctl2']:+,.0f} | – | – | {c['band_excursions']}/5 |")
    v4 = f" | {c['head_v4_median_d']:+.4f}" if "head_v4_median_d" in c else ""
    return (f"| {c['corpus']} | {c['cell']} | {ms(c['main_median'])} | {c['median_d']:+.4f} ({c['pct']:+.2f} %) | "
            f"{ctl['main2']:+.4f} / {ctl['ctl1']:+.4f} / {ctl['ctl2']:+.4f} | {c['T']:.4f} | "
            f"{'**FAIL**' if c['fails'] else ('at T, within controls' if c['at_T'] else 'pass')} | {c['band_excursions']}/5{v4} |")


def table(title, pred, unit="ms", v4=False):
    sel = [c for c in cells if pred(c) and not c.get("incomplete")]
    sel.sort(key=lambda c: (order.index(c["corpus"]) if c["corpus"] in order else 9, c["cell"]))
    print(f"\n**{title}** ({len(sel)} cells)\n")
    hdr = "| Corpus | Cell | main (median of 5) | head − main (median) | main2 / ctl1 / ctl2 − main | T | Rule | Band" + (" | head-v4 − main |" if v4 else " |")
    print(hdr)
    print("|" + "---|" * (hdr.count("|") - 1))
    for c in sel:
        print(row(c, unit))


table("Open, interleaved in one process, phase o (fixed before run 1): main/main2/ctl share one index copy", lambda c: c["phase"] in ("o", "ocpu"), v4=True)
table("Open, interleaved, phase o2 (added after the five runs, before its own): each pair its own index copy", lambda c: c["phase"] in ("o2", "o2cpu"), v4=True)
table("Open, separate processes (bench.py p50 of 30; rbench p50 of 60)", lambda c: c["phase"] in ("q", "r", "rcpu") and "open" in c["cell"])
table("Memory after open (bytes, phys_footprint delta / after open)", lambda c: c["phase"] in ("qmem", "rmem"), unit="B")
table("First call on a fresh handle", lambda c: c["phase"] in ("q", "r") and c["cell"].startswith("first"))
table("Later read_span / outline, CPU per call", lambda c: c["phase"] == "rcpu" and "CPU/call" in c["cell"])
table("Update and first publish (searchd index --update, wall ms per process)", lambda c: c["phase"] == "u")
q = [c for c in cells if c["phase"] == "q" and not c["cell"].startswith(("first", "open"))]
fails = [c for c in q if c["fails"]]
atT = [c for c in q if c.get("at_T") and not c["fails"]]
print(f"\n**Warm query and find cells:** {len(q)} cells; {len(fails)} fail the rule; {len(atT)} at or above T but within the controls; "
      f"band excursions in {sum(1 for c in q if c['band_excursions'] >= 3)} cells on 3 or more runs.")
worst = sorted(q, key=lambda c: -c["median_d"] / max(c["T"], 1e-9))[:8]
print("\n| Corpus | Cell | main | head − main | max control − main | T | Rule |\n|---|---|---|---|---|---|---|")
for c in worst:
    print(f"| {c['corpus']} | {c['cell'][:60]} | {ms(c['main_median'])} | {c['median_d']:+.4f} ({c['pct']:+.2f} %) | {max(c['ctl'].values()):+.4f} | {c['T']:.4f} | {'FAIL' if c['fails'] else 'pass'} |")
print(f"\nAnswer hashes: {len(a['answer_problems'])} differences between variants or runs.")

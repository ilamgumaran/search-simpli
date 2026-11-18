#!/usr/bin/env python3
"""S6-T8 verifier: markdown tables from analysis.json (tables.py analysis.json > tables.md). After S6-T7's verifier's."""
import json
import sys

a = json.load(open(sys.argv[1]))
cells = [c for c in a["cells"]]
order = ["j2", "family", "fixtures", "timing-10k", "prose-10k", "tamil-10k"]


def ms(x):
    return f"{x:.4f}" if abs(x) < 1 else f"{x:.3f}" if abs(x) < 100 else f"{x:.1f}"


def rule(c):
    return "**FAIL**" if c["fails"] else ("at T, within controls" if c["at_T"] else "pass")


def row(c, unit="ms"):
    ctl = c["ctl"]
    if unit == "B":
        return (f"| {c['corpus']} | {c['cell']} | {c['main_median']:,.0f} | {c['median_d']:+,.0f} ({c['pct']:+.1f} %) | "
                f"{ctl['main2']:+,.0f} / {ctl['ctl1']:+,.0f} / {ctl['ctl2']:+,.0f} | – | – | {c['band_excursions']}/5 |")
    v4 = f" | {c['head_v4_median_d']:+.4f}" if "head_v4_median_d" in c else ""
    return (f"| {c['corpus']} | {c['cell']} | {ms(c['main_median'])} | {c['median_d']:+.4f} ({c['pct']:+.1f} %) | "
            f"{ctl['main2']:+.4f} / {ctl['ctl1']:+.4f} / {ctl['ctl2']:+.4f} | {c['T']:.4f} | {rule(c)} | {c['band_excursions']}/5{v4} |")


def table(title, pred, unit="ms", v4=False):
    sel = [c for c in cells if pred(c) and not c.get("incomplete")]
    sel.sort(key=lambda c: (order.index(c["corpus"]) if c["corpus"] in order else 9, c["cell"]))
    print(f"\n**{title}** ({len(sel)} cells)\n")
    hdr = "| Corpus | Cell | main (median of 5) | head − main (median) | main2 / ctl1 / ctl2 − main | T | Rule | Band" + (" | head-v4 − main |" if v4 else " |")
    print(hdr)
    print("|" + "---|" * (hdr.count("|") - 1))
    for c in sel:
        print(row(c, unit))


inc = [c for c in cells if c.get("incomplete")]
print(f"Incomplete cells: {len(inc)}")
table("Open, interleaved in one process, each pair its own index copy (phase o2)", lambda c: c["phase"] in ("o2", "o2cpu"), v4=True)
table("Open, separate processes (bench.py, p50 of 30)", lambda c: c["phase"] == "q" and c["cell"].startswith("open"))
table("Memory after open (bytes, phys_footprint delta)", lambda c: c["phase"] == "qmem", unit="B")
table("First query and first find on a fresh handle", lambda c: c["phase"] == "q" and c["cell"].startswith("first"))
table("Update and first publish (searchd index --update, wall ms per process, median of 3 trials)", lambda c: c["phase"] == "u")
FOCUS = {("prose-10k", "both the"), ("prose-10k", "both have"), ("prose-10k", "both within"), ("prose-10k", "both the within"),
         ("prose-10k", "both have drink"), ("timing-10k", "find words from"), ("timing-10k", "find prefix bada*")}
table("The focus cells (the builder's five prose warm both cells and two find cells)", lambda c: c["phase"] == "q" and (c["corpus"], c["cell"]) in FOCUS)
q = [c for c in cells if c["phase"] == "q" and not c.get("incomplete") and not c["cell"].startswith(("first", "open"))]
for kind, pred in (("find", lambda c: c["cell"].startswith("find ")), ("query", lambda c: not c["cell"].startswith("find "))):
    sel = [c for c in q if pred(c)]
    fails = [c for c in sel if c["fails"]]
    atT = [c for c in sel if c["at_T"] and not c["fails"]]
    print(f"\n**Warm {kind} cells:** {len(sel)}; {len(fails)} fail the rule; {len(atT)} at or above T but within the controls; "
          f"band excursions on 3 or more runs in {sum(1 for c in sel if c['band_excursions'] >= 3)}.")
    for c in fails + atT:
        print(f"- {rule(c)}: {c['corpus']} `{c['cell']}` head − main {c['median_d']:+.4f} ms ({c['pct']:+.1f} %), largest control {max(c['ctl'].values()):+.4f}, T {c['T']:.4f}")
    worst = sorted(sel, key=lambda c: -c["median_d"] / max(c["T"], 1e-9))[:10]
    print(f"\nLargest ten {kind} cells by (head − main) / T:\n\n| Corpus | Cell | main | head − main | max control − main | T | Rule |\n|---|---|---|---|---|---|---|")
    for c in worst:
        print(f"| {c['corpus']} | {c['cell'][:60]} | {ms(c['main_median'])} | {c['median_d']:+.4f} ({c['pct']:+.1f} %) | {max(c['ctl'].values()):+.4f} | {c['T']:.4f} | {rule(c)} |")
print(f"\nAnswer hashes: {len(a['answer_problems'])} differences between variants or runs.")
for p in a["answer_problems"][:20]:
    print("-", p)

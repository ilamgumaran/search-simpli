#!/usr/bin/env python3
"""S6-T8 verifier (recheck): tables from analysis2.json: (1) prose-10k warm `both` cells under the rule set and the
original set; (2) every cell that fails under either set; (3) every cell at or above T; (4) the write expectations.
    tables2.py analysis2.json"""
import json, sys
a = json.load(open(sys.argv[1]))
cells = [c for c in a["cells"] if not c.get("incomplete")]
inc = [c for c in a["cells"] if c.get("incomplete")]
us = lambda x: f"{x * 1000:+.1f}"
def line(c):
    rs, os_ = c["rule_set"], c["original_set"]
    ctl = " ".join(f"{k} {us(v)}" for k, v in rs["ctl"].items())
    return (f"{c['corpus']} {c['cell']}: main {c['main_median'] * 1000:.1f} us, head2-main {us(c['median_d'])} ({c['pct']:+.2f} %), T {c['T'] * 1000:.1f}; "
            f"RULE SET largest {rs['largest']} {us(rs['ctl'][rs['largest']])}, beyond {us(rs['beyond'])} -> {'FAILS' if rs['fails'] else 'passes'}; "
            f"ORIGINAL SET largest {os_['largest']} {us(os_['ctl'][os_['largest']])}, beyond {us(os_['beyond'])} -> {'FAILS' if os_['fails'] else 'passes'}\n"
            f"    controls - main: {ctl}; head2-main per run: {' '.join(us(d) for d in c['d_runs'])}")
print(f"cells: {len(cells)} complete, {len(inc)} incomplete; answer problems: {len(a['answer_problems'])}")
for p in a["answer_problems"][:10]:
    print("  ", p)
print("\n(1) prose-10k warm both cells")
for c in cells:
    if c["phase"] == "q" and c["corpus"] == "prose-10k" and c["cell"].startswith("both "):
        print(line(c))
print("\n(2) cells failing under either set")
for c in cells:
    if c["phase"] in ("q", "u") and (c["rule_set"]["fails"] or c["original_set"]["fails"]):
        print(line(c))
print("\n(3) cells at or above T (head2 - main >= T), either set")
n = 0
for c in cells:
    if c["phase"] in ("q", "u") and c["at_T"]:
        n += 1
        print(line(c))
print(f"  {n} cells at or above T")
print("\n(4) write expectations (first publish and one-file update not slower than main by more than 2 %)")
for c in cells:
    if c["phase"] == "u":
        print(f"{c['corpus']} {c['cell']}: main {c['main_median']:.1f} ms, head2-main {c['median_d']:+.1f} ms ({c['pct']:+.2f} %) -> {'met' if c['write_expectation_met'] else 'NOT met'}; per run {' '.join(f'{d:+.1f}' for d in c['d_runs'])}")
print("\nmemory after open (bytes, head2 - main, five-run median)")
for c in cells:
    if c["phase"] == "qmem":
        print(f"{c['corpus']}: {c['median_d']:+,.0f} B ({c['pct']:+.1f} %)")

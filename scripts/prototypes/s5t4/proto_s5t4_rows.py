#!/usr/bin/env python3
"""S5-T4 prototype (planner scratch): per-query first grade-2 rank on chosen
slices for named candidates of proto_s5t4.grid(), both variants, with the top
hit of each changed row.
    PYTHONHASHSEED=0 python3 <this dir>/proto_s5t4_rows.py CAND [CAND ...] [--slices S ...]"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import proto_s5t4 as P  # noqa: E402
import j2run  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cands", nargs="+")
    ap.add_argument("--slices", nargs="*", default=["control", "morphology", "accent", "tamil"])
    args = ap.parse_args()
    g = P.grid()
    names = ["today-eng"] + [c for c in args.cands if c != "today-eng"]
    res = {n: j2run.run(g[n]) for n in names}
    qs = [q for q in j2run.JUDGMENTS["queries"] if q["slice"] in args.slices or (q.get("negative") and "negatives" in args.slices)]
    for v in ("content", "both"):
        print(f"== {v}: first grade-2 rank (- = not in the top 10)")
        print("id    query                          " + " ".join(f"{n[:11]:>11}" for n in names))
        for q in qs:
            ranks = []
            for n in names:
                r = res[n]["runs"][v]["queries"][q["id"]]
                rk = r.get("first_grade2_rank", "neg")
                ranks.append("-" if rk is None else str(rk))
            mark = "" if len(set(ranks)) == 1 else "  *"
            print(f"{q['id']:<5} {q['query'][:30]:<30} " + " ".join(f"{x:>11}" for x in ranks) + mark)


if __name__ == "__main__":
    main()

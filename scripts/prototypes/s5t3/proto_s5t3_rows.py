#!/usr/bin/env python3
"""S5-T3 prototype (planner scratch): per-query detail for one candidate of
proto_s5t3.py: each query's triggers and expansions (with distance and df), and
the top hits with grades, against today.

    PYTHONHASHSEED=0 python3 <this dir>/proto_s5t3_rows.py CANDIDATE [--ids m01 m02 ...] [--top 5]
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(Path.cwd()))
sys.path.insert(0, str(HERE))

import proto_s5t3 as P  # noqa: E402  (installs the cached candidate scan)
import relevance_smoke as rs  # noqa: E402
import src.search_platform.core as core  # noqa: E402
import fuzzy_expand as fx  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("candidate")
    ap.add_argument("--ids", nargs="*")
    ap.add_argument("--slices", nargs="*")
    ap.add_argument("--top", type=int, default=5)
    ap.add_argument("--variant", default="content")
    args = ap.parse_args()
    cfg = P.grid()[args.candidate]
    judgments = json.loads((rs.PACKS["j2"] / "judgments.json").read_text(encoding="utf-8"))
    pack = rs.PACKS["j2"]
    with tempfile.TemporaryDirectory() as scratch:
        union = Path(scratch) / "union"
        for r in judgments["roots"]:
            shutil.copytree(pack / r, union / r)
        index = core.build_index(union, filename_index=True)
    df = Counter()
    for c in index["chunks"]:
        df.update(c["terms"].keys())
    tvocab = fx._title_vocab(index["chunks"], tuple(judgments["roots"]))

    def hits(query):
        out = []
        for r in core.search(index, query, top_k=10, retrieval_mode="lexical", search_field=args.variant,
                             title_root_ids=judgments["roots"]):
            root, _, rest = r["citation"]["path"].partition("/")
            score = r["ranking"]["lexical"]["score"] if args.variant == "content" else r["score"]
            out.append({"root_id": root, "path": rest, "start_line": r["citation"]["start_line"],
                        "end_line": r["citation"]["end_line"], "score": score, "chunk_id": r.get("chunk_id")})
        return out

    for q in judgments["queries"]:
        if args.ids and q["id"] not in args.ids:
            continue
        if args.slices and q["slice"] not in args.slices:
            continue
        if q["mode"].startswith("find:"):
            continue
        terms = core.tokenize(q["query"]) if args.variant == "content" else core._filename_tokenize(q["query"])
        groups = fx.groups_for(cfg, terms, df, tvocab if cfg.title_guard else None)
        exp = {g: [(t, d, df[t]) for t, _, d in m if d] for g, m in groups if any(d for _, _, d in m)}
        trig = [g for g in sorted(set(terms)) if df.get(g, 0) <= cfg.df_max and not (cfg.title_guard and g in tvocab)]
        line = {}
        for label, c in (("today", None), (args.candidate, cfg)):
            fx.install(c, judgments["roots"])
            rec = rs.j2_record(q, hits(q["query"]))
            line[label] = rec
        print(f"{q['id']} [{q['slice']}] {q['query']!r} triggers={trig} expansions={exp}")
        for label, rec in line.items():
            top = "; ".join(f"{h['path']}:{h['start_line']}-{h['end_line']} g{h['grade']} {h['score']:.2f}" for h in rec["hits"][: args.top])
            print(f"   {label:>14}: first2={rec.get('first_grade2_rank')} | {top}")


if __name__ == "__main__":
    main()

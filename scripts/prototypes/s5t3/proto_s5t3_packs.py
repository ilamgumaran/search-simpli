#!/usr/bin/env python3
"""S5-T3 prototype (planner scratch): the old packs through the Python reference
with the expansion of fuzzy_expand.py installed (lexical, `content`, the title
field at its S5-T2 weight), against today. Prints each pack's metrics and every
per-query first relevant rank, and says whether each equals today's.

    PYTHONHASHSEED=0 python3 <this dir>/proto_s5t3_packs.py CANDIDATE [CANDIDATE ...]
"""
from __future__ import annotations

import contextlib
import io
import json
import shutil
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(Path.cwd()))
sys.path.insert(0, str(HERE))

import proto_s5t3 as P  # noqa: E402
import relevance_smoke as rs  # noqa: E402
import src.search_platform.core as core  # noqa: E402
import src.search_platform.evaluation as evaluation  # noqa: E402
import fuzzy_expand as fx  # noqa: E402

PACKS = (("relevance-smoke", "fixtures/relevance-smoke/corpus", "fixtures/relevance-smoke/judgments.json"),
         ("knowledge", "fixtures/knowledge", "fixtures/judgments.json"),
         ("mixed", "fixtures/mixed-knowledge", "fixtures/mixed-judgments.json"),
         ("tamil", "fixtures/tamil/passages", "fixtures/tamil/judgments.json"),
         ("semantic", "fixtures/semantic-knowledge", "fixtures/semantic-judgments.json"))


def ev(corpus, suite, top_k=10):
    with tempfile.TemporaryDirectory() as tmp:
        if corpus == "fixtures/tamil/passages":
            shutil.copytree(corpus, Path(tmp) / "passages")
            corpus = tmp
        index = core.build_index(Path(corpus))
    out = evaluation.evaluate_modes(index, evaluation.load_suite(Path(suite)), ["lexical"], top_k=top_k)
    m = out["reports"][0]
    per = {q["id"]: q["first_relevant_rank"] for q in m["queries"]}
    keys = ("mean_ndcg_at_k", "mean_reciprocal_rank", "macro_recall_at_k", "success_at_k")
    return {k: round(m[k], 4) for k in keys if k in m}, per


def run_all(cfg):
    res = {}
    for name, corpus, suite in PACKS:
        fx.install(cfg, ())
        res[name] = ev(corpus, suite)
    roots = json.loads((rs.PACKS["family-folder"] / "judgments.json").read_text())["roots"]
    fx.install(cfg, roots)
    with contextlib.redirect_stdout(io.StringIO()):
        pack = rs.run_pack("family-folder")
    res["family-folder"] = ({"words_recall_at_k": pack["words_recall_at_k"], "exactness": pack["exactness"],
                             "find_metrics": pack["find_metrics"]},
                            {c["id"]: c["recall"] for c in pack["words_cases"]})
    return res


def main():
    grid = P.grid()
    today = run_all(None)
    for name in sys.argv[1:]:
        got = run_all(grid[name])
        print(f"=== {name}")
        for pack, (metrics, per) in got.items():
            same = (metrics, per) == today[pack]
            s1 = sum(1 for r in per.values() if r == 1) / len(per) if per and all(isinstance(r, (int, type(None))) for r in per.values()) else None
            s1t = sum(1 for r in today[pack][1].values() if r == 1) / len(today[pack][1]) if s1 is not None else None
            extra = f" success@1 {s1t:.2f} -> {s1:.2f}" if s1 is not None else ""
            print(f"{pack}: {'identical to today' if same else 'DIFFERS'}{extra} {json.dumps(metrics, sort_keys=True)[:400]}")
            if not same:
                print(f"   today {json.dumps(today[pack][0], sort_keys=True)[:400]}")
                diff = {q: (today[pack][1].get(q), r) for q, r in per.items() if today[pack][1].get(q) != r}
                print(f"   per-query changes {json.dumps(diff, sort_keys=True)[:1500]}")


if __name__ == "__main__":
    main()

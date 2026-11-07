#!/usr/bin/env python3
"""S5-T4 prototype (planner scratch): the old packs through the Python reference
with a candidate analyzer (index side: installed before the build; query side:
groups installed after it), against today. Prints each pack's metrics and every
per-query first relevant rank that changed.
    PYTHONHASHSEED=0 python3 <this dir>/proto_s5t4_packs.py CAND [CAND ...]"""
from __future__ import annotations

import contextlib
import io
import json
import shutil
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import analyzer_v3 as v3  # noqa: E402
import j2run  # noqa: E402
import proto_s5t4 as P  # noqa: E402
import relevance_smoke as rs  # noqa: E402
import src.search_platform.core as core  # noqa: E402
import src.search_platform.evaluation as evaluation  # noqa: E402

PACKS = (("relevance-smoke", "fixtures/relevance-smoke/corpus", "fixtures/relevance-smoke/judgments.json"),
         ("knowledge", "fixtures/knowledge", "fixtures/judgments.json"),
         ("mixed", "fixtures/mixed-knowledge", "fixtures/mixed-judgments.json"),
         ("tamil", "fixtures/tamil/passages", "fixtures/tamil/judgments.json"),
         ("semantic", "fixtures/semantic-knowledge", "fixtures/semantic-judgments.json"))


def before_build(cfg):
    v3.restore()
    if cfg is not None and cfg.side == "index":
        v3.set_analyzers(v3.body_cfg(cfg), v3.filename_cfg(cfg))


def after_build(cfg):
    if cfg is not None and cfg.side != "index":
        j2run.install_groups(cfg)


def ev(cfg, corpus, suite, top_k=10):
    before_build(cfg)
    with tempfile.TemporaryDirectory() as tmp:
        if corpus == "fixtures/tamil/passages":
            shutil.copytree(corpus, Path(tmp) / "passages")
            corpus = tmp
        index = core.build_index(Path(corpus))
    after_build(cfg)
    try:
        out = evaluation.evaluate_modes(index, evaluation.load_suite(Path(suite)), ["lexical"], top_k=top_k)
    finally:
        v3.restore()
    m = out["reports"][0]
    per = {q["id"]: q["first_relevant_rank"] for q in m["queries"]}
    keys = ("mean_ndcg_at_k", "mean_reciprocal_rank", "macro_recall_at_k", "success_at_k")
    return {k: round(m[k], 4) for k in keys if k in m}, per


def family(cfg):
    """run_pack builds its own index; the hooks are installed around the whole run."""
    v3.restore()
    if cfg is not None and cfg.side == "index":
        v3.set_analyzers(v3.body_cfg(cfg), v3.filename_cfg(cfg))
    elif cfg is not None:
        orig_build = core.build_index

        def build_then_group(*a, **k):
            idx = orig_build(*a, **k)
            j2run.install_groups(cfg)
            return idx
        rs.build_index = build_then_group
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            pack = rs.run_pack("family-folder")
    finally:
        rs.build_index = core.build_index if not hasattr(core.build_index, "__wrapped__") else core.build_index
        v3.restore()
    return ({"words_recall_at_k": pack["words_recall_at_k"], "exactness": pack["exactness"],
             "find_metrics": pack["find_metrics"]},
            {c["id"]: c["recall"] for c in pack["words_cases"]})


def run_all(cfg):
    res = {name: ev(cfg, corpus, suite) for name, corpus, suite in PACKS}
    res["family-folder"] = family(cfg)
    return res


def main():
    grid = P.grid()
    orig_rs_build = rs.build_index
    today = run_all(None)
    for name in sys.argv[1:]:
        rs.build_index = orig_rs_build
        got = run_all(grid[name])
        print(f"=== {name}")
        for pack, (metrics, per) in got.items():
            same = (metrics, per) == today[pack]
            vals = list(per.values())
            s1 = (sum(1 for r in vals if r == 1) / len(vals)) if vals and all(isinstance(r, (int, type(None))) for r in vals) else None
            s1t = (sum(1 for r in today[pack][1].values() if r == 1) / len(today[pack][1])) if s1 is not None else None
            extra = f" success@1 {s1t:.2f} -> {s1:.2f}" if s1 is not None else ""
            print(f"{pack}: {'identical to today' if same else 'DIFFERS'}{extra} {json.dumps(metrics, sort_keys=True)[:400]}")
            if not same:
                print(f"   today {json.dumps(today[pack][0], sort_keys=True)[:400]}")
                diff = {q: (today[pack][1].get(q), r) for q, r in per.items() if today[pack][1].get(q) != r}
                print(f"   per-query changes {json.dumps(diff, sort_keys=True, ensure_ascii=False)[:1500]}")


if __name__ == "__main__":
    main()

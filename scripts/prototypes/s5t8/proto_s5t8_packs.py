#!/usr/bin/env python3
"""S5-T8 prototype (builder, Phase 1b): the old packs through the Python reference
with a candidate installed (rules.py), against today (bar (e)). Prints each pack's
metrics and every per-query first relevant rank that changed.

    PYTHONHASHSEED=0 python3 scripts/prototypes/s5t8/proto_s5t8_packs.py CAND [CAND ...]"""
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

import rules as V  # noqa: E402

import relevance_smoke as rs  # noqa: E402
import src.search_platform.core as core  # noqa: E402
import src.search_platform.evaluation as evaluation  # noqa: E402

PACKS = (("relevance-smoke", "fixtures/relevance-smoke/corpus", "fixtures/relevance-smoke/judgments.json"),
         ("knowledge", "fixtures/knowledge", "fixtures/judgments.json"),
         ("mixed", "fixtures/mixed-knowledge", "fixtures/mixed-judgments.json"),
         ("tamil", "fixtures/tamil/passages", "fixtures/tamil/judgments.json"),
         ("semantic", "fixtures/semantic-knowledge", "fixtures/semantic-judgments.json"))
KEYS = ("mean_ndcg_at_k", "mean_reciprocal_rank", "macro_recall_at_k", "success_at_k")


def ev(corpus: str, suite: str, top_k: int = 10):
    with tempfile.TemporaryDirectory() as tmp:
        if corpus == "fixtures/tamil/passages":
            shutil.copytree(corpus, Path(tmp) / "passages")
            corpus = tmp
        index = core.build_index(Path(corpus))
    out = evaluation.evaluate_modes(index, evaluation.load_suite(Path(suite)), ["lexical"], top_k=top_k)
    m = out["reports"][0]
    per = {q["id"]: q["first_relevant_rank"] for q in m["queries"]}
    return {k: round(m[k], 4) for k in KEYS if k in m}, per


def family():
    with contextlib.redirect_stdout(io.StringIO()):
        pack = rs.run_pack("family-folder")
    return ({"words_recall_at_k": pack["words_recall_at_k"], "exactness": pack["exactness"],
             "find_metrics": pack["find_metrics"]},
            {c["id"]: c["recall"] for c in pack["words_cases"]})


def run_all(name: str | None) -> dict:
    V.install(name)
    try:
        res = {pack: ev(corpus, suite) for pack, corpus, suite in PACKS}
        res["family-folder"] = family()
    finally:
        V.restore()
    return res


def success_at_1(per: dict) -> float | None:
    vals = list(per.values())
    if not vals or not all(isinstance(r, (int, type(None))) for r in vals):
        return None
    return sum(1 for r in vals if r == 1) / len(vals)


def main(argv=None) -> int:
    names = (argv if argv is not None else sys.argv[1:]) or ["W", "Wb", "F", "X"]
    today = run_all("today")
    rewrite = run_all("rewrite")
    print("rewrite (_fold_groups rewritten, R unchanged) equals today on every pack:", rewrite == today)
    for pack, (metrics, per) in today.items():
        s1 = success_at_1(per)
        print(f"today {pack}: {json.dumps(metrics, sort_keys=True)[:300]}" + (f" success@1 {s1:.3f}" if s1 is not None else ""))
    for name in names:
        got = run_all(name)
        print(f"=== {name}")
        for pack, (metrics, per) in got.items():
            same = (metrics, per) == today[pack]
            s1, s1t = success_at_1(per), success_at_1(today[pack][1])
            extra = f" success@1 {s1t:.3f} -> {s1:.3f}" if s1 is not None else ""
            print(f"{pack}: {'identical to today' if same else 'DIFFERS'}{extra} {json.dumps(metrics, sort_keys=True)[:300]}")
            if not same:
                diff = {q: (today[pack][1].get(q), r) for q, r in per.items() if today[pack][1].get(q) != r}
                print(f"   per-query changes {json.dumps(diff, sort_keys=True, ensure_ascii=False)[:1500]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

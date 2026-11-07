#!/usr/bin/env python3
"""S5-T3 prototype (planner scratch): misspelling expansion at query time on J2,
through the Python reference (core.search with `_bm25_scores` and `_title_scores`
patched by fuzzy_expand.py) and the S5-T1 metric and gate code.

Run from a checkout that holds fixtures/j2 at the S5-T2 baseline (main 2485787 or later):
    PYTHONHASHSEED=0 python3 <this dir>/proto_s5t3.py [--only NAME ...] [--json OUT] [--detail]
"""
from __future__ import annotations

import argparse
import functools
import importlib.util
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = Path.cwd()
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(HERE))

import relevance_smoke as rs  # noqa: E402
import src.search_platform.core as core  # noqa: E402
import fuzzy_expand as fx  # noqa: E402
from fuzzy_expand import Cfg, replace  # noqa: E402

spec = importlib.util.spec_from_file_location("j2_gate", ROOT / "scripts" / "j2_gate.py")
j2_gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(j2_gate)

# Candidate generation is the slow part in Python; J2 is one index, so cache the
# full ordered candidate list per (term, bound, filters, dictionary fingerprint).
_orig_candidates = fx.candidates


@functools.lru_cache(maxsize=None)
def _cands(term, k, first_letter, prefix, latin_only, fp):
    df = dict(_items_cache[fp])
    c = Cfg(d1_min=1 if k >= 1 else 99, d2_min=1 if k >= 2 else 99, first_letter=first_letter,
            prefix=prefix, latin_only=latin_only, max_expansions=10**9)
    return tuple(_orig_candidates(c, term, df))  # the full (distance, -df, bytes) order


_items_cache: dict = {}


def cached_candidates(cfg, term, df):
    fp = (len(df), sum(df.values()))
    if fp not in _items_cache:
        _items_cache[fp] = tuple(sorted(df.items()))
    k = fx.max_distance(cfg, term)
    full = _cands(term, k, cfg.first_letter, cfg.prefix, cfg.latin_only, fp)
    return fx.finish(cfg, term, list(full))


fx.candidates = cached_candidates

BASE = Cfg(name="E-base")  # df 0, d1 >= 3, d2 >= 6, first letter, N 3, w 0.8, max df, max combine, title on


def grid() -> dict[str, Cfg | None]:
    g: dict[str, Cfg | None] = {"today": None}
    # (1) df-0 expansion: N x weight
    for n in (1, 2, 3, 5, 10, 50):
        for w in (1.0, 0.8, 0.6, 0.5, 0.3):
            g[f"E-n{n}-w{w}"] = replace(BASE, name=f"E-n{n}-w{w}", max_expansions=n, weight=w)
    # the edit bound by length
    for d1, d2 in ((3, 99), (4, 99), (3, 7), (3, 8), (4, 8), (3, 5)):
        g[f"E-d1:{d1}-d2:{d2}"] = replace(BASE, name=f"E-d1:{d1}-d2:{d2}", d1_min=d1, d2_min=d2)
    g["E-anyfirst"] = replace(BASE, name="E-anyfirst", first_letter=False)
    g["E-anyfirst-n10"] = replace(BASE, name="E-anyfirst-n10", first_letter=False, max_expansions=10)
    # the blended df and the combination inside a chunk
    for blend in ("max", "sum", "union", "own"):
        for comb in ("max", "sum"):
            g[f"E-df:{blend}-c:{comb}"] = replace(BASE, name=f"E-df:{blend}-c:{comb}", blend=blend, combine=comb)
    g["E-df:own-c:sum-n10-w1"] = replace(BASE, name="E-df:own-c:sum-n10-w1", blend="own", combine="sum", max_expansions=10, weight=1.0)
    # (3) damping by distance
    g["E-damp-w1"] = replace(BASE, name="E-damp-w1", damp=True, weight=1.0)
    g["E-damp-w0.8"] = replace(BASE, name="E-damp-w0.8", damp=True)
    # (2) expansion when df is low but not zero
    for t in (1, 2, 3, 5):
        g[f"E-lowdf{t}"] = replace(BASE, name=f"E-lowdf{t}", df_max=t)
    g["E-lowdf1-nokeep"] = replace(BASE, name="E-lowdf1-nokeep", df_max=1, keep_low=False)
    # (5) the title field: off, and without the title guard
    g["E-notitle"] = replace(BASE, name="E-notitle", title=False)
    g["E-noguard"] = replace(BASE, name="E-noguard", title_guard=False)
    g["E-notitle-noguard"] = replace(BASE, name="E-notitle-noguard", title=False, title_guard=False)
    # Tamil and other scripts
    g["E-latin"] = replace(BASE, name="E-latin", latin_only=True)
    # distance-2 weight, nearest-distance-only, accent-first ordering
    for w2 in (0.8, 0.6, 0.5):
        g[f"E-w1-w2:{w2}"] = replace(BASE, name=f"E-w1-w2:{w2}", weight=1.0, w2=w2)
    g["E-w1-mind"] = replace(BASE, name="E-w1-mind", weight=1.0, min_dist_only=True)
    g["E-w1-accent"] = replace(BASE, name="E-w1-accent", weight=1.0, accent_first=True)
    g["E-w1-n1-accent"] = replace(BASE, name="E-w1-n1-accent", weight=1.0, max_expansions=1, accent_first=True)
    # the recommendation and its neighbours: w 1, N 3, Latin only
    g["R-w1-n3-latin"] = replace(BASE, name="R-w1-n3-latin", weight=1.0, latin_only=True)
    g["R-w1-n3-latin-accent"] = replace(BASE, name="R-w1-n3-latin-accent", weight=1.0, latin_only=True, accent_first=True)
    g["R-w0.9-n3-latin"] = replace(BASE, name="R-w0.9-n3-latin", weight=0.9, latin_only=True)
    g["R-w1-n3-latin-notitle"] = replace(BASE, name="R-w1-n3-latin-notitle", weight=1.0, latin_only=True, title=False)
    g["R-w1-n3-latin-anyfirst"] = replace(BASE, name="R-w1-n3-latin-anyfirst", weight=1.0, latin_only=True, first_letter=False)
    g["R-w1-n3-latin-d2:99"] = replace(BASE, name="R-w1-n3-latin-d2:99", weight=1.0, latin_only=True, d2_min=99)
    g["R-w1-n3-latin-lowdf1"] = replace(BASE, name="R-w1-n3-latin-lowdf1", weight=1.0, latin_only=True, df_max=1)
    # The plan's rule (ruling 2): w 1.0 at distance 1, 0.5 at distance 2, N 3, Latin only.
    g["R-final"] = replace(BASE, name="R-final", weight=1.0, w2=0.5, latin_only=True)
    g["R-final-n1"] = replace(BASE, name="R-final-n1", weight=1.0, w2=0.5, latin_only=True, max_expansions=1)
    g["R-final-n10"] = replace(BASE, name="R-final-n10", weight=1.0, w2=0.5, latin_only=True, max_expansions=10)
    g["R-final-alltitle-off"] = replace(BASE, name="R-final-alltitle-off", weight=1.0, w2=0.5, latin_only=True, title=False)
    g["R-final-candtitle"] = replace(BASE, name="R-final-candtitle", weight=1.0, w2=0.5, latin_only=True, cand_title=True)
    for d1 in (4, 5):
        for w2 in (0.5, 0.25):
            n = f"R-ct-d1:{d1}-w2:{w2}"
            g[n] = replace(BASE, name=n, weight=1.0, w2=w2, latin_only=True, cand_title=True, d1_min=d1)
    g["R-ct-d1:3-w2:0.25"] = replace(BASE, name="R-ct-d1:3-w2:0.25", weight=1.0, w2=0.25, latin_only=True, cand_title=True)
    # THE PLAN'S RULE (ruling 2): R
    g["R"] = replace(BASE, name="R", weight=1.0, w2=0.5, latin_only=True, cand_title=True, d1_min=5, d2_min=6)
    g["R-scripts"] = replace(g["R"], name="R-scripts", latin_only=False)
    g["R-notitle"] = replace(g["R"], name="R-notitle", title=False)
    g["R-w0.8"] = replace(g["R"], name="R-w0.8", weight=0.8, w2=0.4)
    g["R-n1"] = replace(g["R"], name="R-n1", max_expansions=1)
    g["R-n10"] = replace(g["R"], name="R-n10", max_expansions=10)
    g["R-anyfirst"] = replace(g["R"], name="R-anyfirst", first_letter=False)
    g["R-lowdf1"] = replace(g["R"], name="R-lowdf1", df_max=1)
    g["R-noguard"] = replace(g["R"], name="R-noguard", title_guard=False)
    g["R-c:sum"] = replace(g["R"], name="R-c:sum", combine="sum")
    g["R-df:own-c:sum"] = replace(g["R"], name="R-df:own-c:sum", blend="own", combine="sum")
    g["R-final-scripts"] = replace(BASE, name="R-final-scripts", weight=1.0, w2=0.5)
    # (4) prefix/edit hybrid
    for p in (4, 5):
        g[f"E-prefix{p}"] = replace(BASE, name=f"E-prefix{p}", prefix=p)
    return g


SLICES = ("control", "misspelling", "morphology", "accent", "tamil", "title", "phrase", "title-heldout")


def run(cfg, judgments):
    fx.install(cfg, judgments["roots"])
    fx.STATE["log"] = []
    out = rs.run_j2_pack()
    out["expansions"] = fx.STATE["log"]
    fx.STATE["log"] = None
    return out


def find_rewrite_rows(cfg, judgments):
    """Information for (5): the find rows with each trigger rewritten to its first
    expansion (find is conjunctive; a group cannot be OR-ed in through the text)."""
    from src.search_platform.find import find
    import shutil
    import tempfile
    from collections import Counter
    pack = rs.PACKS["j2"]
    with tempfile.TemporaryDirectory() as scratch:
        union = Path(scratch) / "union"
        for r in judgments["roots"]:
            shutil.copytree(pack / r, union / r)
        index = core.build_index(union, filename_index=True)
    df = Counter()
    for c in index["chunks"]:
        df.update(c["terms"].keys())
    rows = {}
    for q in judgments["queries"]:
        if not q["mode"].startswith("find:") or q["mode"] == "find:prefix":
            continue
        words = core.tokenize(q["query"])
        new = []
        changed = False
        for w in words:
            if df.get(w, 0) == 0:
                c = cached_candidates(cfg, w, df)
                if c:
                    new.append(c[0][0])
                    changed = True
                    continue
            new.append(w)
        if not changed:
            continue
        text = " ".join(new)
        hits = []
        for h in find(index, text, mode=q["mode"].split(":", 1)[1], page_size=rs.J2_TOP_K)["hits"]:
            root, _, rest = h["path"].partition("/")
            hits.append({"root_id": root, "path": rest, "start_line": h["start_line"], "end_line": h["end_line"],
                         "score": h["score"], "chunk_id": h.get("chunk_id")})
        rec = rs.j2_record(q, hits)
        rows[q["id"]] = {"rewritten": text, "first_grade2_rank": rec.get("first_grade2_rank"), "returned": len(hits)}
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--json")
    ap.add_argument("--detail", action="store_true")
    args = ap.parse_args()
    judgments = json.loads((rs.PACKS["j2"] / "judgments.json").read_text(encoding="utf-8"))
    baseline = json.loads((rs.PACKS["j2"] / "baseline.json").read_text(encoding="utf-8"))
    base_runs = baseline["surfaces"]["python-reference"]["runs"]
    cands = grid()
    names = [n for n in cands if not args.only or n in args.only or n == "today"]
    results = {}
    for name in names:
        results[name] = run(cands[name], judgments)
    # The reimplemented path with no config must equal the committed Python baseline.
    for v in ("content", "both"):
        today = results["today"]["runs"][v]
        for qid, r in base_runs[v]["first_grade2_rank"].items():
            if today["queries"][qid].get("first_grade2_rank") != r:
                print(f"BASELINE MISMATCH {v} {qid}", file=sys.stderr)
        for sl, m in base_runs[v]["slices"].items():
            mine = {k: today["slices"][sl][k] for k in m}
            if mine != m:
                print(f"BASELINE MISMATCH {v} slice {sl} {m} {mine}", file=sys.stderr)
    summary = {}
    print("candidate | variant | " + " | ".join(SLICES) + " | overall | gate   (success@1/MRR@10)")
    for name in names:
        summary[name] = {}
        for v in ("content", "both"):
            run_v = results[name]["runs"][v]
            fails, _ = j2_gate.judge(run_v, base_runs[v], {})
            cells = [f"{run_v['slices'][s]['success_at_1']:.3f}/{run_v['slices'][s]['mrr_at_10']:.3f}" for s in SLICES]
            o = run_v["overall"]
            print(f"{name} | {v} | " + " | ".join(cells) + f" | {o['success_at_1']:.3f}/{o['mrr_at_10']:.3f} | "
                  + ("pass" if not fails else "FAIL " + "; ".join(fails)))
            moves = {}
            for qid, r in run_v["queries"].items():
                if "first_grade2_rank" not in r:
                    continue
                b = base_runs[v]["first_grade2_rank"][qid]
                if r["first_grade2_rank"] != b:
                    moves[qid] = [b, r["first_grade2_rank"]]
            negs = {}
            for qid, r in run_v["negatives"].items():
                b = base_runs[v]["negatives"][qid]
                if (b["top_hit"], b["returned"]) != (r["top_hit"], r["returned"]):
                    negs[qid] = {"before": [b["returned"], b["top_hit"] and b["top_hit"]["path"]],
                                 "after": [r["returned"], r["top_hit"] and r["top_hit"]["path"], r["top_hit_grade"]]}
            summary[name][v] = {"slices": {s: [run_v["slices"][s]["success_at_1"], run_v["slices"][s]["mrr_at_10"]] for s in SLICES},
                                "overall": [o["success_at_1"], o["mrr_at_10"]], "gate": fails, "moves": moves,
                                "negatives": negs}
        exps = {}
        for e in results[name]["expansions"]:
            exps.setdefault(e["term"], e["expansions"])
        summary[name]["expansions"] = exps
    if args.detail:
        for name in names:
            for v in ("content", "both"):
                mv = summary[name][v]["moves"]
                print(f"MOVES {name} {v} " + " ".join(f"{q}:{a}->{b}" for q, (a, b) in sorted(mv.items())))
                for q, n in sorted(summary[name][v]["negatives"].items()):
                    print(f"NEG {name} {v} {q} {n['before']} -> {n['after']}")
            print(f"EXPANSIONS {name} " + json.dumps(summary[name]["expansions"], ensure_ascii=False, sort_keys=True))
        e = cands.get("E-base") or BASE
        print("FIND-REWRITE (E-base bound, first expansion) " + json.dumps(find_rewrite_rows(e, judgments), ensure_ascii=False, sort_keys=True))
    if args.json:
        Path(args.json).write_text(json.dumps(summary, ensure_ascii=False, indent=1, sort_keys=True))


if __name__ == "__main__":
    main()

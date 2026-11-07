#!/usr/bin/env python3
"""S5-T2 prototype (planner scratch): the old packs through the Python reference
with the title field patched into lexical `content` search (C1: chunk score = body
BM25 + w * title BM25 * matched-fraction, on the file's best body chunk or its
anchor). Usage: PYTHONHASHSEED=0 python3 proto_s5t2_packs.py W [W ...]  (W=0: today)"""
import json, sys, io, contextlib
from collections import Counter, defaultdict
from pathlib import Path
sys.path.insert(0, str(Path.cwd()))
import src.search_platform.core as core
import src.search_platform.evaluation as evaluation
import relevance_smoke as rs
from proto_s5t2 import bm25_docs

_orig = core.search
W = 0.0
ROOTS: list[str] = []


def title_tokens(path):
    parts = path.split("/")
    if ROOTS and parts[0] in ROOTS:
        parts = parts[1:]
    name = parts[-1]
    dot = name.rfind(".")
    words = parts[:-1] + [name[:dot] if dot > 0 else name]
    out = []
    for w in words:
        out += core._filename_tokenize(w)
    return out


def patched(index, query, *, top_k=5, candidate_k=100, path_prefix=None, retrieval_mode="hybrid",
            embedding_provider=None, principal_labels=(), search_field="content"):
    if not W or search_field != "content" or retrieval_mode != "lexical":
        return _orig(index, query, top_k=top_k, candidate_k=candidate_k, path_prefix=path_prefix,
                     retrieval_mode=retrieval_mode, embedding_provider=embedding_provider,
                     principal_labels=principal_labels, search_field=search_field)
    principal_labels = tuple(principal_labels)
    chunks = [c for c in index["chunks"]
              if (path_prefix is None or c["path"].startswith(path_prefix))
              and core.is_authorized(c.get("required_labels", []), principal_labels)]
    s = dict(core._bm25_scores(chunks, core.tokenize(query)))
    by_path = defaultdict(list)
    for c in chunks:
        by_path[c["path"]].append(c)
    docs = {}
    for p in by_path:
        t = title_tokens(p)
        docs[p] = {"terms": dict(Counter(t)), "length": len(t)}
    qt = sorted(set(core._filename_tokenize(query)))
    t = bm25_docs(docs, qt)
    by_id = {c["id"]: c for c in chunks}
    best = {}
    for cid, v in s.items():
        p = by_id[cid]["path"]
        if p not in best or v > s[best[p]] or (v == s[best[p]] and cid.encode() < best[p].encode()):
            best[p] = cid
    for p, tv in t.items():
        if tv <= 0:
            continue
        frac = sum(1 for x in qt if x in docs[p]["terms"]) / len(qt)
        target = best.get(p) or min(by_path[p], key=lambda c: (c["start_line"], c["end_line"], c["id"].encode()))["id"]
        s[target] = s.get(target, 0.0) + W * tv * frac
    ordered = sorted(((cid, v) for cid, v in s.items() if v > 0), key=lambda it: (-it[1], it[0]))[:top_k]
    return [{"chunk_id": cid, "citation": {"path": by_id[cid]["path"], "start_line": by_id[cid]["start_line"],
             "end_line": by_id[cid]["end_line"]}, "content": by_id[cid]["text"], "score": v,
             "ranking": {"lexical": {"rank": r, "score": v}, "vector": {"rank": None, "score": None, "mode": "none"}}}
            for r, (cid, v) in enumerate(ordered, start=1)]


core.search = evaluation.search = rs.search = patched


def ev(corpus, suite, top_k=10):
    if corpus == "fixtures/tamil/passages":
        import shutil, tempfile
        tmp = Path(tempfile.mkdtemp())
        shutil.copytree(corpus, tmp / "passages")
        corpus = tmp
    index = core.build_index(Path(corpus))
    out = evaluation.evaluate_modes(index, evaluation.load_suite(Path(suite)), ["lexical"], top_k=top_k)
    m = out["reports"][0]
    per = {q["id"]: q["first_relevant_rank"] for q in m["queries"]}
    keys = ("mean_ndcg_at_k", "mean_reciprocal_rank", "macro_recall_at_k", "success_at_k")
    return {k: round(m[k], 4) for k in keys if k in m}, per


def main():
    global W, ROOTS
    for w in map(float, sys.argv[1:]):
        W = w
        ROOTS = []
        res = {}
        for name, corpus, suite in (("relevance-smoke", "fixtures/relevance-smoke/corpus", "fixtures/relevance-smoke/judgments.json"),
                                    ("knowledge", "fixtures/knowledge", "fixtures/judgments.json"),
                                    ("mixed", "fixtures/mixed-knowledge", "fixtures/mixed-judgments.json"),
                                    ("tamil", "fixtures/tamil/passages", "fixtures/tamil/judgments.json"),
                                    ("semantic", "fixtures/semantic-knowledge", "fixtures/semantic-judgments.json")):
            res[name] = ev(corpus, suite)
        ROOTS = json.loads((rs.PACKS["family-folder"] / "judgments.json").read_text())["roots"]
        with contextlib.redirect_stdout(io.StringIO()):
            pack = rs.run_pack("family-folder")
        res["family-folder"] = {"words_recall_at_k": pack["words_recall_at_k"], "exactness": pack["exactness"],
                                "find_metrics": pack["find_metrics"],
                                "cases": {c["id"]: c["recall"] for c in pack["words_cases"]}}
        print(f"=== w={w}")
        for k, v in res.items():
            print(k, json.dumps(v[0] if isinstance(v, tuple) else v, sort_keys=True)[:900])
            if isinstance(v, tuple):
                print("   per-query", json.dumps(v[1], sort_keys=True)[:1500])


main()

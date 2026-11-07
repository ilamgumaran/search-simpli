#!/usr/bin/env python3
"""S5-T2 prototype (planner scratch, not committed): a title/path field on J2,
through the Python reference's own scoring (core._bm25_scores, tokenize,
_filename_tokenize) and the S5-T1 metric code (relevance_smoke.j2_*).

Run from a checkout of the repo that holds fixtures/j2 (task/S5-T1 or later):
    PYTHONHASHSEED=0 python3 proto_s5t2.py [--json OUT] [--detail]

The title field of a file: the root-relative folder names and the file stem,
tokenized with _filename_tokenize (analyzer-v2 simple fold, the filename
channel's analyzer, which mirrors Zig), one document per file; BM25 (k1 1.2,
b 0.75) over the files. Candidates are named in CANDIDATES below.
"""
from __future__ import annotations

import argparse
import json
import math
import shutil
import sys
import tempfile
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path.cwd()
sys.path.insert(0, str(ROOT))

from relevance_smoke import (  # noqa: E402
    J2_TOP_K, j2_record, j2_summarise, PACKS,
)
from src.search_platform.core import (  # noqa: E402
    _bm25_scores, _filename_tokenize, build_index, tokenize,
)
from src.search_platform.find import find  # noqa: E402

K = J2_TOP_K
CANDIDATE_K = 100


def bm25_docs(docs: dict[str, dict], terms: list[str], k1=1.2, b=0.75) -> dict[str, float]:
    """BM25 over {key: {terms, length}} (the same formula as core._bm25_scores)."""
    if not docs or not terms:
        return {}
    df = Counter()
    for d in docs.values():
        df.update(d["terms"].keys())
    avg = sum(d["length"] for d in docs.values()) / len(docs)
    n = len(docs)
    out: dict[str, float] = defaultdict(float)
    for key, d in docs.items():
        for t in sorted(set(terms)):
            f = d["terms"].get(t, 0)
            if not f:
                continue
            idf = math.log(1.0 + (n - df[t] + 0.5) / (df[t] + 0.5))
            out[key] += idf * (f * (k1 + 1.0) / (f + k1 * (1.0 - b + b * d["length"] / avg)))
    return dict(out)


def title_text(path: str, roots: list[str], *, folders=True, root=False, stem=True) -> list[str]:
    parts = path.split("/")
    if parts[0] in roots and not root:
        parts = parts[1:]
    name = parts[-1]
    dot = name.rfind(".")
    stem_text = name[:dot] if dot > 0 else name
    words = []
    if folders:
        words += parts[:-1]
    if stem:
        words.append(stem_text)
    tokens = []
    for w in words:
        tokens += _filename_tokenize(w)
    return tokens


class World:
    def __init__(self, index: dict, roots: list[str]):
        self.index = index
        self.roots = roots
        self.chunks = index["chunks"]
        self.by_id = {c["id"]: c for c in self.chunks}
        self.by_path: dict[str, list[dict]] = defaultdict(list)
        for c in self.chunks:
            self.by_path[c["path"]].append(c)
        self.anchor = {p: min(cs, key=lambda c: (c["start_line"], c["end_line"], c["id"].encode()))
                       for p, cs in self.by_path.items()}
        self.fname = {r["path"]: r for r in index["filename_index"]["records"]}
        self._title_cache = {}

    def title_docs(self, kind: str) -> dict[str, dict]:
        if kind not in self._title_cache:
            opts = {"fs": dict(), "fsr": dict(root=True), "s": dict(folders=False)}[kind]
            docs = {}
            for p in self.by_path:
                toks = title_text(p, self.roots, **opts)
                docs[p] = {"terms": dict(Counter(toks)), "length": len(toks)}
            self._title_cache[kind] = docs
        return self._title_cache[kind]


def hit(world: World, chunk: dict, score: float) -> dict:
    root, _, rest = chunk["path"].partition("/")
    return {"root_id": root, "path": rest, "start_line": chunk["start_line"], "end_line": chunk["end_line"],
            "score": score, "chunk_id": chunk["id"]}


def body_scores(world: World, query: str) -> dict[str, float]:
    return _bm25_scores(world.chunks, tokenize(query))


def per_file_best(world: World, scores: dict[str, float]) -> tuple[dict[str, float], dict[str, dict]]:
    best_s: dict[str, float] = {}
    best_c: dict[str, dict] = {}
    for cid, s in scores.items():
        c = world.by_id[cid]
        p = c["path"]
        prev = best_s.get(p)
        if prev is None or s > prev or (s == prev and cid.encode() < best_c[p]["id"].encode()):
            best_s[p] = s
            best_c[p] = c
    return best_s, best_c


def file_ranks(world: World, scores: dict[str, float]) -> dict[str, int]:
    ordered = sorted(((p, s) for p, s in scores.items() if s > 0),
                     key=lambda it: (-it[1], it[0].encode(), world.anchor[it[0]]["id"].encode()))
    return {p: r for r, (p, _) in enumerate(ordered, start=1) if r <= CANDIDATE_K}


# ---------------------------------------------------------------- content --

def content_baseline(world, query):
    s = body_scores(world, query)
    ordered = sorted(((cid, v) for cid, v in s.items() if v > 0), key=lambda it: (-it[1], it[0]))[:K]
    return [hit(world, world.by_id[cid], v) for cid, v in ordered]


def coord(world, query, kind, p):
    """(query title terms present in the file's title / distinct query title terms) ** p."""
    terms = sorted(set(_filename_tokenize(query)))
    docs = world.title_docs(kind)
    if not terms:
        return {}
    return {path: (sum(1 for t in terms if t in d["terms"]) / len(terms)) ** p for path, d in docs.items()}


def content_title(world, query, *, w, spread, kind="fs", p=0):
    """chunk score = body BM25 + w * title BM25 of its file.
    spread 'all': every chunk with a body score gets the title part; a title-only
    file's anchor chunk gets it alone. 'best': only the file's best body chunk (or
    its anchor) gets it, one title part per file."""
    s = dict(body_scores(world, query))
    t = bm25_docs(world.title_docs(kind), _filename_tokenize(query))
    if p:
        cf = coord(world, query, kind, p)
        t = {path: v * cf[path] for path, v in t.items()}
    if w and t:
        best_s, best_c = per_file_best(world, s)
        for p, tv in t.items():
            if tv <= 0:
                continue
            if spread == "all" and p in best_s:
                for c in world.by_path[p]:
                    if s.get(c["id"], 0) > 0:
                        s[c["id"]] += w * tv
            else:
                target = best_c[p]["id"] if p in best_c else world.anchor[p]["id"]
                s[target] = s.get(target, 0.0) + w * tv
    ordered = sorted(((cid, v) for cid, v in s.items() if v > 0), key=lambda it: (-it[1], it[0]))[:K]
    return [hit(world, world.by_id[cid], v) for cid, v in ordered]


# ------------------------------------------------------------------- both --

def both_rrf(world, query, *, alpha=1.0, beta=1.0, channel="stem", kind="fs"):
    """Per file: beta/(60+body rank) + alpha/(60+name rank). channel 'stem' is
    today's filename channel (stem only, its BM25 over the catalog); 'title' the
    folders+stem field. alpha = beta = 1 with 'stem' is today's `both`."""
    terms = _filename_tokenize(query)
    if not terms:
        return []
    raw = _bm25_scores(world.chunks, terms)  # today's both: body terms are the filename tokens
    best_s, best_c = per_file_best(world, raw)
    br = file_ranks(world, best_s)
    if channel == "stem":
        docs = {p: {"terms": r["terms"], "length": r["length"]} for p, r in world.fname.items()}
        ns = _bm25_scores([{"id": p, **d} for p, d in docs.items()], terms)
    else:
        ns = bm25_docs(world.title_docs(kind), terms)
    nr = file_ranks(world, ns)
    fused: dict[str, float] = defaultdict(float)
    for p, r in br.items():
        fused[p] += beta / (60.0 + r)
    for p, r in nr.items():
        fused[p] += alpha / (60.0 + r)
    ordered = sorted(fused.items(), key=lambda it: (-it[1], it[0].encode()))[:K]
    return [hit(world, best_c.get(p, world.anchor[p]), v) for p, v in ordered]


def both_merge(world, query, *, w, kind="fs", p=0):
    """Score-level merge: per file, the best body chunk's BM25 + w * title BM25;
    the cited chunk is the best body chunk (the anchor for a title-only file)."""
    terms = _filename_tokenize(query)
    if not terms:
        return []
    raw = _bm25_scores(world.chunks, terms)
    best_s, best_c = per_file_best(world, raw)
    t = bm25_docs(world.title_docs(kind), terms)
    if p:
        cf = coord(world, query, kind, p)
        t = {path: v * cf[path] for path, v in t.items()}
    score = dict(best_s)
    for p, tv in t.items():
        if tv > 0:
            score[p] = score.get(p, 0.0) + w * tv
    ordered = sorted(((p, v) for p, v in score.items() if v > 0), key=lambda it: (-it[1], it[0].encode()))[:K]
    return [hit(world, best_c.get(p, world.anchor[p]), v) for p, v in ordered]


# ---------------------------------------------------------------- driver --

WEIGHTS = (0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0)
ALPHAS = (0.25, 0.5, 0.75)


def candidates():
    c = {"baseline": ("content_baseline", {}, "both_rrf", {})}
    for kind in ("fs", "s", "fsr"):
        for spread in ("best", "all"):
            for w in WEIGHTS:
                if kind != "fs" and w not in (0.5, 1.0, 1.5):
                    continue
                c[f"T-{kind}-{spread}-w{w}"] = ("content_title", dict(w=w, spread=spread, kind=kind),
                                                "both_merge", dict(w=w, kind=kind))
    for pw in (1, 2):
        for w in (1.0, 1.5, 2.0, 2.25, 2.5, 2.75, 3.0, 3.5, 4.0, 5.0):
            c[f"C{pw}-fs-best-w{w}"] = ("content_title", dict(w=w, spread="best", kind="fs", p=pw),
                                       "both_merge", dict(w=w, kind="fs", p=pw))
    for w in (2.5, 3.0):
        c[f"C1-fs-all-w{w}"] = ("content_title", dict(w=w, spread="all", kind="fs", p=1), "both_merge", dict(w=w, kind="fs", p=1))
        c[f"C1-fsr-best-w{w}"] = ("content_title", dict(w=w, spread="best", kind="fsr", p=1), "both_merge", dict(w=w, kind="fsr", p=1))
        c[f"C1-s-best-w{w}"] = ("content_title", dict(w=w, spread="best", kind="s", p=1), "both_merge", dict(w=w, kind="s", p=1))
    for a in ALPHAS:
        c[f"WRRF-stem-a{a}"] = ("content_baseline", {}, "both_rrf", dict(alpha=a))
        c[f"WRRF-title-a{a}"] = ("content_baseline", {}, "both_rrf", dict(alpha=a, channel="title"))
    c["RRF-title-a1"] = ("content_baseline", {}, "both_rrf", dict(alpha=1.0, channel="title"))
    return c


FUNCS = {"content_baseline": content_baseline, "content_title": content_title,
         "both_rrf": both_rrf, "both_merge": both_merge}


def run(world, judgments, cname, spec):
    cf, ck, bf, bk = spec
    found = {}
    for q in judgments["queries"]:
        if q["mode"].startswith("find:"):
            out = []
            for h in find(world.index, q["query"], mode=q["mode"].split(":", 1)[1], page_size=K)["hits"]:
                root, _, rest = h["path"].partition("/")
                out.append({"root_id": root, "path": rest, "start_line": h["start_line"],
                            "end_line": h["end_line"], "score": h["score"], "chunk_id": h.get("chunk_id")})
            found[q["id"]] = out
    runs = {}
    for variant, (fn, kw) in (("content", (cf, ck)), ("both", (bf, bk))):
        recs = {}
        for q in judgments["queries"]:
            hits = found[q["id"]] if q["id"] in found else FUNCS[fn](world, q["query"], **kw)
            recs[q["id"]] = j2_record(q, hits)
        runs[variant] = j2_summarise(judgments, recs)
    return runs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json")
    ap.add_argument("--detail", action="store_true")
    ap.add_argument("--only", nargs="*")
    args = ap.parse_args()
    pack = PACKS["j2"]
    judgments = json.loads((pack / "judgments.json").read_text(encoding="utf-8"))
    with tempfile.TemporaryDirectory() as scratch:
        union = Path(scratch) / "union"
        for root in judgments["roots"]:
            shutil.copytree(pack / root, union / root)
        index = build_index(union, filename_index=True)
    world = World(index, judgments["roots"])
    results = {}
    for name, spec in candidates().items():
        if args.only and name not in args.only:
            continue
        results[name] = run(world, judgments, name, spec)
    # check: the reimplemented baseline equals the committed Python baseline
    base = json.loads((pack / "baseline.json").read_text())["surfaces"]["python-reference"]["runs"]
    for v in ("content", "both"):
        if "baseline" not in results:
            break
        for qid, r in base[v]["first_grade2_rank"].items():
            mine = results["baseline"][v]["queries"][qid].get("first_grade2_rank")
            if r != mine:
                print(f"BASELINE MISMATCH {v} {qid} {r} {mine}", file=sys.stderr)
        for sl, m in base[v]["slices"].items():
            if m != results["baseline"][v]["slices"][sl]:
                print(f"BASELINE MISMATCH {v} slice {sl}", file=sys.stderr)
    slices = ("control", "misspelling", "morphology", "accent", "tamil", "title", "phrase")
    print("candidate | variant | " + " | ".join(slices) + " | overall   (success@1 / MRR@10)")
    for name, runs in results.items():
        for v in ("content", "both"):
            cells = [f"{runs[v]['slices'][s]['success_at_1']:.3f}/{runs[v]['slices'][s]['mrr_at_10']:.3f}" for s in slices]
            o = runs[v]["overall"]
            print(f"{name} | {v} | " + " | ".join(cells) + f" | {o['success_at_1']:.3f}/{o['mrr_at_10']:.3f}")
    if args.detail:
        focus = [q["id"] for q in judgments["queries"] if q["slice"] == "title"] + ["c02", "c06", "c07"]
        for name, runs in results.items():
            for v in ("content", "both"):
                ranks = {qid: runs[v]["queries"][qid]["first_grade2_rank"] for qid in focus}
                print(f"RANKS {name} {v} " + " ".join(f"{q}={ranks[q]}" for q in focus))
    if args.json:
        Path(args.json).write_text(json.dumps(results, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()

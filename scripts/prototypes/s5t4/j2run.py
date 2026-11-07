"""S5-T4 prototype (planner scratch): J2 through the Python reference with a
candidate analyzer installed, index side (a rebuild) or query side only (no
rebuild). Mirrors `relevance_smoke.run_j2_pack` with one hook between the build
and the queries; with no candidate it must equal the committed baseline's
Python cells (checked by proto_s5t4.py)."""
from __future__ import annotations

import json
import shutil
import tempfile
from collections import Counter
from pathlib import Path

import analyzer_v3 as v3
from analyzer_v3 import Cfg, replace

import relevance_smoke as rs  # noqa: E402  (sys.path set by analyzer_v3)
import src.search_platform.core as core  # noqa: E402
from src.search_platform.find import find  # noqa: E402,F401
import src.search_platform.find as findmod  # noqa: E402

PACK = rs.PACKS["j2"]
JUDGMENTS = json.loads((PACK / "judgments.json").read_text(encoding="utf-8"))
LOG: dict = {}


def _title_tokens_stop(path, root_ids):
    return tuple(t for t in v3.ORIG["_title_tokens"](path, root_ids) if t not in v3.STOP)


def _title_scores_stop(visible_chunks, query, root_ids, weight, groups=None):
    """core._title_scores with stop words left out of the query's title terms."""
    terms = sorted(set(t for t in core._filename_tokenize(query) if t not in v3.STOP))
    if not terms or not weight:
        return {}
    fields = core._title_fields(visible_chunks, root_ids)
    docs = [{"id": path, "terms": Counter(tokens), "length": len(tokens)} for path, tokens in fields.items()]
    active = {term: groups[term] for term in terms if term in groups} if groups else {}
    out = {}
    for path, score in core._bm25_scores(docs, terms, active).items():
        held = set(fields[path])
        coverage = sum(1 for term in terms if term in held
                       or any(member in held for member, _ in active.get(term, ()))) / len(terms)
        out[path] = weight * (score * coverage)
    return out


def install_groups(cfg: Cfg):
    """Query side: each query term is also searched as the dictionary (and visible
    title) terms whose v3 key equals its key (`query-groups`), or as its own key
    only (`query-naive`); scored as one word with fuzzy-v1's machinery (max df,
    best member per chunk, weight 1.0). Fuzzy-v1 runs as today for the rest."""
    keycfg = replace(cfg, side="index")

    def key(t):
        k = v3._key_cached(t, keycfg)
        return k[0] if len(k) == 1 else (t if not k else " ".join(k))

    def groups_fn(chunks, visible, terms, root_ids, path_prefix=None):
        terms = set(terms)
        body_df: Counter = Counter()
        for chunk in chunks:
            body_df.update(chunk["terms"].keys())
        fields = core._title_fields(visible, root_ids)
        title_vocab = {tok for toks in fields.values() for tok in toks}
        vocab = set(body_df) | title_vocab
        by_key: dict = {}
        if cfg.side == "query-groups":
            for d in vocab:
                by_key.setdefault(key(d), set()).add(d)
        out = {}
        for t in sorted(terms):
            k = key(t)
            if cfg.side == "query-groups":
                members = by_key.get(k, set())
            else:
                members = {m for m in (t, k) if m in vocab}
            if members and members != {t}:
                order = sorted(members, key=lambda m: (m != t, -body_df.get(m, 0), m.encode("utf-8")))
                out[t] = tuple((m, 1.0) for m in order)
        rest = [t for t in terms if t not in out]
        fz = v3.ORIG["_fuzzy_query_groups"](chunks, visible, rest, root_ids, path_prefix) if rest else {}
        for t, g in out.items():
            LOG.setdefault("groups", {}).setdefault(t, [m for m, _ in g])
        for t, g in fz.items():
            LOG.setdefault("fuzzy", {}).setdefault(t, [m for m, _ in g])
        out.update(fz)
        return out

    core._fuzzy_query_groups = groups_fn


def install_fuzzy_log():
    def fz(chunks, visible, terms, root_ids, path_prefix=None):
        g = v3.ORIG["_fuzzy_query_groups"](chunks, visible, terms, root_ids, path_prefix)
        for t, m in g.items():
            LOG.setdefault("fuzzy", {}).setdefault(t, [x for x, _ in m])
        return g
    core._fuzzy_query_groups = fz


def strip_stop(query: str) -> str:
    toks = core._filename_tokenize(query)
    kept = [t for t in toks if t not in v3.STOP]
    return " ".join(kept) if kept and len(kept) < len(toks) else query


def run(cfg: Cfg | None, judgments: dict | None = None, pack_dir: Path = PACK) -> dict:
    judgments = judgments or JUDGMENTS
    LOG.clear()
    v3.restore()
    try:
        with tempfile.TemporaryDirectory() as scratch:
            union = Path(scratch) / "union"
            for root in judgments["roots"]:
                shutil.copytree(pack_dir / root, union / root)
            if cfg is None:
                pass
            elif cfg.side == "index":
                v3.set_analyzers(v3.body_cfg(cfg), v3.filename_cfg(cfg))
            else:
                base = v3.base_cfg(cfg)
                v3.set_analyzers(base if cfg.base_fold != "full" else None, None)
            index = core.build_index(union, filename_index=True)
            if cfg is not None and cfg.side != "index":
                install_groups(cfg)
            else:
                install_fuzzy_log()
            if cfg is not None and cfg.stop_title:
                core._title_tokens = _title_tokens_stop
                core._title_scores = _title_scores_stop

            def split(path):
                root, _, rest = path.partition("/")
                return root, rest

            def knowledge(query, field):
                if cfg is not None and cfg.stop_query:
                    query = strip_stop(query)
                out = []
                for r in core.search(index, query, top_k=rs.J2_TOP_K, retrieval_mode="lexical", search_field=field,
                                     title_root_ids=judgments["roots"]):
                    root, rest = split(r["citation"]["path"])
                    score = r["ranking"]["lexical"]["score"] if field == "content" else r["score"]
                    out.append({"root_id": root, "path": rest, "start_line": r["citation"]["start_line"],
                                "end_line": r["citation"]["end_line"], "score": score, "chunk_id": r.get("chunk_id")})
                return out

            def find_page(query, mode):
                out = []
                for h in findmod.find(index, query, mode=mode, page_size=rs.J2_TOP_K)["hits"]:
                    root, rest = split(h["path"])
                    out.append({"root_id": root, "path": rest, "start_line": h["start_line"], "end_line": h["end_line"],
                                "score": h["score"], "chunk_id": h.get("chunk_id")})
                return out

            runs = rs.j2_run_queries(judgments, knowledge, find_page)
            vocab = Counter()
            for c in index["chunks"]:
                vocab.update(c["terms"].keys())
    finally:
        v3.restore()
    return {"runs": runs, "log": dict(LOG), "vocab": vocab}

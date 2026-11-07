"""S5-T3 prototype (planner scratch): query-time misspelling expansion for the
Python reference, patched over `core._bm25_scores` and `core._title_scores`.

Nothing here is the engine. It is the smallest code that measures the candidates
of the S5-T3 plan on J2 and the old packs through the reference's own scoring.

A query term is a *trigger* when its document frequency over the chunks being
scored is at most `Cfg.df_max` (0: absent from every chunk) and, with
`title_guard`, it is also absent from every visible file's title field. A trigger
is expanded to the dictionary terms within an edit bound (optimal string
alignment, Damerau, counted on code points), at most `max_expansions` of them,
ordered by (distance, -df, bytes). The expansions of one query term form a
*group*: within a chunk the group contributes the best of its terms (`combine`
"max") or their sum ("sum"), each term's BM25 computed with one blended document
frequency for the whole group (`blend`), times a weight below 1.

With `Cfg` None (or no trigger in a query) every score is the reference's own,
bit for bit: the groups are summed in the same sorted order with the same
operations.
"""
from __future__ import annotations

import math
import unicodedata
from collections import Counter, defaultdict
from dataclasses import dataclass, field, replace

import src.search_platform.core as core

ORIG_BM25 = core._bm25_scores
ORIG_TITLE = core._title_scores
K1, B = 1.2, 0.75


@dataclass(frozen=True)
class Cfg:
    name: str = "x"
    df_max: int = 0              # trigger when df <= df_max (0: absent only)
    d1_min: int = 3              # shortest term (code points) allowed distance 1
    d2_min: int = 6              # shortest term allowed distance 2 (99: never)
    first_letter: bool = True    # an expansion keeps the query term's first code point
    max_expansions: int = 3      # N
    weight: float = 0.8          # flat weight on an expansion's contribution
    damp: bool = False           # weight *= 1 - d / len(query term)
    blend: str = "max"           # max | sum | union | own
    combine: str = "max"         # max | sum (within one chunk, over a group's terms)
    title: bool = True           # expansions also feed the title field
    title_guard: bool = True     # a term held by a visible title is not a trigger
    latin_only: bool = False     # expand only terms with no code point outside Latin/digits
    prefix: int = 0              # also take dictionary terms the query term prefixes (len >= prefix; 0 off)
    keep_low: bool = True        # df_max > 0: the trigger keeps its own exact term in its group
    w2: float | None = None      # weight for a distance-2 expansion (None: `weight`)
    min_dist_only: bool = False  # keep only the expansions at the smallest distance found
    accent_first: bool = False   # an expansion equal to the term once marks are stripped sorts first
    cand_title: bool = False     # candidates also from the visible title terms (a word only a file name holds)


OFF = None
STATE: dict = {"cfg": None, "log": None}


def osa_bounded(a: str, b: str, k: int) -> int | None:
    """OSA distance between two code-point strings when <= k, else None."""
    la, lb = len(a), len(b)
    if abs(la - lb) > k:
        return None
    prev2 = None
    prev = list(range(lb + 1))
    for i in range(1, la + 1):
        cur = [i] + [0] * lb
        best = cur[0]
        ai = a[i - 1]
        for j in range(1, lb + 1):
            cost = 0 if ai == b[j - 1] else 1
            v = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            if prev2 is not None and j > 1 and ai == b[j - 2] and a[i - 2] == b[j - 1]:
                v = min(v, prev2[j - 2] + 1)
            cur[j] = v
            if v < best:
                best = v
        if best > k:
            return None
        prev2, prev = prev, cur
    return prev[lb] if prev[lb] <= k else None


def is_latin(term: str) -> bool:
    for ch in term:
        if ch.isdigit():
            continue
        if not unicodedata.name(ch, "").startswith("LATIN"):
            return False
    return True


def max_distance(cfg: Cfg, term: str) -> int:
    n = len(term)
    if n >= cfg.d2_min:
        return 2
    if n >= cfg.d1_min:
        return 1
    return 0


def candidates(cfg: Cfg, term: str, df: Counter) -> list[tuple[str, int]]:
    """(dictionary term, distance), best first, at most N; `df` is the scored
    chunks' document frequency (its keys are the dictionary)."""
    k = max_distance(cfg, term)
    if cfg.latin_only and not is_latin(term):
        return []
    found = []
    for t in df:
        if t == term or df[t] == 0:
            continue
        if cfg.first_letter and t[:1] != term[:1]:
            continue
        d = osa_bounded(term, t, k) if k else None
        if d is None and cfg.prefix and len(term) >= cfg.prefix and t.startswith(term):
            d = 1  # a prefix completion ranks with distance-1 expansions
        if d is None or d == 0:
            continue
        found.append((t, d))
    found.sort(key=lambda it: (it[1], -df[it[0]], it[0].encode("utf-8")))
    return finish(cfg, term, found)


def strip_marks(term: str) -> str:
    return "".join(ch for ch in unicodedata.normalize("NFD", term) if unicodedata.category(ch) != "Mn")


def finish(cfg: Cfg, term: str, found: list[tuple[str, int]]) -> list[tuple[str, int]]:
    """The ordering options and the cut to N, over the (distance, -df, bytes) order."""
    if cfg.accent_first:
        bare = strip_marks(term)
        found = sorted(found, key=lambda it: 0 if strip_marks(it[0]) == bare else 1)  # stable
    if cfg.min_dist_only and found:
        least = min(d for _, d in found)
        found = [it for it in found if it[1] == least]
    return found[: cfg.max_expansions]


def term_weight(cfg: Cfg, term: str, d: int) -> float:
    w = cfg.weight if (d < 2 or cfg.w2 is None) else cfg.w2
    if cfg.damp:
        w *= 1.0 - d / max(len(term), 1)
    return w


# The title field's vocabulary over the visible files, per call (the reference
# rebuilds the field per call as well).
def _title_vocab(visible_chunks, root_ids) -> set:
    vocab = set()
    seen = set()
    for c in visible_chunks:
        if c["path"] in seen:
            continue
        seen.add(c["path"])
        vocab.update(core._title_tokens(c["path"], root_ids))
    return vocab


def groups_for(cfg: Cfg, terms: list[str], df: Counter, title_vocab: set | None) -> list[tuple[str, list[tuple[str, float, int]]]]:
    """[(query term, [(term, weight, distance), ...])] in sorted query-term order.
    A non-trigger's group is [(itself, 1.0, 0)]."""
    out = []
    for q in sorted(set(terms)):
        trig = df.get(q, 0) <= cfg.df_max
        if trig and cfg.title_guard and title_vocab is not None and q in title_vocab:
            trig = False
        if not trig:
            out.append((q, [(q, 1.0, 0)]))
            continue
        pool = df
        if cfg.cand_title and title_vocab:
            pool = Counter(df)
            for t in title_vocab:
                if pool.get(t, 0) == 0:
                    pool[t] = 1  # a title-only term: present, ordered as a rare body term
        exp = candidates(cfg, q, pool)
        members = []
        if df.get(q, 0) > 0 and cfg.keep_low:
            members.append((q, 1.0, 0))
        members += [(t, term_weight(cfg, q, d), d) for t, d in exp]
        if not members:
            members = [(q, 1.0, 0)]
        out.append((q, members))
        if STATE["log"] is not None and exp:
            STATE["log"].append({"term": q, "df": df.get(q, 0), "expansions": [(t, d, df[t]) for t, d in exp]})
    return out


def _blended_df(cfg: Cfg, members, df: Counter, chunks, n: int) -> dict[str, int]:
    if len(members) == 1 and members[0][2] == 0:
        return {members[0][0]: df.get(members[0][0], 0)}
    if cfg.blend == "own":
        return {t: df.get(t, 0) for t, _, _ in members}
    if cfg.blend == "max":
        v = max(df.get(t, 0) for t, _, _ in members)
    elif cfg.blend == "sum":
        v = min(n, sum(df.get(t, 0) for t, _, _ in members))
    elif cfg.blend == "union":
        names = {t for t, _, _ in members}
        v = sum(1 for c in chunks if names.intersection(c["terms"]))
    else:
        raise ValueError(cfg.blend)
    return {t: v for t, _, _ in members}


def _score_groups(cfg: Cfg, docs: list[dict], groups, df: Counter) -> dict[str, float]:
    if not docs:
        return {}
    n = len(docs)
    avg = sum(d["length"] for d in docs) / n
    gdfs = [_blended_df(cfg, members, df, docs, n) for _, members in groups]
    scores: dict[str, float] = defaultdict(float)
    for d in docs:
        dl = d["length"]
        for (q, members), gdf in zip(groups, gdfs):
            if len(members) == 1 and members[0][2] == 0:
                t = members[0][0]
                f = d["terms"].get(t, 0)
                if not f:
                    continue
                dft = gdf[t]
                idf = math.log(1.0 + (n - dft + 0.5) / (dft + 0.5))
                scores[d["id"]] += idf * (f * (K1 + 1.0) / (f + K1 * (1.0 - B + B * dl / avg)))
                continue
            parts = []
            for t, w, _ in members:
                f = d["terms"].get(t, 0)
                if not f:
                    continue
                dft = gdf[t]
                idf = math.log(1.0 + (n - dft + 0.5) / (dft + 0.5))
                parts.append(w * idf * (f * (K1 + 1.0) / (f + K1 * (1.0 - B + B * dl / avg))))
            if parts:
                scores[d["id"]] += max(parts) if cfg.combine == "max" else sum(parts)
    return dict(scores)


def patched_bm25(chunks, query_terms):
    cfg: Cfg | None = STATE["cfg"]
    # Only body chunks: the file-name records (`anchor_id`) and the title documents
    # keep the reference's own scoring.
    if cfg is None or not chunks or not query_terms or "start_line" not in chunks[0] or "anchor_id" in chunks[0]:
        return ORIG_BM25(chunks, query_terms)
    df: Counter = Counter()
    for c in chunks:
        df.update(c["terms"].keys())
    tv = _title_vocab(chunks, STATE["root_ids"]) if cfg.title_guard else None
    groups = groups_for(cfg, list(query_terms), df, tv)
    if all(len(m) == 1 and m[0][2] == 0 for _, m in groups):
        return ORIG_BM25(chunks, query_terms)
    return _score_groups(cfg, chunks, groups, df)


def patched_title(visible_chunks, query, root_ids, weight):
    cfg: Cfg | None = STATE["cfg"]
    if cfg is None or not cfg.title:
        return ORIG_TITLE(visible_chunks, query, root_ids, weight)
    terms = sorted(set(core._filename_tokenize(query)))
    if not terms or not weight:
        return {}
    df: Counter = Counter()
    for c in visible_chunks:
        df.update(c["terms"].keys())
    fields: dict[str, tuple] = {}
    for c in visible_chunks:
        if c["path"] not in fields:
            fields[c["path"]] = core._title_tokens(c["path"], root_ids)
    tv = set()
    for toks in fields.values():
        tv.update(toks)
    saved = STATE["log"]
    STATE["log"] = None
    groups = groups_for(cfg, terms, df, tv if cfg.title_guard else None)
    STATE["log"] = saved
    if all(len(m) == 1 and m[0][2] == 0 for _, m in groups):
        return ORIG_TITLE(visible_chunks, query, root_ids, weight)
    docs = [{"id": p, "terms": Counter(t), "length": len(t)} for p, t in fields.items()]
    tdf: Counter = Counter()
    for d in docs:
        tdf.update(d["terms"].keys())
    raw = _score_groups(cfg, docs, groups, tdf)
    out = {}
    for path, score in raw.items():
        held = set(fields[path])
        covered = sum(1 for _, members in groups if any(t in held for t, _, _ in members))
        out[path] = weight * (score * (covered / len(terms)))
    return out


def install(cfg: Cfg | None, root_ids=()):
    STATE["cfg"] = cfg
    STATE["root_ids"] = tuple(root_ids)
    core._bm25_scores = patched_bm25
    core._title_scores = patched_title


__all__ = ["Cfg", "install", "STATE", "osa_bounded", "candidates", "replace"]

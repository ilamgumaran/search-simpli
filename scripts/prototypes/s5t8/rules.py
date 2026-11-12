"""S5-T8 prototype (builder, Phase 1b): the candidates of docs/tasks/S5-T8.md ruling
2, as declared in docs/tasks/S5-T8-prototype.md, as hooks over the Python
reference's module functions. Nothing here edits the engine: `install(names)`
swaps the functions a candidate touches and `restore()` puts today's back.

- W   `core._title_scores`: a stop word does not score against the title field and
      does not count in title coverage (the body is unchanged).
- Wb  `core._bm25_scores` on body chunks: the stop words are dropped from the body
      query when the question holds at least one other word.
- F   `core._fuzzy_groups`: a near word is kept only if it passes the floor.
- X   `core._fold_groups`: R's forms pass an eligibility rule for the e shapes and
      the look-alike remainders.

Run from a checkout (the working directory is the repository root)."""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path.cwd()
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import src.search_platform.core as core  # noqa: E402
from src.search_platform import analyzer_v3, verb_forms  # noqa: E402

# Lucene's 33 English stop words (EnglishAnalyzer.ENGLISH_STOP_WORDS_SET) and `my`:
# the list fixtures/j2/README.md's measure reads (judgments.json `stop_words`).
LUCENE_33 = ("a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "if", "in", "into", "is", "it",
             "no", "not", "of", "on", "or", "such", "that", "the", "their", "then", "there", "these", "they",
             "this", "to", "was", "will", "with")
STOP = frozenset(LUCENE_33 + ("my",))

ORIGINAL = {name: getattr(core, name) for name in ("_title_scores", "_bm25_scores", "_fuzzy_groups", "_fold_groups")}
LOG: dict = {}


def _log(kind: str, key, value) -> None:
    LOG.setdefault(kind, {})[key] = value


# ------------------------------------------------------------------- W --

def make_w(all_stop_keeps: bool):
    """W: the title part scores and covers only the query's non-stop words. With
    `all_stop_keeps`, a query whose every title word is a stop word is left as today
    (W as declared); without it (W0, the literal reading), such a query has no title
    part."""
    inner = ORIGINAL["_title_scores"]

    def title_scores(visible_chunks, query, root_ids, weight, groups=None):
        terms = core._filename_tokenize(query)
        kept = [t for t in terms if t not in STOP]
        if len(kept) == len(terms):
            return inner(visible_chunks, query, root_ids, weight, groups)
        if not kept:
            if all_stop_keeps:
                return inner(visible_chunks, query, root_ids, weight, groups)
            return {}
        _log("w", query, kept)
        return inner(visible_chunks, " ".join(kept), root_ids, weight, groups)

    return title_scores


# ------------------------------------------------------------------ Wb --

def make_wb():
    """Wb: on body chunks (the content field's and `both`'s body scoring; not the
    title documents, not the file-name records), the stop words leave the query when
    it holds a non-stop word."""
    inner = ORIGINAL["_bm25_scores"]

    def bm25_scores(docs, query_terms, groups=None, statistics=None):
        docs = list(docs)
        is_body = bool(docs) and "start_line" in docs[0]
        terms = list(query_terms)
        if is_body and any(t not in STOP for t in terms) and any(t in STOP for t in terms):
            kept = [t for t in terms if t not in STOP]
            _log("wb", " ".join(terms), kept)
            terms = kept
        return inner(docs, terms, groups, statistics) if statistics is not None else inner(docs, terms, groups)

    return bm25_scores


# ------------------------------------------------------------------- F --

def make_f(d2_min: int | None = None, df_floor: int | None = None, d2_df_floor: int | None = None,
           swap_one: bool = False, prefix2_below: bool = False):
    """F: fuzzy-v1 with a floor. `d2_min`: a distance-2 near word only for a typed
    word of at least this many code points (fuzzy-v1: 6). `df_floor`: a near word
    is kept only when its key df (the visible chunks; 1 for a title-only word) is at
    least this. `d2_df_floor`: the same floor, for distance-2 near words only.

    Phase 1c: `swap_one` (Ft) takes the floor's edit count from the optimal string
    alignment distance recomputed here, in which one swapped adjacent pair is one
    edit, instead of from the member's weight (fuzzy-v1's own distance is that
    alignment already, so Ft keeps exactly what F keeps). `prefix2_below` (Fp2): a
    distance-2 near word of a typed word shorter than `d2_min` is kept when it
    starts with the typed word's first two code points, instead of being dropped."""
    inner = ORIGINAL["_fuzzy_groups"]

    def fuzzy_groups(terms, body_df, title_vocabulary, key_df=None, title_candidates=None):
        groups = inner(terms, body_df, title_vocabulary, key_df, title_candidates)
        kdf = body_df if key_df is None else key_df
        out = {}
        for term, members in groups.items():
            kept = []
            for member, weight in members:
                distance = 1 if weight == core.FUZZY_WEIGHTS[1] else 2
                if swap_one:
                    distance = core._osa_within(term, member, 2)
                df = kdf.get(member, 0) or 1
                if d2_min is not None and distance == 2 and len(term) < d2_min:
                    if not (prefix2_below and member[:2] == term[:2]):
                        continue
                if df_floor is not None and df < df_floor:
                    continue
                if d2_df_floor is not None and distance == 2 and df < d2_df_floor:
                    continue
                kept.append((member, weight))
            if kept:
                out[term] = tuple(kept)
            if len(kept) != len(members):
                _log("f", term, {"before": [m for m, _ in members], "after": [m for m, _ in kept]})
        return out

    return fuzzy_groups


# ------------------------------------------------------------------- X --

DOUBLING_EXEMPT = frozenset("wxy")
ES_KEEP_ENDINGS = ("s", "x", "z", "ch", "sh")


def _vowel_groups(word: str) -> int:
    groups, inside = 0, False
    for c in word:
        vowel = c in "aeiou"
        if vowel and not inside:
            groups += 1
        inside = vowel
    return groups


def doubling_shape(b: str) -> bool:
    """One vowel group, ending consonant, vowel, consonant, the last not w, x or y:
    the shape whose own -ed and -ing double the last consonant (hop, tap, car)."""
    return (len(b) >= 3 and b[-1] not in "aeiou" and b[-1] not in DOUBLING_EXEMPT and b[-2] in "aeiou"
            and b[-3] not in "aeiou" and _vowel_groups(b) == 1)


def x_forms(term: str) -> list[str]:
    """R's forms of t less those X makes ineligible:

    (i) for a base b of the doubling shape, b+es (unless b ends s, x, z, ch, sh),
        b+ed and b+ing are not b's own forms but those of b+e (hop: hopes, hoped,
        hoping are hope's): they are dropped;
    (ii) when t is r+ing or r+ed with r of the doubling shape (one consonant, not
        doubled), r is not t's base (r's own forms double): the base r is dropped,
        r+e kept (hoping: hope, not hop; caring: care, not car)."""
    u = verb_forms.word_of(term)
    if u is None:
        return []
    p = analyzer_v3.stem_plural(u)
    drop_bases = set()
    for suffix in ("ing", "ed"):
        if p.endswith(suffix):
            r = p[: -len(suffix)]
            if doubling_shape(r):
                drop_bases.add(r)
    out: list[str] = []
    for b in verb_forms.bases(term):
        if b in drop_bases:
            continue
        rel = verb_forms.relatives(b)
        if doubling_shape(b):
            banned = {b + "ed", b + "ing"}
            if not b.endswith(ES_KEEP_ENDINGS):
                banned.add(b + "es")
            rel = [f for f in rel if f not in banned]
        for f in rel:
            if f != term and f not in out:
                out.append(f)
    return out


def make_x():
    """X: `_fold_groups` as today with `verb_forms.forms` replaced by `x_forms`."""

    def fold_groups(terms, members_by_key, key_df, parts, vocabulary=None, held=None):
        groups = {}
        for term in sorted(set(terms)):
            mates = members_by_key.get(analyzer_v3.key(term, parts), set())
            weights = {member: 1.0 for member in mates}
            if vocabulary is not None:
                is_held = held is not None and term in held
                own = key_df.get(term, 0)
                today_forms = verb_forms.forms(term)
                eligible = x_forms(term)
                dropped = [f for f in today_forms if f not in eligible and f in vocabulary and f not in weights]
                if dropped:
                    _log("x", term, dropped)
                for form in eligible:
                    if form in weights or form not in vocabulary:
                        continue
                    if is_held:
                        if key_df.get(form, 0) <= own:
                            weights[form] = core.VERB_FORM_HELD_WEIGHT
                    else:
                        weights[form] = core.VERB_FORM_UNHELD_WEIGHT
            if weights and set(weights) != {term}:
                order = sorted(weights, key=lambda m: (m != term, -key_df.get(m, 0), m.encode("utf-8")))
                groups[term] = tuple((member, weights[member]) for member in order)
        return groups

    return fold_groups


def make_fold_today():
    """`_fold_groups` rewritten here with R unchanged: must equal today's on every cell."""

    def fold_groups(terms, members_by_key, key_df, parts, vocabulary=None, held=None):
        groups = {}
        for term in sorted(set(terms)):
            mates = members_by_key.get(analyzer_v3.key(term, parts), set())
            weights = {member: 1.0 for member in mates}
            if vocabulary is not None:
                is_held = held is not None and term in held
                own = key_df.get(term, 0)
                for form in verb_forms.forms(term):
                    if form in weights or form not in vocabulary:
                        continue
                    if is_held:
                        if key_df.get(form, 0) <= own:
                            weights[form] = core.VERB_FORM_HELD_WEIGHT
                    else:
                        weights[form] = core.VERB_FORM_UNHELD_WEIGHT
            if weights and set(weights) != {term}:
                order = sorted(weights, key=lambda m: (m != term, -key_df.get(m, 0), m.encode("utf-8")))
                groups[term] = tuple((member, weights[member]) for member in order)
        return groups

    return fold_groups


# ---------------------------------------------------------- candidates --

# name -> {core function name: factory}
CANDIDATES = {
    "today": {},
    "rewrite": {"_fold_groups": make_fold_today},
    "W0": {"_title_scores": lambda: make_w(False)},
    "W": {"_title_scores": lambda: make_w(True)},
    "Wb": {"_bm25_scores": make_wb},
    # Declared (docs/tasks/S5-T8-prototype.md): F (= F8 of runs E3, E4) and F7.
    "F": {"_fuzzy_groups": lambda: make_f(d2_min=8)},
    # Exploratory names (runs E3, E4 on the non-held-out rows): W0, F8, Fdf2, Fd2df2.
    "F8": {"_fuzzy_groups": lambda: make_f(d2_min=8)},
    "F7": {"_fuzzy_groups": lambda: make_f(d2_min=7)},
    "Fdf2": {"_fuzzy_groups": lambda: make_f(df_floor=2)},
    "Fd2df2": {"_fuzzy_groups": lambda: make_f(d2_df_floor=2)},
    "X": {"_fold_groups": make_x},
    # Phase 1c (ruling 3 of the Phase 1 rulings), declared in the record before their run.
    "Ft": {"_fuzzy_groups": lambda: make_f(d2_min=8, swap_one=True)},
    "Fp2": {"_fuzzy_groups": lambda: make_f(d2_min=8, prefix2_below=True)},
}


def install(names) -> None:
    """Install one candidate, or several together ("W+Wb+X")."""
    restore()
    LOG.clear()
    hooks: dict = {}
    for name in (names.split("+") if isinstance(names, str) else names):
        for fn, factory in CANDIDATES[name].items():
            if fn in hooks:
                raise SystemExit(f"two candidates hook {fn}: {names}")
            hooks[fn] = factory
    for fn, factory in hooks.items():
        setattr(core, fn, factory())


def restore() -> None:
    for name, fn in ORIGINAL.items():
        setattr(core, name, fn)


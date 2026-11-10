"""S5-T5 prototype (builder, Phase 1): rule R of docs/tasks/S5-T5.md ruling 2, as
restated in docs/tasks/S5-T5-prototype.md, and the candidates A, B, C, D of
ruling 3 (plus any declared there) as a replacement for `core._query_groups`.

Run from a checkout (the working directory is the repository root). Nothing here
changes the engine; `install(name)` swaps the group function and `restore()` puts
fold-groups-v1 back."""
from __future__ import annotations

import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

ROOT = Path.cwd()
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import src.search_platform.core as core  # noqa: E402
from src.search_platform import analyzer_v3  # noqa: E402

ORIGINAL = core._query_groups
VOWELS = frozenset("aeiou")
REMAINDER_VOWELS = frozenset("aeiouy")
LETTERS = frozenset("abcdefghijklmnopqrstuvwxyz")
LOG: dict = {}


# ------------------------------------------------------------------ R --

def word_of(term: str) -> str | None:
    """u = A(F(t)) when F leaves one piece of 4 to 49 letters a-z; else None (R off)."""
    pieces = analyzer_v3.fold(term)
    if len(pieces) != 1:
        return None
    u = analyzer_v3.fold_marks(pieces[0])
    if not 4 <= len(u) <= 49 or not set(u) <= LETTERS:
        return None
    return u


def _consonant(c: str) -> bool:
    return c not in VOWELS


def _undoubled(r: str) -> str | None:
    if len(r) >= 2 and r[-1] == r[-2] and _consonant(r[-1]) and r[-1] not in "lsz":
        return r[:-1]
    return None


def _remainder_bases(r: str) -> list[str]:
    if len(r) < 3 or not set(r) & REMAINDER_VOWELS:
        return []
    out = [r, r + "e"]
    u = _undoubled(r)
    if u:
        out.append(u)
    return out


def bases(term: str) -> list[str]:
    """The bases of t (empty when R does not apply), in a fixed order."""
    u = word_of(term)
    if u is None:
        return []
    p = analyzer_v3.stem_plural(u)
    out = [p]
    if p.endswith("ing"):
        out += _remainder_bases(p[:-3])
    if p.endswith("ed"):
        out += _remainder_bases(p[:-2])
    if p.endswith("ied") and len(p) >= 5:
        out.append(p[:-3] + "y")
    seen: list[str] = []
    for b in out:
        if b not in seen:
            seen.append(b)
    return seen


def relatives(b: str) -> list[str]:
    out = [b, b + "s", b + "es", b + "ed", b + "ing"]
    if b.endswith("e"):
        out += [b + "d", b[:-1] + "ing"]
    if len(b) >= 3 and _consonant(b[-3]) and not _consonant(b[-2]) and _consonant(b[-1]):
        out += [b + b[-1] + "ed", b + b[-1] + "ing"]
    if len(b) >= 2 and b.endswith("y") and _consonant(b[-2]):
        out += [b[:-1] + "ies", b[:-1] + "ied"]
    return out


def forms(term: str) -> list[str]:
    """R's forms of t: every relative of every base, less t itself, first seen first.
    Its length is the number of dictionary lookups R makes for t."""
    out: list[str] = []
    for b in bases(term):
        for f in relatives(b):
            if f != term and f not in out:
                out.append(f)
    return out


# ---------------------------------------------------------- candidates --

@dataclass(frozen=True)
class Candidate:
    name: str
    trigger: str          # "always" or "v1-empty"
    weight_held: float    # R-only member weight when the v1 group is not empty
    weight_empty: float   # R-only member weight when the v1 group is empty
    df_cap: bool = False  # v1 group not empty: an R-only member joins only if its in-scope
                          # body df is no larger than the largest of the v1 members'


CANDIDATES = {
    "A": Candidate("A", "always", 1.0, 1.0),
    "B": Candidate("B", "always", 0.5, 0.5),
    "C": Candidate("C", "v1-empty", 0.0, 1.0),
    "D": Candidate("D", "always", 0.5, 1.0),
    # The builder's own (declared in docs/tasks/S5-T5-prototype.md before any held-out run):
    "E": Candidate("E", "always", 0.5, 1.0, df_cap=True),
}


def make_groups(candidate: Candidate | None):
    """A drop-in for core._query_groups. With `candidate` None it is fold-groups-v1
    rewritten here, which must give today's cells exactly (checked by the grid)."""

    def groups_fn(chunks, visible_chunks, terms, root_ids, path_prefix=None, fold="", fuzzy=True):
        terms = set(terms)
        groups: dict = {}
        if fold and terms:
            key_df: Counter = Counter()
            for chunk in visible_chunks:
                key_df.update(chunk["terms"].keys())
            body_df: Counter = Counter()
            for chunk in chunks:
                body_df.update(chunk["terms"].keys())
            vocabulary: set = set(body_df)
            for path, tokens in core._title_fields(visible_chunks, root_ids).items():
                if path_prefix is None or path.startswith(path_prefix):
                    vocabulary.update(tokens)
            members_by_key: dict = {}
            for word in vocabulary:
                members_by_key.setdefault(analyzer_v3.key(word, fold), set()).add(word)
            for term in sorted(terms):
                mates = members_by_key.get(analyzer_v3.key(term, fold), set())
                extra: set = set()
                weight = 1.0
                if candidate is not None and not (candidate.trigger == "v1-empty" and mates):
                    held = [f for f in forms(term) if f in vocabulary]
                    if candidate.df_cap and mates:
                        cap = max(body_df.get(m, 0) for m in mates)
                        held = [f for f in held if body_df.get(f, 0) <= cap]
                    LOG.setdefault("lookups", {})[term] = len(forms(term))
                    extra = {f for f in held if f not in mates}
                    weight = candidate.weight_empty if not mates else candidate.weight_held
                members = mates | extra
                if members and members != {term}:
                    order = sorted(members, key=lambda m: (m != term, -key_df.get(m, 0), m.encode("utf-8")))
                    groups[term] = tuple((m, weight if m in extra else 1.0) for m in order)
                    if extra:
                        LOG.setdefault("verb", {})[term] = [(m, weight if m in extra else 1.0) for m in order]
        if fuzzy:
            rest = [term for term in terms if term not in groups]
            if rest:
                fz = core._fuzzy_query_groups(chunks, visible_chunks, rest, root_ids, path_prefix)
                for term, members in fz.items():
                    LOG.setdefault("fuzzy", {})[term] = [m for m, _ in members]
                groups.update(fz)
        return groups

    return groups_fn


def install(name: str | None) -> None:
    """Install a candidate by name ("today-orig" keeps core's own function,
    "today" the rewrite with no R)."""
    LOG.clear()
    if name == "today-orig":
        core._query_groups = ORIGINAL
    else:
        core._query_groups = make_groups(None if name == "today" else CANDIDATES[name])


def restore() -> None:
    core._query_groups = ORIGINAL

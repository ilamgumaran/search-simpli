"""R, the verb-form rule of `fold-groups-v2` (S5-T5, docs/tasks/S5-T5.md ruling 2, as
restated in docs/tasks/S5-T5-prototype.md; docs/fold-groups-v2.md).

The Python mirror of R in `zig/src/fold.zig`. R reads nothing but its term: no
dictionary, no file. For a query term t it gives the bases of t and the relatives of
each base; the forms of t are those relatives, t itself left out, first seen first.
The query side (`core._query_groups`) looks each form up, as exact bytes, among the
in-scope body terms and the visible title terms under the prefix.

R applies when u = A(F(t)) is one piece of 4 to 49 letters a-z (else t has no
bases). With p = S(u) (`analyzer_v3.stem_plural`), the bases are, in order and
without repeats:

  p;
  when p ends in -ing, the remainder r = p less -ing, when r has at least 3
    letters and holds one of a, e, i, o, u, y: r, r + e, and r undoubled (its last
    letter dropped when the last two are one consonant other than l, s, z);
  the same for -ed;
  when p ends in -ied and has at least 5 letters: p less -ied, plus y.

The relatives of a base b are b, bs, bes, bed, bing; when b ends in e, bd and b
less e plus ing; when b ends consonant, vowel, consonant (y counted a consonant),
b doubled plus ed and plus ing; when b ends in a consonant and y, b less y plus ies
and plus ied. A vowel is one of a, e, i, o, u.

fold-groups-v3 (S5-T8, docs/fold-groups-v3.md) searches only R's eligible forms
(`eligible_forms`): R's forms less those of another word. A base b has the doubling
shape when it has one vowel group (a, e, i, o, u; y a consonant) and ends consonant,
vowel, consonant, the last not w, x or y (hop, tap, car, bit). Then:

  (i)  for a base of the doubling shape, b + ed, b + ing and (unless b ends s, x, z,
       ch or sh) b + es are not its forms but those of b + e (hop: hoped, hoping,
       hopes are hope's), and are left out;
  (ii) when p is r + ing or r + ed with r of the doubling shape, the base r is left
       out (r's own -ing and -ed double: hoping is hope's, not hop's; caring is
       care's, not car's); r + e stays.
"""
from __future__ import annotations

from . import analyzer_v3

MIN_LETTERS = 4
MAX_LETTERS = 49
MIN_REMAINDER = 3
MIN_IED = 5
VOWELS = frozenset("aeiou")
REMAINDER_VOWELS = frozenset("aeiouy")
LETTERS = frozenset("abcdefghijklmnopqrstuvwxyz")
UNDOUBLED_KEEP = frozenset("lsz")


def word_of(term: str) -> str | None:
    """u = A(F(t)) when F leaves one piece of 4 to 49 letters a-z, else None."""
    pieces = analyzer_v3.fold(term)
    if len(pieces) != 1:
        return None
    u = analyzer_v3.fold_marks(pieces[0])
    if not MIN_LETTERS <= len(u) <= MAX_LETTERS or not set(u) <= LETTERS:
        return None
    return u


def _consonant(c: str) -> bool:
    return c not in VOWELS


def _undoubled(r: str) -> str | None:
    if len(r) >= 2 and r[-1] == r[-2] and _consonant(r[-1]) and r[-1] not in UNDOUBLED_KEEP:
        return r[:-1]
    return None


def _remainder_bases(r: str) -> list[str]:
    if len(r) < MIN_REMAINDER or not set(r) & REMAINDER_VOWELS:
        return []
    out = [r, r + "e"]
    undoubled = _undoubled(r)
    if undoubled:
        out.append(undoubled)
    return out


def bases(term: str) -> list[str]:
    """The bases of t in order, without repeats; empty when R does not apply."""
    u = word_of(term)
    if u is None:
        return []
    p = analyzer_v3.stem_plural(u)
    out = [p]
    if p.endswith("ing"):
        out += _remainder_bases(p[:-3])
    if p.endswith("ed"):
        out += _remainder_bases(p[:-2])
    if p.endswith("ied") and len(p) >= MIN_IED:
        out.append(p[:-3] + "y")
    seen: list[str] = []
    for base in out:
        if base not in seen:
            seen.append(base)
    return seen


def relatives(b: str) -> list[str]:
    """The relatives of a base, in order (repeats possible; `forms` drops them)."""
    out = [b, b + "s", b + "es", b + "ed", b + "ing"]
    if b.endswith("e"):
        out += [b + "d", b[:-1] + "ing"]
    if len(b) >= 3 and _consonant(b[-3]) and not _consonant(b[-2]) and _consonant(b[-1]):
        out += [b + b[-1] + "ed", b + b[-1] + "ing"]
    if len(b) >= 2 and b.endswith("y") and _consonant(b[-2]):
        out += [b[:-1] + "ies", b[:-1] + "ied"]
    return out


def forms(term: str) -> list[str]:
    """R's forms of t: every relative of every base, t itself left out, first seen
    first. Its length is the number of exact lookups R makes for t."""
    out: list[str] = []
    for base in bases(term):
        for form in relatives(base):
            if form != term and form not in out:
                out.append(form)
    return out


DOUBLING_EXEMPT = frozenset("wxy")
ES_KEPT_AFTER = ("s", "x", "z", "ch", "sh")


def _vowel_groups(word: str) -> int:
    groups, inside = 0, False
    for c in word:
        vowel = c in VOWELS
        if vowel and not inside:
            groups += 1
        inside = vowel
    return groups


def doubling_shape(b: str) -> bool:
    """One vowel group, ending consonant, vowel, consonant, the last not w, x or y."""
    return (len(b) >= 3 and _consonant(b[-1]) and b[-1] not in DOUBLING_EXEMPT and not _consonant(b[-2])
            and _consonant(b[-3]) and _vowel_groups(b) == 1)


def eligible_forms(term: str) -> list[str]:
    """fold-groups-v3: R's forms of t less those of another word ((i) and (ii) above),
    t itself left out, first seen first."""
    u = word_of(term)
    if u is None:
        return []
    p = analyzer_v3.stem_plural(u)
    left_out = {p[: -len(suffix)] for suffix in ("ing", "ed")
                if p.endswith(suffix) and doubling_shape(p[: -len(suffix)])}
    out: list[str] = []
    for base in bases(term):
        if base in left_out:
            continue
        banned: set[str] = set()
        if doubling_shape(base):
            banned = {base + "ed", base + "ing"}
            if not base.endswith(ES_KEPT_AFTER):
                banned.add(base + "es")
        for form in relatives(base):
            if form != term and form not in banned and form not in out:
                out.append(form)
    return out

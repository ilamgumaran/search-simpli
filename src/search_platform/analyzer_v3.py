"""K, the key function of `fold-groups-v1` (S5-T4, docs/tasks/S5-T4.md rulings 2-5).

The Python mirror of `zig/src/fold.zig`. K maps one analyzer-v2 token to zero or
more terms through four parts, in order:

  F  fold: each code point through the generated fold table (`_fold.FOLD`,
     NFKC(casefold(NFKC(c))) to a fixpoint, Unicode 13.0.0), then NFC; a folded
     token holding a code point outside the v2 token classes is split again by
     the v2 rule (`½` -> `1`, `2`);
  A  Latin marks: an ASCII piece is untouched; otherwise NFD, the eight-letter
     table, every U+0300-U+036F whose nearest preceding non-mark code point is
     a-z dropped, then NFC;
  S  English plural: a piece matching [a-z]{3,49}, not in the keep list, by the
     first of ruling 4's rules that applies;
  T  Tamil: a piece of code points U+0B80-U+0BFF only, not in the keep list, by
     the first of ruling 5's seven suffix rules whose condition holds and whose
     result keeps two Tamil letters.

K reads nothing but its token: no dictionary, no file, and no `str.casefold` or
NFKC call (the fold is the table's). NFC and NFD are `unicodedata`'s, as the v2
tokenizer's are (`core.tokenize`). `parts` names the parts applied, for the
part-by-part measure (ruling 11): without F the piece is the v2 term itself
(analyzer-v2's simple fold).

The query side (ruling 10) groups terms by `key`: the pieces joined by one
space, or the term itself when K leaves nothing.
"""
from __future__ import annotations

import functools
import re
import unicodedata
from bisect import bisect_right

from ._fold import FOLD, UNICODE_VERSION
from ._marks import MARK_RANGES

POLICY_ID = "fold-groups-v1"
ALL_PARTS = "FAST"
VARIATION_SELECTORS = re.compile("[︀-️\U000e0100-\U000e01ef]")

_MARK_STARTS = [lo for lo, _ in MARK_RANGES]


def _is_mark(cp: int) -> bool:
    i = bisect_right(_MARK_STARTS, cp) - 1
    return i >= 0 and cp <= MARK_RANGES[i][1]


@functools.lru_cache(maxsize=1)
def _token_pattern() -> re.Pattern[str]:
    from .core import TOKEN_PATTERN  # the v2 split (core imports this module lazily)
    return TOKEN_PATTERN


def _simple_fold(token: str) -> str:
    """analyzer-v2's simple fold (`core._filename_tokenize`, the engine's body fold)."""
    out = []
    for character in token:
        folded = character.casefold()
        if len(folded) != 1:
            lowered = character.lower()
            folded = lowered if len(lowered) == 1 else character
        out.append(folded)
    return "".join(out)


# ---------------------------------------------------------------- F: fold --

def fold(token: str) -> list[str]:
    """F: the table per code point, NFC, and the v2 re-split when needed."""
    folded = unicodedata.normalize("NFC", "".join(FOLD.get(ord(c), c) for c in token))
    pattern = _token_pattern()
    if pattern.fullmatch(folded):
        return [folded]
    return pattern.findall(VARIATION_SELECTORS.sub("", folded))


# ------------------------------------------------------- A: Latin marks --

LATIN_TABLE = {"ø": "o", "đ": "d", "ł": "l", "ħ": "h", "ŧ": "t", "ı": "i", "æ": "ae", "œ": "oe"}


def fold_marks(piece: str) -> str:
    """A: drop U+0300-U+036F after a Latin a-z base; the eight-letter table."""
    if piece.isascii():
        return piece
    out = []
    latin_base = False
    for character in unicodedata.normalize("NFD", piece):
        cp = ord(character)
        if _is_mark(cp):
            if latin_base and 0x300 <= cp <= 0x36F:
                continue
            out.append(character)
            continue
        mapped = LATIN_TABLE.get(character, character)
        out.append(mapped)
        latin_base = "a" <= mapped[-1] <= "z"
    return unicodedata.normalize("NFC", "".join(out))


# ---------------------------------------------------- S: English plural --

ASCII_WORD = re.compile(r"[a-z]{3,49}\Z")
PLURAL_KEEP = frozenset((
    "news", "species", "series", "always", "perhaps", "christmas", "lens", "atlas", "canvas", "bias",
    "alias", "chaos", "cosmos", "pants", "trousers", "scissors", "glasses", "maths", "physics",
    "athletics", "gymnastics", "politics", "measles", "mumps", "means", "lots", "thanks", "towards",
    "afterwards", "upstairs", "downstairs", "indoors", "outdoors", "headquarters", "whereas", "yes",
    "does", "goes", "was", "has", "his", "its", "this", "thus", "plus", "bus", "gas", "us", "is", "as",
))


def stem_plural(piece: str) -> str:
    """S: ruling 4's rules, the first that applies."""
    if not ASCII_WORD.match(piece) or piece in PLURAL_KEEP:
        return piece
    if piece.endswith(("ss", "us", "is")) or not piece.endswith("s"):
        return piece
    if piece.endswith("ies"):
        return piece[:-3] + "y" if len(piece) >= 5 else piece[:-1]
    if piece.endswith(("sses", "xes", "ches", "shes", "zzes")):
        return piece[:-2]
    if piece.endswith("oes") and len(piece) >= 6:
        return piece[:-2]
    if len(piece) >= 4:
        return piece[:-1]
    return piece


# ------------------------------------------------------------- T: Tamil --

TAMIL_KEEP = frozenset(("நாங்கள்", "நீங்கள்", "உங்கள்", "எங்கள்", "தங்கள்", "அவர்கள்", "இவர்கள்", "மக்கள்"))
TAMIL_VOWEL_SIGNS = ("ா", "ி", "ீ", "ு", "ூ", "ெ", "ே", "ை", "ொ", "ோ", "ௌ")
TAMIL_I_AI = ("ி", "ீ", "ை")
TAMIL_RULES = (
    ("ங்கள்", "ம்", None),
    ("கள்", "", None),
    ("த்தில்", "ம்", None),
    ("த்தின்", "ம்", None),
    ("க்கு", "", TAMIL_VOWEL_SIGNS),
    ("யில்", "", TAMIL_I_AI),
    ("யின்", "", TAMIL_I_AI),
)


def _tamil_letters(text: str) -> int:
    return sum(1 for c in text if 0x0B85 <= ord(c) <= 0x0BB9)


def stem_tamil(piece: str) -> str:
    """T: ruling 5's rules, the first whose suffix and condition hold and whose
    result keeps two Tamil letters (U+0B85-U+0BB9)."""
    if not piece or piece in TAMIL_KEEP or not all(0x0B80 <= ord(c) <= 0x0BFF for c in piece):
        return piece
    for suffix, replacement, stem_ends in TAMIL_RULES:
        if not piece.endswith(suffix):
            continue
        stem = piece[: -len(suffix)]
        if stem_ends is not None and not stem.endswith(stem_ends):
            continue
        out = stem + replacement
        if _tamil_letters(out) >= 2:
            return out
    return piece


# ------------------------------------------------------------------- K --

@functools.lru_cache(maxsize=1 << 18)
def key_terms(token: str, parts: str = ALL_PARTS) -> tuple[str, ...]:
    """K over one analyzer-v2 token (before or after v2's fold: F folds either the
    same way), with the parts named in `parts` (a subset of "FAST", in K's order)."""
    pieces = fold(token) if "F" in parts else [_simple_fold(token)]
    out = []
    for piece in pieces:
        if "A" in parts:
            piece = fold_marks(piece)
        if "S" in parts:
            piece = stem_plural(piece)
        if "T" in parts:
            piece = stem_tamil(piece)
        out.append(piece)
    return tuple(out)


def key(term: str, parts: str = ALL_PARTS) -> str:
    """The group key of a v2 term (ruling 10): K's pieces joined by one space, or the
    term itself when K leaves nothing."""
    pieces = key_terms(term, parts)
    return " ".join(pieces) if pieces else term

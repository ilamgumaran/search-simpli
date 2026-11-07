"""S5-T4 prototype (planner scratch): candidate `analyzer-v3` steps over the
Python reference, and the hooks that install them.

Every step works on one analyzer-v2 token (the v2 split on NFC text, variation
selectors dropped) and returns zero or more terms:

  F  fold: NFKC_Casefold (NFKC, full case fold, NFKC again, to a fixpoint);
     a folded token holding a character outside the token classes is split
     again by the v2 rule (fractions, compatibility symbols)
  A  Latin accent fold: NFD, drop U+0300..U+036F after a Latin base letter,
     NFC; plus a short table (o-slash, d-stroke, l-stroke, h-stroke, t-stroke,
     dotless i, ae, oe)
  P  possessive: a token `s` right after an apostrophe (U+0027, U+2019) that
     follows a letter or digit is dropped (`biscuit's` -> `biscuit`)
  S  English plural (`stem_plural`), ASCII a-z only, length 3..49 (KStem guard)
  I  `-ing`, D `-ed` (Porter step 1b with the stated exceptions), same guard
  T  Tamil: a bounded suffix list (`stem_tamil`)
  W  stop words (Lucene's English set), on a chosen surface

Run from a checkout (the working directory): it imports `src.search_platform`.
"""
from __future__ import annotations

import functools
import re
import sys
import unicodedata
from dataclasses import dataclass, replace  # noqa: F401  (replace re-exported)
from pathlib import Path

sys.path.insert(0, str(Path.cwd()))

import src.search_platform.core as core  # noqa: E402
import src.search_platform.find as findmod  # noqa: E402

TOKEN_PATTERN = core.TOKEN_PATTERN
VS = core.VARIATION_SELECTORS


@dataclass(frozen=True)
class Cfg:
    name: str = "v3"
    fold: bool = False          # F
    accents: bool = False       # A
    possessive: bool = False    # P
    plural: bool = False        # S
    ing: bool = False           # I
    ing_double: str = "undouble" # I on a doubled consonant: undouble (Porter) | keep
    ed: bool = False            # D
    ed_double: str = "undouble" # D on a doubled consonant: undouble (Porter) | keep (the word is left whole)
    tamil: bool = False         # T
    stop_index: bool = False    # W on the analyzer (body, title, query, find)
    stop_title: bool = False    # W on the title field only (derived at query time)
    stop_query: bool = False    # W dropped from a body query that keeps another word
    side: str = "index"         # index | query-naive | query-groups
    base_fold: str = "full"     # the v2 body fold of the base index: full (Python) | simple (engine)
    group_df: str = "max"       # query-groups: max | union


# ------------------------------------------------------------------ folds --

def simple_fold_char(ch: str) -> str:
    folded = ch.casefold()
    if len(folded) == 1:
        return folded
    lowered = ch.lower()
    return lowered if len(lowered) == 1 else ch


def simple_fold(tok: str) -> str:
    return "".join(simple_fold_char(c) for c in tok)


def nfkc_cf(tok: str) -> str:
    out = tok
    for _ in range(4):
        nxt = unicodedata.normalize("NFKC", unicodedata.normalize("NFKC", out).casefold())
        if nxt == out:
            break
        out = nxt
    return out


LATIN_BASE = set("abcdefghijklmnopqrstuvwxyz")
LATIN_TABLE = {"ø": "o", "đ": "d", "ł": "l", "ħ": "h", "ŧ": "t", "ı": "i", "æ": "ae", "œ": "oe"}


def fold_latin(tok: str) -> str:
    if tok.isascii():
        return tok
    out = []
    after_latin = False
    for ch in unicodedata.normalize("NFD", tok):
        o = ord(ch)
        if 0x300 <= o <= 0x36F:
            if after_latin:
                continue
            out.append(ch)
            continue
        mapped = LATIN_TABLE.get(ch, ch)
        out.append(mapped)
        after_latin = mapped[-1] in LATIN_BASE
    return unicodedata.normalize("NFC", "".join(out))


# ------------------------------------------------------------ English stem --

ASCII_WORD = re.compile(r"[a-z]{3,49}\Z")
VOWELS = set("aeiou")
# Words whose final s is not a plural (or whose -s rule would merge two words).
PLURAL_KEEP = {"news", "species", "series", "always", "perhaps", "christmas", "lens", "atlas", "canvas",
               "bias", "alias", "chaos", "cosmos", "pants", "trousers", "scissors", "glasses", "maths",
               "physics", "athletics", "gymnastics", "politics", "measles", "mumps", "means", "lots",
               "thanks", "towards", "afterwards", "upstairs", "downstairs", "indoors", "outdoors",
               "headquarters", "whereas", "yes", "does", "goes", "was", "has", "his", "its", "this",
               "thus", "plus", "bus", "gas", "us", "is", "as"}
ING_KEEP = {"evening", "morning", "wedding", "pudding", "nothing", "something", "anything", "everything",
            "thing", "things", "during", "ceiling", "darling", "sibling", "duckling", "spring", "string",
            "bring", "sing", "king", "ring", "wing", "swing", "sting", "thing", "being", "ping", "ding",
            "awning", "lightning", "shilling", "sterling", "viking", "pudding", "icing", "stuffing"}
ED_KEEP = {"bed", "red", "shed", "sled", "wed", "fed", "led", "ted", "need", "seed", "feed", "speed", "weed",
           "reed", "deed", "freed", "breed", "bleed", "greed", "hundred", "sacred", "naked", "wicked", "rugged",
           "ragged", "jagged", "crooked", "beloved", "learned", "used", "bred", "shred", "sped"}


def _has_vowel(s: str) -> bool:
    return any(c in VOWELS for c in s) or (len(s) > 1 and "y" in s[1:])


def _cons(word: str, i: int) -> bool:
    c = word[i]
    if c in VOWELS:
        return False
    if c == "y":
        return i == 0 or not _cons(word, i - 1)
    return True


def _measure(stem: str) -> int:
    m, prev_v = 0, False
    for i in range(len(stem)):
        v = not _cons(stem, i)
        if prev_v and not v:
            m += 1
        prev_v = v
    return m


def _cvc(stem: str) -> bool:
    if len(stem) < 3:
        return False
    return (_cons(stem, len(stem) - 3) and not _cons(stem, len(stem) - 2) and _cons(stem, len(stem) - 1)
            and stem[-1] not in "wxy")


def stem_plural(w: str) -> str:
    if not ASCII_WORD.match(w) or w in PLURAL_KEEP:
        return w
    if w.endswith(("ss", "us", "is")) or not w.endswith("s"):
        return w
    if w.endswith("ies"):
        return w[:-3] + "y" if len(w) >= 5 else w[:-1]           # ponies -> pony; ties -> tie
    if w.endswith(("sses", "xes", "ches", "shes", "zzes")):
        return w[:-2]                                            # glasses -> glass, boxes -> box
    if w.endswith("oes") and len(w) >= 6:
        return w[:-2]                                            # potatoes -> potato (shoes: -s)
    if len(w) >= 4:
        return w[:-1]                                            # tests -> test, rides -> ride
    return w


def _after_suffix(stem: str) -> str:
    if stem.endswith(("at", "bl", "iz")):
        return stem + "e"
    if len(stem) >= 2 and stem[-1] == stem[-2] and _cons(stem, len(stem) - 1) and stem[-1] not in "lsz":
        return stem[:-1]                                         # skipping -> skip
    if _measure(stem) == 1 and _cvc(stem):
        return stem + "e"                                        # skating -> skate
    return stem


def stem_ing(w: str, double: str = "undouble") -> str:
    if not ASCII_WORD.match(w) or w in ING_KEEP or not w.endswith("ing") or len(w) < 6:
        return w
    stem = w[:-3]
    if not _has_vowel(stem):
        return w
    if double == "keep" and len(stem) >= 2 and stem[-1] == stem[-2] and _cons(stem, len(stem) - 1) \
            and stem[-1] not in "lsz":
        return w
    return _after_suffix(stem)


def stem_ed(w: str, double: str = "undouble") -> str:
    if not ASCII_WORD.match(w) or w in ED_KEEP or not w.endswith("ed") or len(w) < 5:
        return w
    if w.endswith("eed"):
        return w[:-1] if _measure(w[:-3]) > 0 else w            # agreed -> agree; feed stays
    stem = w[:-2]
    if not _has_vowel(stem):
        return w
    if stem.endswith("i") and len(stem) >= 3:
        return stem[:-1] + "y"                                   # carried -> carry
    if double == "keep" and len(stem) >= 2 and stem[-1] == stem[-2] and _cons(stem, len(stem) - 1) \
            and stem[-1] not in "lsz":
        return w                                                 # potted stays potted
    return _after_suffix(stem)


# ------------------------------------------------------------- Tamil stem --

VIRAMA = "்"
TA_I_AI = ("ி", "ீ", "ை")                         # ி ீ ை
TA_VOWEL_END = ("ா", "ி", "ீ", "ு", "ூ", "ெ", "ே", "ை",
                "ொ", "ோ", "ௌ")                       # a vowel sign: the stem ends in a vowel


def _ta_letters(s: str) -> int:
    return sum(1 for c in s if "அ" <= c <= "ஹ")


def _is_tamil(w: str) -> bool:
    return all("஀" <= c <= "௿" for c in w)


# Plural-looking pronouns and lexical -கள் words the plural rule must leave whole.
TAMIL_KEEP = {"நாங்கள்", "நீங்கள்", "உங்கள்", "எங்கள்", "தங்கள்", "அவர்கள்", "இவர்கள்", "மக்கள்"}


def stem_tamil(w: str) -> str:
    """A bounded list: plural கள் (ங்கள் -> ம்), dative க்கு, locative த்தில் (-> ம்)
    and யில், genitive த்தின் (-> ம்) and யின். Never the accusative ஐ (J2's guards
    g1, g2), never the nominal -வு (g3). The stem keeps two letters or more."""
    if not w or not _is_tamil(w) or w in TAMIL_KEEP:
        return w
    rules = (
        ("ங்கள்", "ம்", None),
        ("கள்", "", None),
        ("த்தில்", "ம்", None),
        ("த்தின்", "ம்", None),
        ("க்கு", "", TA_VOWEL_END),
        ("யில்", "", TA_I_AI),
        ("யின்", "", TA_I_AI),
    )
    for suffix, add, must_end in rules:
        if w.endswith(suffix):
            stem = w[: -len(suffix)]
            if must_end is not None and not stem.endswith(must_end):
                continue
            out = stem + add
            if _ta_letters(out) >= 2:
                return out
    return w


# ---------------------------------------------------------------- stop words --

STOP = {"a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "if", "in", "into", "is", "it", "no",
        "not", "of", "on", "or", "such", "that", "the", "their", "then", "there", "these", "they", "this",
        "to", "was", "will", "with"}


# ------------------------------------------------------------- the analyzer --

CFG = Cfg()


def key_terms(tok: str, cfg: Cfg) -> list[str]:
    """One v2 token (not yet folded) -> its v3 terms."""
    pieces = [nfkc_cf(tok)] if cfg.fold else [tok.casefold() if cfg.base_fold == "full" else simple_fold(tok)]
    if cfg.fold and len(pieces) == 1 and not TOKEN_PATTERN.fullmatch(pieces[0]):
        pieces = TOKEN_PATTERN.findall(pieces[0])
    out = []
    for p in pieces:
        if cfg.accents:
            p = fold_latin(p)
        if cfg.plural:
            p = stem_plural(p)
        if cfg.ed:
            p = stem_ed(p, cfg.ed_double)
        if cfg.ing:
            p = stem_ing(p, cfg.ing_double)
        if cfg.tamil:
            p = stem_tamil(p)
        if cfg.stop_index and p in STOP:
            continue
        out.append(p)
    return out


@functools.lru_cache(maxsize=1 << 18)
def _key_cached(tok: str, cfg: Cfg) -> tuple[str, ...]:
    return tuple(key_terms(tok, cfg))


def _possessive_s(text: str, m: re.Match) -> bool:
    s = m.start()
    return (m.group() in ("s", "S") and s >= 2 and text[s - 1] in "'’"
            and (text[s - 2].isalnum()))


def tokenize_cfg(text: str, cfg: Cfg) -> list[str]:
    norm = VS.sub("", unicodedata.normalize("NFC", text))
    out: list[str] = []
    for m in TOKEN_PATTERN.finditer(norm):
        if cfg.possessive and _possessive_s(norm, m):
            continue
        out.extend(_key_cached(m.group(), cfg))
    return out


def tokenize_positioned_cfg(text: str, cfg: Cfg) -> list[tuple[str, int, int]]:
    normalized, starts, ends = findmod.normalize_mapped(text)
    kept = [k for k, char in enumerate(normalized) if not VS.match(char)]
    view = "".join(normalized[k] for k in kept)
    tokens = []
    for m in TOKEN_PATTERN.finditer(view):
        if cfg.possessive and _possessive_s(view, m):
            continue
        indexes = kept[m.start():m.end()]
        start = min(starts[k] for k in indexes)
        end = max(ends[k] for k in indexes)
        for term in _key_cached(m.group(), cfg):
            tokens.append((term, start, end - start))
    return tokens


def body_cfg(cfg: Cfg) -> Cfg:
    return cfg


def base_cfg(cfg: Cfg) -> Cfg:
    """The v2 analyzer of the base index (no v3 step)."""
    return Cfg(name="v2", base_fold=cfg.base_fold)


def filename_cfg(cfg: Cfg) -> Cfg:
    """The title and file-name surface: today `_filename_tokenize` (simple fold);
    under v3 one analyzer for both surfaces."""
    if any((cfg.fold, cfg.accents, cfg.possessive, cfg.plural, cfg.ing, cfg.ed, cfg.tamil, cfg.stop_index)):
        return cfg
    return replace(cfg, base_fold="simple")


ORIG = {
    "tokenize": core.tokenize,
    "_filename_tokenize": core._filename_tokenize,
    "find.tokenize": findmod.tokenize,
    "find.tokenize_positioned": findmod.tokenize_positioned,
    "_title_tokens": core._title_tokens,
    "_title_scores": core._title_scores,
    "_fuzzy_query_groups": core._fuzzy_query_groups,
    "_bm25_scores": core._bm25_scores,
}


def set_analyzers(body: Cfg | None, filename: Cfg | None) -> None:
    """Install `body` as core.tokenize (and find's), `filename` as _filename_tokenize.
    None restores today's function."""
    if body is None:
        core.tokenize = ORIG["tokenize"]
        findmod.tokenize = ORIG["find.tokenize"]
        findmod.tokenize_positioned = ORIG["find.tokenize_positioned"]
    else:
        core.tokenize = lambda text, _c=body: tokenize_cfg(text, _c)
        findmod.tokenize = core.tokenize
        findmod.tokenize_positioned = lambda text, _c=body: tokenize_positioned_cfg(text, _c)
    if filename is None:
        core._filename_tokenize = ORIG["_filename_tokenize"]
    else:
        core._filename_tokenize = lambda text, _c=filename: tokenize_cfg(text, _c)
    ORIG["_title_tokens"].cache_clear()


def restore() -> None:
    set_analyzers(None, None)
    core._title_tokens = ORIG["_title_tokens"]
    core._title_scores = ORIG["_title_scores"]
    core._fuzzy_query_groups = ORIG["_fuzzy_query_groups"]
    core._bm25_scores = ORIG["_bm25_scores"]
    ORIG["_title_tokens"].cache_clear()

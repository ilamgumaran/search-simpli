#!/usr/bin/env python3
"""Generate the J2 judged fixture: its files, judgments.json and README (S5-T1).

Deterministic and standard-library only. The roots (school/, home/, laptop/),
judgments.json and README.md are written next to this script, or into --out.
Every line range in judgments.json is computed here from the files: content.py
holds the text, queries.py the judged queries and their anchors.

Before anything is written, every query's `checks` are asserted (finding 3 of
the S5-T1 plan). They are what makes each miss real: a misspelt word is in no
file, a morphology row's answer holds the other form and not the query's, a
title row's words sit in the file name and barely in the body, a phrase row's
distractor holds the words apart. The checks tokenize with the simple case fold
of analyzer-v2 (`_filename_tokenize`, which mirrors the Zig analyzer), not the
Python reference's full fold. A check that fails stops the generator.
"""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True

import argparse  # noqa: E402
import hashlib  # noqa: E402
import importlib.util  # noqa: E402
import json  # noqa: E402
import unicodedata  # noqa: E402
from pathlib import Path, PurePosixPath  # noqa: E402

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent.parent))

from src.search_platform import analyzer_v3, verb_forms  # noqa: E402
from src.search_platform.core import _filename_tokenize, file_chunks  # noqa: E402


def _load(name: str):
    """content.py and queries.py by path, under J2-only names: the family-folder
    generator also has a `content` module, and a test run imports both."""
    spec = importlib.util.spec_from_file_location(f"j2_{name}", HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


content = _load("content")
queries = _load("queries")

ROOTS = ("school", "home", "laptop")
BOM = b"\xef\xbb\xbf"
SLICES = ("control", "misspelling", "morphology", "accent", "tamil", "title", "phrase", "negatives",
          "title-heldout", "misspelling-heldout", "morphology-heldout", "accent-heldout", "tamil-heldout",
          "verbform-heldout", "verbform-cross", "precision-control", "negatives-tuning", "negatives-heldout",
          "misspelling-short", "negatives-short", "misspelling-opening")
# S5-T8: the slices and sets it adds, and the slices whose queries are negatives.
# The short-typo slice and its negatives (Phase 1c, ruling 3 of the Phase 1 rulings)
# came after the others, and keep out of their query words too.
SHORT_SLICES = ("misspelling-short", "negatives-short")
# The re-ruling after the verifier's measurement (13 Nov): misspelling-opening holds
# the verifier's own typed words, as the short questions it ran. Its questions are
# taken verbatim, so the new-words check does not apply to them.
OPENING_SLICES = ("misspelling-opening",)
S5T8_SLICES = ("verbform-cross", "precision-control", "negatives-tuning", "negatives-heldout") + SHORT_SLICES \
    + OPENING_SLICES
NEGATIVE_SLICES = ("negatives", "negatives-tuning", "negatives-heldout", "negatives-short")
# S5-T8 ruling 1: the stop words of the measure of what misleads (README, "What
# counts as misleading"): Lucene's 33 English stop words, and `my`, which the
# ruling names among the common words in file names.
STOP_WORDS = ("a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "if", "in", "into", "is", "it",
              "no", "not", "of", "on", "or", "such", "that", "the", "their", "then", "there", "these", "they",
              "this", "to", "was", "will", "with", "my")
NEGATIVE_KINDS = ("stop-name", "near-word", "near-topic", "cross-form", "tamil", "accent", "half-held")
PRECISION_KINDS = ("stop-title", "near", "verb")
VERBFORM_CROSS_ANSWER_FILES = 6
# S5-T8 Phase 1c (ruling 3 of the Phase 1 rulings): misspelling-short's typed words
# are 6 or 7 code points, two edits from the meant word when a swap of two
# neighbours counts two (Levenshtein), the length kept; at least this many are one
# swapped adjacent pair, the rest a dropped and an added letter or two wrong
# letters; and at least this many negatives-short rows.
SHORT_KINDS = ("swap", "drop and add", "two wrong letters")
SHORT_MIN_SWAPS = 5
SHORT_MIN_NEGATIVES = 3
# misspelling-opening (the re-ruling, item 3): typed words of 6 or 7 code points, two
# edits (optimal string alignment) from the meant word, with no word of the fixture
# one edit away, and the edit in the first letter or, the first letter kept, in the
# second; at least this many of each.
OPENING_KINDS = ("second letter", "first letter")
OPENING_MINIMUMS = {"second letter": 16, "first letter": 9}
# S5-T3, ruling 7 of its plan: the edits the held-out misspelling slice must hold,
# at least this many rows of each (a distance-2 row needs a meant word of 8 or more
# code points; "name" is a word only the answer's file or folder name holds;
# "common" a meant word in 8 or more files; "short" a 4-code-point meant word).
HELDOUT_MISSPELLING_MIX = {"swap": 2, "deletion": 2, "insertion": 1, "substitution": 1,
                           "two edits": 2, "name": 1, "common": 1, "short": 1}
# S5-T4, ruling 11 of its plan: the rows each held-out slice must hold, at least
# this many of each kind.
HELDOUT_MORPHOLOGY_MIX = {"-ies": 2, "-ches": 2, "-oes": 2, "keep": 3, "-ing/-ed": 3, "title": 1,
                          "query plural": 1, "query singular": 1}
HELDOUT_ACCENT_MIX = {"short": 4, "nfkc": 2, "sharp-s": 1, "table": 1, "merge-guard": 1,
                      "plain query": 1, "accented query": 1}
# S5-T5, ruling 4: the rows the verb-form held-out slice must hold, at least this
# many of each kind; the verb rows cover every direction pair and each feature.
HELDOUT_VERBFORM_MIX = {"verb": 8, "guard": 4, "held": 2}
VERBFORM_DIRECTIONS = {"-ing->-ed": ("ing", "ed"), "-ed->-ing": ("ed", "ing"), "base->-ing": ("", "ing"),
                       "-ing->base": ("ing", ""), "base->-ed": ("", "ed"), "-ed->base": ("ed", "")}
VERBFORM_PAIRS = ({"-ing->-ed", "-ed->-ing"}, {"base->-ing", "-ing->base"}, {"base->-ed", "-ed->base"})
VERBFORM_FEATURES = ("doubled", "dropped e", "-ied")
TAMIL_RULES = ("ங்கள்", "கள்", "த்தில்", "த்தின்", "க்கு", "யில்", "யின்")
TAMIL_GUARDS = ("accusative", "-வு noun", "keep-list pronoun")
# The Latin letters of S5-T4's table (o-slash, d-stroke, l-stroke, h-stroke,
# t-stroke, dotless i, ae, oe): what the "table" kind must hold.
LATIN_TABLE_LETTERS = set("øđłħŧıæœ")
MODES = ("knowledge", "find:words", "find:phrase", "find:prefix")


def toks(text: str) -> list[str]:
    return _filename_tokenize(text)


# ------------------------------------------------------------------ files ---

def build_files() -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    for path, text in content.FILES.items():
        files[path] = text.encode("utf-8")
    for path, text in content.CRLF_FILES.items():
        files[path] = text.replace("\n", "\r\n").encode("utf-8")
    for path, text in content.BOM_FILES.items():
        files[path] = BOM + text.encode("utf-8")
    for path, text in content.NO_FINAL_NEWLINE.items():
        assert not text.endswith("\n"), path
        files[path] = text.encode("utf-8")
    assert len(files) == len(content.FILES) + len(content.CRLF_FILES) + len(content.BOM_FILES) + len(content.NO_FINAL_NEWLINE)
    return dict(sorted(files.items()))


def text_lines(data: bytes) -> list[str]:
    body = data[len(BOM):] if data.startswith(BOM) else data
    text = body.decode("utf-8")
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return [line[:-1] if line.endswith("\r") else line for line in lines]


class Corpus:
    def __init__(self, files: dict[str, bytes]):
        self.files = files
        self.lines = {p: text_lines(d) for p, d in files.items()}
        self.chunks = {}
        for path, data in files.items():
            rel = path.split("/", 1)[1]
            self.chunks[path] = [(s, e, sp) for s, e, _, sp, _, _ in file_chunks(rel, data.decode("utf-8"))]
        self.vocabulary: dict[str, int] = {}
        for path in files:
            for token in set(toks("\n".join(self.lines[path]))):
                self.vocabulary[token] = self.vocabulary.get(token, 0) + 1
        # S5-T8: the title field's words (every folder below the root, then the stem).
        self.titles: dict[str, list[str]] = {}
        for path in files:
            rel = PurePosixPath(path.split("/", 1)[1])
            self.titles[path] = [t for part in rel.parent.parts for t in toks(part)] + toks(rel.stem)
        self.title_vocabulary = {t for words in self.titles.values() for t in words}

    def df(self, token: str) -> int:
        return self.vocabulary.get(token, 0)

    def find_line(self, path: str, needle: str) -> int:
        hits = [i + 1 for i, line in enumerate(self.lines[path]) if needle in line]
        if len(hits) != 1:
            raise SystemExit(f"anchor {needle!r} in {path}: {len(hits)} matches, need exactly 1")
        return hits[0]

    def resolve(self, path: str, anchor: str) -> tuple[int, int, list[str] | None]:
        if path not in self.files:
            raise SystemExit(f"no such file: {path}")
        lines = self.lines[path]
        if anchor == "*":
            if not lines:
                raise SystemExit(f"{path} is empty; nothing to judge")
            return 1, len(lines), None
        if anchor.startswith("§"):
            heading = anchor[1:]
            found = [(s, e, sp) for s, e, sp in self.chunks[path]
                     if sp and unicodedata.normalize("NFC", sp[-1]) == unicodedata.normalize("NFC", heading)]
            if len(found) != 1:
                raise SystemExit(f"section {heading!r} in {path}: {len(found)} chunks, need exactly 1")
            start, end, section = found[0]
            while end > start and not lines[end - 1].strip():
                end -= 1
            return start, end, section
        if anchor.startswith("="):
            first, sep, last = anchor[1:].partition("..")
            a = self.find_line(path, first)
            b = self.find_line(path, last.lstrip("=")) if sep else a
            if b < a:
                raise SystemExit(f"span {anchor!r} in {path} runs backwards")
            return a, b, None
        raise SystemExit(f"unknown anchor {anchor!r}")

    def range_tokens(self, row: dict) -> list[str]:
        path = f"{row['root_id']}/{row['path']}"
        return toks("\n".join(self.lines[path][row["start_line"] - 1:row["end_line"]]))


def osa_distance(a: str, b: str) -> int:
    """Damerau distance, optimal string alignment (an adjacent swap costs 1)."""
    d = [[0] * (len(b) + 1) for _ in range(len(a) + 1)]
    for i in range(len(a) + 1):
        d[i][0] = i
    for j in range(len(b) + 1):
        d[0][j] = j
    for i in range(1, len(a) + 1):
        for j in range(1, len(b) + 1):
            cost = 0 if a[i - 1] == b[j - 1] else 1
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
            if i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]:
                d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
    return d[len(a)][len(b)]


def is_one_swap(typed: str, meant: str) -> bool:
    if len(typed) != len(meant) or typed == meant:
        return False
    diff = [i for i in range(len(typed)) if typed[i] != meant[i]]
    return (len(diff) == 2 and diff[1] == diff[0] + 1
            and typed[diff[0]] == meant[diff[1]] and typed[diff[1]] == meant[diff[0]])


def edit_kind(typed: str, meant: str) -> str:
    """The edit a misspelling is: one adjacent swap, deletion, insertion or
    substitution, or "two edits" (distance 2)."""
    distance = osa_distance(typed, meant)
    if distance == 2:
        return "two edits"
    if distance != 1:
        return f"distance {distance}"
    if is_one_swap(typed, meant):
        return "swap"
    return {-1: "deletion", 1: "insertion", 0: "substitution"}[len(typed) - len(meant)]


def levenshtein(a: str, b: str) -> int:
    """Insertions, deletions and substitutions only: a swap of two neighbours costs 2."""
    before = list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        now = [i] + [0] * len(b)
        for j in range(1, len(b) + 1):
            now[j] = min(before[j] + 1, now[j - 1] + 1, before[j - 1] + (a[i - 1] != b[j - 1]))
        before = now
    return before[-1]


def short_kind(typed: str, meant: str) -> str:
    """misspelling-short's edit: one swapped adjacent pair; two wrong letters (two
    positions differ); or a dropped and an added letter (the same length, more
    positions differ, two edits)."""
    if is_one_swap(typed, meant):
        return "swap"
    if len(typed) != len(meant) or levenshtein(typed, meant) != 2:
        return f"length {len(typed)}/{len(meant)}, Levenshtein {levenshtein(typed, meant)}"
    differ = sum(1 for x, y in zip(typed, meant) if x != y)
    return "two wrong letters" if differ == 2 else "drop and add"


def opening_kind(typed: str, meant: str) -> str:
    """misspelling-opening's edit position: the first letter differs, or the first
    letter is the same and the second differs."""
    if typed[:1] != meant[:1]:
        return "first letter"
    return "second letter" if typed[1:2] != meant[1:2] else "after the second letter"


def contains_run(seq: list[str], want: list[str]) -> bool:
    return any(seq[i:i + len(want)] == want for i in range(len(seq) - len(want) + 1))


# ------------------------------------------------------------- judgments ---

class CheckFailed(SystemExit):
    pass


def title_slice_words() -> set[str]:
    """Every query word of the title slice (ti01-ti11) and every word of its grade-2
    targets' root-relative paths, root included: S5-T2's held-out rows use none."""
    words: set[str] = set()
    for spec in queries.QUERIES:
        if spec["slice"] != "title":
            continue
        words.update(toks(spec["query"]))
        for path, _anchor, grade, _note in spec["rows"]:
            if grade == 2:
                pure = PurePosixPath(path)
                words.update(toks(pure.stem))
                for part in pure.parent.parts:
                    words.update(toks(part))
    return words


def misspelling_slice_words() -> set[str]:
    """Every typed and every meant word of the misspelling slice (m01-m16):
    S5-T3's held-out rows use none."""
    return {word for spec in queries.QUERIES if spec["slice"] == "misspelling" for word in spec["typo"][:2]}


def misspelling_heldout_words() -> set[str]:
    """Every typed and every meant word of the misspelling-heldout slice (mh01-mh12)."""
    return {word for spec in queries.QUERIES if spec["slice"] == "misspelling-heldout" for word in spec["typo"][:2]}


def heldout_words(slice_name: str) -> set[str]:
    """Every query word and every form or fold word of an S5-T1 slice: S5-T4's
    held-out rows of the matching slice use none."""
    words: set[str] = set()
    for spec in queries.QUERIES:
        if spec["slice"] != slice_name:
            continue
        words.update(toks(spec["query"]))
        for pair in spec.get("forms", ()):
            words.update(pair)
        if "fold" in spec:
            words.update(spec["fold"])
        if "guard" in spec and isinstance(spec["guard"], tuple):
            words.update(spec["guard"])
    return words


def new_file_hygiene(corpus: Corpus) -> list[str]:
    """S5-T5's new files keep out of every earlier slice's query words (the slices
    S5-T8 adds came later and are left out) and of their
    fold-groups-v1 forms (the keys `analyzer_v3.key` gives), in body and path, so
    that adding them moves no earlier row by a word they hold."""
    earlier: set[str] = set()
    for spec in queries.QUERIES:
        if spec["slice"] != "verbform-heldout" and spec.get("of") != "verbform-heldout" \
                and spec["slice"] not in S5T8_SLICES:
            earlier.update(toks(spec["query"].rstrip("*")))
    keys = {analyzer_v3.key(w): w for w in earlier}
    problems = []
    for path in content.VERBFORM_FILES:
        rel = PurePosixPath(path.split("/", 1)[1])
        held = set(toks("\n".join(corpus.lines[path]))) | {t for part in rel.parent.parts for t in toks(part)} | set(toks(rel.stem))
        for word in sorted(held):
            if word in earlier:
                problems.append(f"{path} holds {word}, an earlier query word")
            elif analyzer_v3.key(word) in keys:
                problems.append(f"{path} holds {word}, a fold-groups-v1 form of {keys[analyzer_v3.key(word)]}")
    return problems


def earlier_query_words() -> set[str]:
    """Every query word of a slice before S5-T8 (the stop words included)."""
    words: set[str] = set()
    for spec in queries.QUERIES:
        if spec["slice"] not in S5T8_SLICES:
            words.update(toks(spec["query"].rstrip("*")))
    return words


def fuzzy_reach(typed: str, candidate: str) -> bool:
    """fuzzy-v1's candidate test, without the dictionary: the same first code point,
    and an optimal-string-alignment distance of at most 1 (5 code points) or 2 (6 or
    more). The script test is left out: every word it is used on here is Latin."""
    k = 2 if len(typed) >= 6 else (1 if len(typed) == 5 else 0)
    return bool(k) and typed[:1] == candidate[:1] and abs(len(typed) - len(candidate)) <= k \
        and 1 <= osa_distance(typed, candidate) <= k


def s5t8_file_hygiene(corpus: Corpus) -> list[str]:
    """S5-T8's new files keep out of every earlier query word (stop words in file names
    excepted: content.STOP_WORDS_IN_NAMES), of its fold-groups-v1 key, of its verb
    forms (R, `verb_forms.forms`; content.HYGIENE_EXEMPT names the hop/hope forms
    review R05 asks for) and, for an earlier query word no earlier file holds, of
    fuzzy-v1's reach from it."""
    earlier = earlier_query_words()
    keys = {analyzer_v3.key(w): w for w in earlier}
    earlier_paths = [p for p in corpus.files if p not in content.S5T8_FILES]
    earlier_vocabulary: set[str] = set()
    for path in earlier_paths:
        rel = PurePosixPath(path.split("/", 1)[1])
        earlier_vocabulary |= set(toks("\n".join(corpus.lines[path])))
        earlier_vocabulary |= {t for part in rel.parent.parts for t in toks(part)} | set(toks(rel.stem))
    forms = {}
    for w in sorted(earlier):
        for f in verb_forms.forms(w):
            if f not in content.HYGIENE_EXEMPT.get(w, ()):
                forms.setdefault(f, w)
    unheld = sorted(w for w in earlier if w not in earlier_vocabulary)
    problems = []
    for path in content.S5T8_FILES:
        rel = PurePosixPath(path.split("/", 1)[1])
        body = set(toks("\n".join(corpus.lines[path])))
        name = {t for part in rel.parent.parts for t in toks(part)} | set(toks(rel.stem))
        for word in sorted(body | name):
            if word in content.STOP_WORDS_IN_NAMES and word in name and word not in body:
                continue
            if word in earlier:
                problems.append(f"{path} holds {word}, an earlier query word")
            elif analyzer_v3.key(word) in keys:
                problems.append(f"{path} holds {word}, a fold-groups-v1 form of {keys[analyzer_v3.key(word)]}")
            elif word in forms:
                problems.append(f"{path} holds {word}, a verb form of {forms[word]}")
            else:
                near = [w for w in unheld if fuzzy_reach(w, word)]
                if near:
                    problems.append(f"{path} holds {word}, in fuzzy-v1's reach of {near}")
    return problems


def held_anywhere(corpus: Corpus, word: str) -> bool:
    """A body word of some file, or a title word (folders and stem) of some file."""
    return corpus.df(word) > 0 or word in corpus.title_vocabulary


def strip_marks(word: str) -> str:
    """The word without its combining marks (NFD), for the merge guard's check
    that two words differ only by an accent."""
    return "".join(c for c in unicodedata.normalize("NFD", word) if not unicodedata.combining(c))


def build_query(corpus: Corpus, spec: dict) -> dict:
    qid = spec["id"]

    def need(condition: bool, what: str) -> None:
        if not condition:
            raise CheckFailed(f"{qid}: check failed: {what}")

    expected = []
    for path, anchor, grade, note in spec["rows"]:
        start, end, section = corpus.resolve(path, anchor)
        root, _, rest = path.partition("/")
        row = {"root_id": root, "path": rest, "start_line": start, "end_line": end, "grade": grade}
        if section:
            row["section_path"] = section
        row["note"] = note
        expected.append(row)
    graded = [r for r in expected if r["grade"] >= 1]
    answers = [r for r in expected if r["grade"] == 2]
    negative = spec["slice"] in NEGATIVE_SLICES
    need(spec["mode"] in MODES, f"mode {spec['mode']}")
    need(bool(answers) != negative, "graded queries have a grade-2 row; negatives have none with grade 1 or more")

    query_tokens = toks(spec["query"].rstrip("*"))
    checks: list[dict] = []

    # grading is unambiguous: no chunk overlaps both a grade-2 row and a grade-0 row
    for zero in (r for r in expected if r["grade"] == 0):
        path = f"{zero['root_id']}/{zero['path']}"
        for two in answers:
            if (two["root_id"], two["path"]) != (zero["root_id"], zero["path"]):
                continue
            for s, e, _ in corpus.chunks[path]:
                both = (s <= two["end_line"] and two["start_line"] <= e
                        and s <= zero["end_line"] and zero["start_line"] <= e)
                need(not both, f"chunk {s}-{e} of {path} overlaps a grade-2 and a grade-0 row")
    checks.append({"check": "no chunk overlaps a grade-2 row and a grade-0 row"})

    first = corpus.range_tokens(answers[0]) if answers else []
    s = spec["slice"]
    if s in ("misspelling", "misspelling-heldout"):
        typed, meant, swap = spec["typo"]
        need(typed in query_tokens, f"{typed} is a query word")
        need(corpus.df(typed) == 0, f"{typed} occurs in no file (df {corpus.df(typed)})")
        distance = osa_distance(typed, meant)
        need(1 <= distance <= 2, f"{typed}->{meant} distance {distance}")
        need(is_one_swap(typed, meant) == swap, f"{typed}->{meant} transposition flag {swap}")
        if s == "misspelling":
            need(meant in first, f"{meant} is in the answer")
            checks.append({"check": "misspelt word in no file; Damerau distance 1-2; transposition flag; meant word in the answer",
                           "typed": typed, "meant": meant, "df": 0, "distance": distance, "transposition": swap})
        else:
            edit = edit_kind(typed, meant)
            need(edit == spec["edit"], f"{typed}->{meant} is {edit}, declared {spec['edit']}")
            need(edit != "two edits" or len(meant) >= 8, f"a distance-2 row needs a meant word of 8+ code points ({meant})")
            if spec.get("name"):
                pure = PurePosixPath(answers[0]["path"])
                path_words = set(toks(pure.stem)) | {t for part in pure.parent.parts for t in toks(part)}
                need(corpus.df(meant) == 0, f"{meant} occurs in no file (df {corpus.df(meant)})")
                need(meant in path_words, f"{meant} is in the answer's file or folder name")
                where = "name"
            else:
                need(meant in first, f"{meant} is in the answer")
                where = "body"
            checks.append({"check": "misspelt word in no file; Damerau distance 1-2; transposition flag; the edit; "
                                    "meant word in the answer (body), or only in its file or folder name (name)",
                           "typed": typed, "meant": meant, "df": 0, "distance": distance, "transposition": swap,
                           "edit": edit, "where": where, "meant_df": corpus.df(meant),
                           "typed_code_points": len(typed), "meant_code_points": len(meant)})
            reused = sorted({typed, meant} & misspelling_slice_words())
            need(not reused, f"held out: {reused} is a typed or meant word of the misspelling slice")
            checks.append({"check": "held out: no typed or meant word is a typed or meant word of the misspelling slice"})
    elif s == "misspelling-short":
        typed, meant, swap = spec["typo"]
        kind = spec["kind"]
        need(kind in SHORT_KINDS, f"kind {kind}")
        need(typed in query_tokens, f"{typed} is a query word")
        need(not held_anywhere(corpus, typed), f"{typed} occurs in no file or file name")
        need(len(typed) in (6, 7), f"{typed} is 6 or 7 code points ({len(typed)})")
        need(levenshtein(typed, meant) == 2, f"{typed}->{meant} Levenshtein {levenshtein(typed, meant)}, need 2")
        need(short_kind(typed, meant) == kind, f"{typed}->{meant} is {short_kind(typed, meant)}, declared {kind}")
        need(is_one_swap(typed, meant) == swap, f"{typed}->{meant} transposition flag {swap}")
        need(meant in first, f"{meant} is in the answer")
        reused = sorted({typed, meant} & (misspelling_slice_words() | misspelling_heldout_words()))
        need(not reused, f"held out: {reused} is a typed or meant word of the misspelling or misspelling-heldout slice")
        checks.append({"check": "short typo: 6 or 7 code points, in no file or file name; Levenshtein 2 to the meant "
                                "word; the kind; the meant word in the answer; no typed or meant word of the "
                                "misspelling or misspelling-heldout slice",
                       "typed": typed, "meant": meant, "levenshtein": 2, "distance": osa_distance(typed, meant),
                       "transposition": swap, "kind": kind, "typed_code_points": len(typed),
                       "meant_df": corpus.df(meant)})
    elif s == "misspelling-opening":
        typed, meant = spec["typo"]
        kind = spec["kind"]
        need(kind in OPENING_KINDS, f"kind {kind}")
        need(typed in query_tokens, f"{typed} is a query word")
        need(not held_anywhere(corpus, typed), f"{typed} occurs in no file or file name")
        need(len(typed) in (6, 7), f"{typed} is 6 or 7 code points ({len(typed)})")
        need(osa_distance(typed, meant) == 2, f"{typed}->{meant} distance {osa_distance(typed, meant)}, need 2")
        held = set(corpus.vocabulary) | corpus.title_vocabulary
        near = sorted(w for w in held if abs(len(w) - len(typed)) <= 1 and osa_distance(typed, w) == 1)
        need(not near, f"{typed} is one edit from {near}")
        need(opening_kind(typed, meant) == kind, f"{typed}->{meant} is {opening_kind(typed, meant)}, declared {kind}")
        holders = sorted(p for p in corpus.files if meant in toks("\n".join(corpus.lines[p])))
        named = sorted(f"{r['root_id']}/{r['path']}" for r in answers)
        need(holders == named, f"the answer files {named} are the files holding {meant} {holders}")
        need(all((r["start_line"], r["end_line"]) == (1, len(corpus.lines[f"{r['root_id']}/{r['path']}"]))
                 for r in answers), "each answer row is its whole file")
        checks.append({"check": "opening typo: 6 or 7 code points, in no file or file name; distance 2 to the meant "
                                "word and no fixture word one edit away; the edit in the first letter, or in the "
                                "second with the first kept; the answer rows are the files holding the meant word",
                       "typed": typed, "meant": meant, "distance": 2, "levenshtein": levenshtein(typed, meant),
                       "kind": kind, "typed_code_points": len(typed), "meant_df": corpus.df(meant)})
    elif s in ("morphology", "tamil") and "forms" in spec:
        for query_form, file_form in spec["forms"]:
            need(query_form in query_tokens, f"{query_form} is a query word")
            need(query_form not in first, f"{query_form} is absent from the answer")
            need(file_form in first, f"{file_form} is present in the answer")
            checks.append({"check": "query form absent from the answer, other form present",
                           "query_form": query_form, "file_form": file_form})
        if spec.get("only_form"):
            need(not set(query_tokens) & set(first), "no query word occurs in the answer")
            checks.append({"check": "only the form differs: no query word occurs in the answer"})
        if spec.get("possessive"):
            need(all(t in first for t in query_tokens), "every query word occurs in the answer")
            checks.append({"check": "a singular possessive: the apostrophe splits it, every query word is in the answer"})
    elif s == "tamil":
        word, homograph = spec["guard"]
        zero = [r for r in expected if r["grade"] == 0]
        need(word in query_tokens and word in first, f"{word} is in the answer")
        need(len(zero) == 1, "one homograph row")
        zt = corpus.range_tokens(zero[0])
        need(homograph in zt and word not in zt, f"{homograph} in the distractor, {word} not")
        checks.append({"check": "suffix guard: the word is in the answer; its homograph stem, and not the word, is in the distractor",
                       "word": word, "homograph": homograph, "kind": spec["guard_kind"]})
    elif s == "morphology-heldout":
        kind = spec["kind"]
        for query_form, file_form in spec["forms"]:
            need(query_form in query_tokens, f"{query_form} is a query word")
            need(query_form not in first, f"{query_form} is absent from the answer")
            need(file_form in first, f"{file_form} is present in the answer")
            checks.append({"check": "query form absent from the answer, other form present",
                           "query_form": query_form, "file_form": file_form, "kind": kind,
                           **({"direction": "query plural" if len(query_form) > len(file_form) else "query singular"}
                              if kind in ("-ies", "-ches", "-oes", "-s") else {})})
        if kind == "keep":
            word, merged = spec["guard"]
            zero = [r for r in expected if r["grade"] == 0]
            need(word in query_tokens and word in first, f"{word} is in the answer")
            need(len(zero) == 1, "one distractor row")
            zt = corpus.range_tokens(zero[0])
            need(merged in zt and word not in zt, f"{merged} in the distractor, {word} not")
            checks.append({"check": "keep guard: the word is in the answer; the form a plural rule without the keep "
                                    "list would make, and not the word, is in the distractor",
                           "word": word, "merged": merged, "kind": kind})
        if kind == "title":
            word, title_form = spec["title_only"]
            pure = PurePosixPath(answers[0]["path"])
            path_words = set(toks(pure.stem)) | {t for part in pure.parent.parts for t in toks(part)}
            need(word in query_tokens, f"{word} is a query word")
            need(word not in first and title_form not in first, f"neither {word} nor {title_form} is in the body")
            need(title_form in path_words and word not in path_words, f"{title_form}, not {word}, is in the file name")
            checks.append({"check": "title only: neither form in the body; the other form in the file name",
                           "query_form": word, "title_form": title_form, "kind": kind})
        need(kind in HELDOUT_MORPHOLOGY_MIX or kind == "-s", f"kind {kind}")
        need(bool(spec["forms"]) or kind in ("keep", "title"), "a form pair, a keep guard or a title form")
        reused = sorted((set(query_tokens) | {w for pair in spec["forms"] for w in pair}) & heldout_words("morphology"))
        need(not reused, f"held out: {reused} is a query word or form of the morphology slice")
        checks.append({"check": "held out: no query word or form is a query word or form of the morphology slice"})
    elif s == "accent-heldout":
        kind = spec["kind"]
        query_form, file_form = spec["fold"]
        need(query_form in query_tokens, f"{query_form} is a query word")
        need(file_form in first, f"{file_form} is in the answer")
        if kind == "merge-guard":
            word, other = spec["guard"]
            zero = [r for r in expected if r["grade"] == 0]
            need(word == query_form and word in first, f"{word} is in the answer")
            need(word != other and strip_marks(word) == strip_marks(other), f"{word} and {other} differ only by marks")
            need(len(zero) == 1, "one distractor row")
            zt = corpus.range_tokens(zero[0])
            need(other in zt and word not in zt, f"{other} in the distractor, {word} not")
            checks.append({"check": "merge guard: the word is in the answer; a word that differs from it only by an "
                                    "accent, and not the word, is in the distractor",
                           "word": word, "other": other, "kind": kind})
        else:
            need(query_form != file_form and query_form not in first, f"{query_form} is absent from the answer")
            accented = "accented query" if not query_form.isascii() else "plain query"
            checks.append({"check": "query form absent from the answer, the other form present",
                           "query_form": query_form, "file_form": file_form, "kind": kind, "direction": accented,
                           "query_code_points": len(query_form)})
        if kind == "short":
            need(len(query_form) <= 4, f"{query_form} has 4 code points or fewer")
        if kind == "nfkc":
            need(unicodedata.normalize("NFKC", file_form) != file_form, f"{file_form} has a compatibility form")
        if kind == "sharp-s":
            need("ß" in query_form + file_form and "ss" in query_form + file_form, "one form has ß, the other ss")
        if kind == "table":
            need(bool(LATIN_TABLE_LETTERS & set(query_form + file_form)), "a letter of the Latin table")
        need(kind in HELDOUT_ACCENT_MIX or kind == "long", f"kind {kind}")
        reused = sorted({query_form, file_form} & heldout_words("accent"))
        need(not reused, f"held out: {reused} is a query word or fold word of the accent slice")
        checks.append({"check": "held out: no query word or fold word is one of the accent slice"})
    elif s == "tamil-heldout":
        if "forms" in spec:
            rule = spec["rule"]
            need(rule in TAMIL_RULES, f"rule {rule}")
            for query_form, file_form in spec["forms"]:
                need(query_form in query_tokens, f"{query_form} is a query word")
                need(query_form not in first, f"{query_form} is absent from the answer")
                need(file_form in first, f"{file_form} is present in the answer")
                need(query_form.endswith(rule) or file_form.endswith(rule), f"a form ends in {rule}")
                checks.append({"check": "query form absent from the answer, other form present; a form ends in the rule's suffix",
                               "query_form": query_form, "file_form": file_form, "rule": rule})
            words = {w for pair in spec["forms"] for w in pair}
        else:
            word, homograph = spec["guard"]
            zero = [r for r in expected if r["grade"] == 0]
            need(spec["guard_kind"] in TAMIL_GUARDS, f"guard kind {spec['guard_kind']}")
            need(word in query_tokens and word in first, f"{word} is in the answer")
            need(len(zero) == 1, "one homograph row")
            zt = corpus.range_tokens(zero[0])
            need(homograph in zt and word not in zt, f"{homograph} in the distractor, {word} not")
            checks.append({"check": "suffix guard: the word is in the answer; the word a stripper would make, and not the word, is in the distractor",
                           "word": word, "homograph": homograph, "kind": spec["guard_kind"]})
            words = {word, homograph}
        reused = sorted((set(query_tokens) | words) & heldout_words("tamil"))
        need(not reused, f"held out: {reused} is a query word or form of the Tamil slice")
        checks.append({"check": "held out: no query word or form is a word of J2's Tamil rows"})
    elif s == "verbform-heldout":
        kind = spec["kind"]
        need(kind in HELDOUT_VERBFORM_MIX, f"kind {kind}")
        need(all(r[0] in content.VERBFORM_FILES for r in spec["rows"]), "every row is in one of S5-T5's new files")
        zero = [r for r in expected if r["grade"] == 0]
        words = set(query_tokens)
        if kind == "verb":
            base, direction, feature = spec["base"], spec["direction"], spec["feature"]
            need(direction in VERBFORM_DIRECTIONS, f"direction {direction}")
            need(feature in VERBFORM_FEATURES + (None,), f"feature {feature}")
            need(len(spec["forms"]) == 1, "one form pair")
            query_form, file_form = spec["forms"][0]
            need(query_form in query_tokens, f"{query_form} is a query word")
            need(query_form not in first, f"{query_form} is absent from the answer")
            need(file_form in first, f"{file_form} is present in the answer")
            need(corpus.df(query_form) == 0, f"{query_form} occurs in no file (df {corpus.df(query_form)})")
            same_key = sorted(w for w in corpus.vocabulary if analyzer_v3.key(w) == analyzer_v3.key(query_form))
            need(not same_key, f"no file holds a fold-groups-v1 form of {query_form} ({same_key})")
            q_end, f_end = VERBFORM_DIRECTIONS[direction]
            for form, end in ((query_form, q_end), (file_form, f_end)):
                if end:
                    need(form.endswith(end), f"{form} ends in -{end}")
                else:
                    need(form == base, f"{form} is the base {base}")
            if feature == "doubled":
                need(any(f in (base + base[-1] + "ing", base + base[-1] + "ed") for f in (query_form, file_form)),
                     f"a form doubles the final consonant of {base}")
            if feature == "dropped e":
                need(base.endswith("e") and any(f in (base[:-1] + "ing", base + "d") for f in (query_form, file_form)),
                     f"a form drops the final e of {base} before -ing, or adds only d")
            if feature == "-ied":
                need(base.endswith("y") and base[:-1] + "ied" in (query_form, file_form), f"a form is {base[:-1]}ied")
            checks.append({"check": "verb form: the answer holds only another form of the query's verb; no file holds "
                                    "the query form or a fold-groups-v1 form of it",
                           "query_form": query_form, "file_form": file_form, "base": base, "direction": direction,
                           "feature": feature, "kind": kind})
            words |= {query_form, file_form, base}
        elif kind == "guard":
            word, lookalike = spec["guard"]
            need(word in query_tokens and word in first, f"{word} is in the answer")
            need(word.startswith(lookalike) and word[len(lookalike):] in
                 ("ing", "ed", lookalike[-1] + "ing", lookalike[-1] + "ed"),
                 f"{word} is {lookalike} with -ing or -ed (and a doubled consonant)")
            need(len(zero) == 1, "one distractor row")
            zt = corpus.range_tokens(zero[0])
            need(lookalike in zt and word not in zt, f"{lookalike} in the distractor, {word} not")
            checks.append({"check": "guard: the query word is in the answer; the word left when its -ing or -ed "
                                    "(and a doubled consonant) is taken off, and not the query word, is in the distractor",
                           "word": word, "lookalike": lookalike, "kind": kind})
            words |= {word, lookalike}
        else:
            typed, file_form = spec["held"]
            need(typed in query_tokens, f"{typed} is a query word")
            need(typed not in first and file_form in first, f"{typed} absent from the answer, {file_form} present")
            need(any(typed in corpus.range_tokens(z) for z in zero), f"a grade-0 row holds {typed}")
            checks.append({"check": "held: a grade-0 row holds the typed word; the answer holds another form of it "
                                    "and not the typed word",
                           "typed": typed, "file_form": file_form, "kind": kind})
            words |= {typed, file_form}
        reused = sorted(words & (heldout_words("morphology") | heldout_words("morphology-heldout")))
        need(not reused, f"held out: {reused} is a query word or form of the morphology or morphology-heldout slice")
        checks.append({"check": "held out: no query word, form or base is a query word or form of the morphology "
                                "or morphology-heldout slices"})
    elif s == "accent":
        query_form, file_form = spec["fold"]
        need(query_form in query_tokens, f"{query_form} is a query word")
        need(file_form in first, f"{file_form} is in the answer")
        if spec.get("guard"):
            need(toks(query_form) == toks(file_form), "the two forms are one token after NFC")
            checks.append({"check": "NFC guard: the query form and the file's decomposed form are one token",
                           "query_form": query_form, "file_form": file_form})
        else:
            need(query_form != file_form and query_form not in first, f"{query_form} is absent from the answer")
            checks.append({"check": "query form absent from the answer, the other form present",
                           "query_form": query_form, "file_form": file_form})
    elif s in ("title", "title-heldout"):
        target = answers[0]
        pure = PurePosixPath(target["path"])
        stem = toks(pure.stem)
        folder = [t for part in pure.parent.parts for t in toks(part)]
        body = corpus.range_tokens(target)
        counts = {}
        for word, where in spec["name"]:
            need(word in query_tokens, f"{word} is a query word")
            actual = "stem" if word in stem else ("folder" if word in folder else "none")
            need(actual == where, f"{word} sits in the {actual}, declared {where}")
            counts[word] = body.count(word)
            need(counts[word] <= 1, f"{word} occurs {counts[word]} times in the body")
        need(any(w != "none" for _, w in spec["name"]), "at least one query word is in the path")
        checks.append({"check": "the words sit in the file name (stem) or only in its folder; each at most once in the body",
                       "where": {w: p for w, p in spec["name"]}, "body_counts": counts})
        if s == "title-heldout":
            reused = sorted(set(query_tokens) & title_slice_words())
            need(not reused, f"held out: {reused} is a query word or a target path word of the title slice")
            checks.append({"check": "held out: no query word is a query word of the title slice or a word of its targets' paths"})
    elif s == "phrase":
        near = corpus.range_tokens(expected[spec["adjacent"]])
        far = corpus.range_tokens(expected[spec["apart"]])
        need(contains_run(near, query_tokens), "the words are adjacent in the adjacent row")
        need(all(t in far for t in query_tokens) and not contains_run(far, query_tokens),
             "the words are all present and never adjacent in the apart row")
        checks.append({"check": "adjacent in one row, present but apart in the other",
                       "adjacent_grade": expected[spec["adjacent"]]["grade"],
                       "apart_grade": expected[spec["apart"]]["grade"]})
    elif s == "verbform-cross":
        typed, own, cross = spec["cross"]
        zero = [r for r in expected if r["grade"] == 0]
        need(spec["kind"] == "cross", f"kind {spec['kind']}")
        need(query_tokens == [typed], f"the query is the one word {typed}")
        need(held_anywhere(corpus, typed) == spec["held"], f"{typed} held: {spec['held']}")
        need(own in first and (own == typed or own in verb_forms.forms(typed)
                               or analyzer_v3.key(own) == analyzer_v3.key(typed)),
             f"{own}, the typed word or a form of it, is in the answer")
        need(spec["held"] or typed not in first, f"{typed} is absent from the answer")
        need(cross in verb_forms.forms(typed), f"R generates {cross} from {typed}")
        need(cross not in first, f"{cross} is absent from the answer")
        need(any(cross in corpus.range_tokens(z) and own not in corpus.range_tokens(z) for z in zero),
             f"a grade-0 row holds {cross} and not {own}")
        checks.append({"check": "cross form: the answer holds the typed word's own form and not the other word's; "
                                "a grade-0 row holds a form of another word that R generates from the typed word",
                       "typed": typed, "own": own, "cross": cross, "held": spec["held"], "kind": spec["kind"]})
    elif s == "precision-control":
        kind = spec["kind"]
        need(kind in PRECISION_KINDS, f"kind {kind}")
        if kind == "stop-title":
            target = answers[0]
            title = corpus.titles[f"{target['root_id']}/{target['path']}"]
            body = corpus.range_tokens(target)
            stops = [t for t in query_tokens if t in STOP_WORDS]
            others = [t for t in query_tokens if t not in STOP_WORDS]
            need(target["start_line"] == 1 and target["end_line"] == len(corpus.lines[f"{target['root_id']}/{target['path']}"]),
                 "the answer is the whole file")
            need(bool(stops) and all(t in title for t in stops), f"a stop word of the query is in the file name ({stops})")
            need(all(t in title and t not in body for t in others), f"{others} are in the file name and not in its body")
            checks.append({"check": "stop-word title: the query's stop words and its other words are in the file name; "
                                    "the other words are not in its body",
                           "stop_words": stops, "other_words": others, "title": title, "kind": kind})
        elif kind == "near":
            typed, meant, swap = spec["typo"]
            need(typed in query_tokens and not held_anywhere(corpus, typed), f"{typed} is a query word no file holds")
            need(meant in first, f"{meant} is in the answer")
            need(fuzzy_reach(typed, meant), f"{meant} is in fuzzy-v1's reach of {typed}")
            need(is_one_swap(typed, meant) == swap, f"{typed}->{meant} transposition flag {swap}")
            checks.append({"check": "near: the typed word is in no file; the answer holds the meant word, in fuzzy-v1's reach",
                           "typed": typed, "meant": meant, "distance": osa_distance(typed, meant),
                           "typed_code_points": len(typed), "meant_df": corpus.df(meant), "kind": kind})
        else:
            query_form, file_form = spec["forms"][0]
            need(query_form in query_tokens and not held_anywhere(corpus, query_form), f"{query_form} is a query word no file holds")
            need(file_form in first, f"{file_form} is in the answer")
            need(file_form in verb_forms.forms(query_form), f"R generates {file_form} from {query_form}")
            same_key = sorted(w for w in set(corpus.vocabulary) | corpus.title_vocabulary
                              if analyzer_v3.key(w) == analyzer_v3.key(query_form))
            need(not same_key, f"no file holds a fold-groups-v1 form of {query_form} ({same_key})")
            checks.append({"check": "verb: no file holds the query form or a fold-groups-v1 form of it; the answer holds a "
                                    "verb form R generates from it",
                           "query_form": query_form, "file_form": file_form, "kind": kind})
    elif s in ("negatives-tuning", "negatives-heldout", "negatives-short"):
        kind = spec["kind"]
        need(kind in NEGATIVE_KINDS, f"kind {kind}")
        if s == "negatives-short":
            need(kind == "near-word", "a negatives-short row is a near word")
            need(all(len(t) in (6, 7) for t in query_tokens), "a word of 6 or 7 code points")
        words = [t for t in query_tokens if t not in STOP_WORDS]
        held = [t for t in words if held_anywhere(corpus, t)]
        facts = {}
        if kind == "stop-name":
            stop = spec["stop"]
            need(stop in query_tokens and stop in STOP_WORDS, f"{stop} is a stop word of the query")
            need(stop in corpus.title_vocabulary, f"{stop} is in a file name")
            need(not held, f"no file holds {held}")
            facts = {"stop": stop}
        elif kind == "near-word":
            need(len(words) == 1 and not held, "one word, which no file holds")
            near = sorted(w for w in set(corpus.vocabulary) | corpus.title_vocabulary if fuzzy_reach(words[0], w))
            need(bool(near), f"a file holds a word in fuzzy-v1's reach of {words[0]}")
            facts = {"near": near}
        elif kind == "near-topic":
            need(len(words) >= 2 and held == words, "every word is held")
        elif kind == "cross-form":
            typed, other = spec["cross"]
            need(typed in words and not held_anywhere(corpus, typed), f"{typed} is a query word no file holds")
            need(other in verb_forms.forms(typed) and held_anywhere(corpus, other),
                 f"R generates {other} from {typed} and a file holds it")
            need(queries.VERB_FORM_JUDGMENTS.get(typed, {}).get(other) == "cross", f"{other} is judged a form of another word")
            facts = {"typed": typed, "other": other}
        elif kind == "tamil":
            need(all(any("\u0b80" <= c <= "\u0bff" for c in t) for t in words), "Tamil words")
            keys = {analyzer_v3.key(w) for w in set(corpus.vocabulary) | corpus.title_vocabulary}
            need(any(analyzer_v3.key(t) in keys for t in words), "a word, or a fold-groups-v1 form of it, is held")
        elif kind == "accent":
            marked = [t for t in words if not t.isascii()]
            need(bool(marked) and not any(held_anywhere(corpus, t) for t in marked), "an accented word no file holds")
        elif kind == "half-held":
            need(len(words) == 2 and len(held) == 1, "two words, one held")
        checks.append({"check": f"negative ({kind}): " + {
            "stop-name": "a stop word of the query is in a file name; no file holds the other words",
            "near-word": "one correctly spelt word no file holds; files hold words in fuzzy-v1's reach",
            "near-topic": "every word is held; the topic is not",
            "cross-form": "a word no file holds; R generates another word a file holds, judged a form of another word",
            "tamil": "a Tamil question; a word or a fold-groups-v1 form of it is held",
            "accent": "an accented word no file holds",
            "half-held": "two words, one held"}[kind], "held": held, **facts})
    elif s == "negatives":
        present = [t for t in query_tokens if corpus.df(t) > 0]
        need(bool(present), "at least one query word occurs in the corpus")
        checks.append({"check": "no row with grade 1 or more; at least one query word occurs in the corpus",
                       "present": present})
    elif s != "control":
        raise SystemExit(f"{qid}: unknown slice {s}")

    if s in S5T8_SLICES and s not in OPENING_SLICES:
        earlier = earlier_query_words()
        earlier_keys = {analyzer_v3.key(w) for w in earlier if w not in STOP_WORDS}
        reused = sorted(t for t in query_tokens if t not in STOP_WORDS
                        and (t in earlier or analyzer_v3.key(t) in earlier_keys))
        need(not reused, f"{reused} is a query word of an earlier slice, or shares its fold-groups-v1 key")
        if s in SHORT_SLICES:
            first_s5t8 = {t for spec_ in queries.QUERIES if spec_["slice"] in S5T8_SLICES
                          and spec_["slice"] not in SHORT_SLICES + OPENING_SLICES
                          for t in toks(spec_["query"].rstrip("*"))}
            reused = sorted(t for t in query_tokens if t not in STOP_WORDS and t in first_s5t8)
            need(not reused, f"{reused} is a query word of an earlier S5-T8 slice")
        checks.append({"check": "new words: no query word but a stop word is a query word of an earlier slice or shares "
                                "its fold-groups-v1 key"})

    item = {"slice": s, "id": qid, "question": spec["question"], "query": spec["query"], "mode": spec["mode"],
            "expected": expected}
    if negative:
        item["negative"] = True
        item["negative_of"] = spec["of"]
    if s in ("misspelling", "misspelling-heldout"):
        item["transposition"] = spec["typo"][2]
    if s == "misspelling-heldout":
        item["edit"] = spec["edit"]
    if s == "misspelling-short":
        item["transposition"] = spec["typo"][2]
    if s == "morphology":
        item["only_form"] = bool(spec.get("only_form"))
    if s == "tamil" and "guard" in spec:
        item["guard"] = spec["guard_kind"]
    if s in ("morphology-heldout", "accent-heldout"):
        item["kind"] = spec["kind"]
    if s in S5T8_SLICES:
        item["kind"] = spec["kind"]
    if s == "verbform-heldout":
        item["kind"] = spec["kind"]
        if spec["kind"] == "verb":
            item["direction"] = spec["direction"]
            item["feature"] = spec["feature"]
    if s == "tamil-heldout":
        if "guard" in spec:
            item["tamil_guard"] = spec["guard_kind"]
        else:
            item["rule"] = spec["rule"]
    if s == "phrase" and spec.get("reversed"):
        item["reversed"] = True
    item["checks"] = checks
    return item


def verb_form_judgments(corpus: Corpus, items: list[dict]) -> dict[str, dict[str, str]]:
    """S5-T8: every verb form R gives a negative's query word that a file holds (body
    or name), judged in queries.VERB_FORM_JUDGMENTS as "same" (of the question's own
    word) or "cross" (of another word). Every reachable form must be judged, and only
    those: the measure of what misleads needs a verdict for any form a rule can add."""
    need: dict[str, dict[str, str]] = {}
    for item in items:
        if not item.get("negative"):
            continue
        for word in toks(item["query"]):
            held = [f for f in verb_forms.forms(word) if held_anywhere(corpus, f)]
            if held:
                need[word] = {f: queries.VERB_FORM_JUDGMENTS.get(word, {}).get(f) for f in held}
    missing = sorted(f"{w}->{f}" for w, forms in need.items() for f, v in forms.items() if v not in ("same", "cross"))
    extra = sorted(f"{w}->{f}" for w, forms in queries.VERB_FORM_JUDGMENTS.items() for f in forms
                   if f not in need.get(w, {}))
    if missing or extra:
        raise SystemExit(f"verb form judgments: unjudged {missing}; judged but not reachable {extra}")
    return {w: dict(sorted(need[w].items())) for w in sorted(need)}


def build_judgments(corpus: Corpus) -> dict:
    seen = set()
    items = []
    for spec in queries.QUERIES:
        if spec["id"] in seen:
            raise SystemExit(f"duplicate query id {spec['id']}")
        seen.add(spec["id"])
        items.append(build_query(corpus, spec))
    counts = {s: sum(1 for i in items if i["slice"] == s) for s in SLICES}
    for name, minimum in queries.SLICE_MINIMUMS.items():
        if counts[name] < minimum:
            raise SystemExit(f"slice {name}: {counts[name]} queries, minimum {minimum}")
    # misspelling-opening is the verifier's rows as they were run, and the verifier
    # wrote no negative for it (the re-ruling, item 3).
    for name in (n for n in queries.SLICE_MINIMUMS if n not in OPENING_SLICES):
        if not any(i.get("negative_of") == name for i in items):
            raise SystemExit(f"slice {name} has no negative")
    held = [next(c for c in i["checks"] if "edit" in c) for i in items if i["slice"] == "misspelling-heldout"]
    have = {kind: sum(1 for c in held if c["edit"] == kind) for kind in ("swap", "deletion", "insertion", "substitution")}
    have["two edits"] = sum(1 for c in held if c["edit"] == "two edits" and c["meant_code_points"] >= 8)
    have["name"] = sum(1 for c in held if c["where"] == "name")
    have["common"] = sum(1 for c in held if c["meant_df"] >= 8)
    have["short"] = sum(1 for c in held if c["meant_code_points"] == 4)
    for kind, minimum in HELDOUT_MISSPELLING_MIX.items():
        if have[kind] < minimum:
            raise SystemExit(f"misspelling-heldout: {have[kind]} rows of kind {kind}, minimum {minimum}")
    morph = [c for i in items if i["slice"] == "morphology-heldout" for c in i["checks"] if "kind" in c]
    have = {kind: sum(1 for i in items if i["slice"] == "morphology-heldout" and i["kind"] == kind)
            for kind in HELDOUT_MORPHOLOGY_MIX}
    for direction in ("query plural", "query singular"):
        have[direction] = sum(1 for c in morph if c.get("direction") == direction)
    for kind, minimum in HELDOUT_MORPHOLOGY_MIX.items():
        if have[kind] < minimum:
            raise SystemExit(f"morphology-heldout: {have[kind]} rows of kind {kind}, minimum {minimum}")
    accent = [i for i in items if i["slice"] == "accent-heldout"]
    have = {kind: sum(1 for i in accent if i["kind"] == kind) for kind in HELDOUT_ACCENT_MIX}
    for direction in ("plain query", "accented query"):
        have[direction] = sum(1 for i in accent for c in i["checks"] if c.get("direction") == direction)
    for kind, minimum in HELDOUT_ACCENT_MIX.items():
        if have[kind] < minimum:
            raise SystemExit(f"accent-heldout: {have[kind]} rows of kind {kind}, minimum {minimum}")
    tamil = [i for i in items if i["slice"] == "tamil-heldout"]
    for rule in TAMIL_RULES:
        if not any(i.get("rule") == rule for i in tamil):
            raise SystemExit(f"tamil-heldout: no row of the rule {rule}")
    for kind in TAMIL_GUARDS:
        if not any(i.get("tamil_guard") == kind for i in tamil):
            raise SystemExit(f"tamil-heldout: no guard of the kind {kind}")
    verbs = [i for i in items if i["slice"] == "verbform-heldout"]
    for kind, minimum in HELDOUT_VERBFORM_MIX.items():
        have = sum(1 for i in verbs if i["kind"] == kind)
        if have < minimum:
            raise SystemExit(f"verbform-heldout: {have} rows of kind {kind}, minimum {minimum}")
    for pair in VERBFORM_PAIRS:
        if not any(i.get("direction") in pair for i in verbs):
            raise SystemExit(f"verbform-heldout: no verb row of the directions {sorted(pair)}")
    for feature in VERBFORM_FEATURES:
        if not any(i.get("feature") == feature for i in verbs):
            raise SystemExit(f"verbform-heldout: no verb row with the feature {feature}")
    hygiene = new_file_hygiene(corpus)
    if hygiene:
        raise SystemExit("verbform-heldout files: " + "; ".join(hygiene))
    hygiene = s5t8_file_hygiene(corpus)
    if hygiene:
        raise SystemExit("S5-T8 files: " + "; ".join(hygiene))
    for name, minimum in queries.NEGATIVE_SET_MINIMUMS.items():
        if counts[name] < minimum:
            raise SystemExit(f"{name}: {counts[name]} queries, minimum {minimum}")
        for kind in NEGATIVE_KINDS:
            if not any(i["slice"] == name and i["kind"] == kind for i in items):
                raise SystemExit(f"{name}: no negative of the kind {kind}")
    if sum(queries.NEGATIVE_SET_MINIMUMS.get(n, 0) and counts[n] for n in queries.NEGATIVE_SET_MINIMUMS) < 30:
        raise SystemExit("fewer than 30 negatives in S5-T8's two sets")
    for kind in PRECISION_KINDS:
        if not any(i["slice"] == "precision-control" and i["kind"] == kind for i in items):
            raise SystemExit(f"precision-control: no row of the kind {kind}")
    cross_files = {(r["root_id"], r["path"]) for i in items if i["slice"] == "verbform-cross"
                   for r in i["expected"] if r["grade"] == 2}
    if len(cross_files) < VERBFORM_CROSS_ANSWER_FILES:
        raise SystemExit(f"verbform-cross: answers in {len(cross_files)} files, minimum {VERBFORM_CROSS_ANSWER_FILES}")
    short = [i for i in items if i["slice"] == "misspelling-short"]
    if sum(1 for i in short if i["kind"] == "swap") < SHORT_MIN_SWAPS:
        raise SystemExit(f"misspelling-short: fewer than {SHORT_MIN_SWAPS} swapped pairs")
    if {len(c["typed"]) for i in short for c in i["checks"] if "levenshtein" in c} != {6, 7}:
        raise SystemExit("misspelling-short: typed words of 6 and of 7 code points both needed")
    opening = [i for i in items if i["slice"] == "misspelling-opening"]
    for kind, minimum in OPENING_MINIMUMS.items():
        if sum(1 for i in opening if i["kind"] == kind) < minimum:
            raise SystemExit(f"misspelling-opening: fewer than {minimum} rows of kind {kind}")
    if counts["negatives-short"] < SHORT_MIN_NEGATIVES:
        raise SystemExit(f"negatives-short: {counts['negatives-short']} queries, minimum {SHORT_MIN_NEGATIVES}")
    judged = verb_form_judgments(corpus, items)
    if sum(1 for i in items if i.get("transposition")) < 5:
        raise SystemExit("fewer than 5 transpositions")
    if sum(1 for i in items if i.get("only_form")) < 3:
        raise SystemExit("fewer than 3 rows where only the form differs")
    return {
        "version": 1,
        "pack": "j2",
        "roots": list(ROOTS),
        "conventions": {
            "lines": "1-based; a line ends at \\n or \\r\\n; a final line without a terminator counts; a BOM is not part of any line",
            "grades": "2 the answer; 1 useful context; 0 a named distractor (never relevant). Title intent: grade 2 is the whole file",
            "hit_match": "a hit matches a row when root_id and path are equal and the line ranges overlap; a hit takes the highest-grade unmatched row it overlaps and each row is matched at most once",
            "modes": "knowledge = search_knowledge (lexical, top 10, search_field content and both); find:words, find:phrase, find:prefix = find in that mode, first page of 10",
            "negatives": "an empty answer set; rows name the distractors; reported as hit count, top hit and whether it is a named distractor",
            "checks": "asserted by generate.py with the analyzer-v2 simple case fold",
            "misleading": "S5-T8: for a negative, each of its first 5 hits is labelled by what brought it (README, What counts as misleading); stop_words and verb_form_judgments are the labels' inputs",
        },
        "slices": {name: queries.SLICE_MINIMUMS.get(name, queries.NEGATIVE_SET_MINIMUMS.get(
            name, SHORT_MIN_NEGATIVES if name == "negatives-short" else 0)) for name in SLICES},
        "counts": counts,
        "files": [{"root_id": p.split("/", 1)[0], "path": p.split("/", 1)[1], "bytes": len(d),
                   "lines": len(corpus.lines[p]), "sha256": hashlib.sha256(d).hexdigest()}
                  for p, d in corpus.files.items()],
        "queries": items,
        # S5-T8: what the measure of what misleads reads (README, "What counts as misleading").
        "stop_words": list(STOP_WORDS),
        "verb_form_judgments": judged,
    }


# ---------------------------------------------------------------- readme ---

README_HEAD = """\
# J2: the judged fixture (S5-T1)

Invented content only: the Varnell family of Thistlecombe (Maren, Joss, Pip in
Year 5, Wren in Year 2, Paati their grandmother, Biscuit the dog), Thistlecombe
Primary, Mill Lane, Hollow Woods. No real person, place or product. Phone numbers
are from the ranges set aside for drama.

J2 says where keyword search loses. It holds {total} queries in seven slices,
a held-out title slice (S5-T2), a held-out misspelling slice (S5-T3), held-out
morphology, accent and Tamil slices (S5-T4), a held-out verb-form slice (S5-T5),
a cross-word verb-form slice and a precision-control slice (S5-T8) and named
negatives in three sets (S5-T8 adds a tuning set and a held-out set), graded 0 to
2, over three roots. Its numbers are the baseline later
search tasks are judged against (`fixtures/j2/baseline.json`,
`scripts/j2_gate.py`); see `docs/evaluation.md`, section J2.

Do not edit the files by hand. `python3 fixtures/j2/generate.py` rewrites every
file, `judgments.json` and this README from `content.py`, `queries.py` and
`generate.py`; `tests/test_j2_fixture.py` regenerates into a temporary folder and
compares byte for byte. Every line range is computed from the files. Before it
writes, the generator asserts each query's `checks`: they are what keeps each
miss real. A change to a judgment is a reviewed commit named in its task's Report.

Run it: `python3 scripts/relevance_smoke.py --pack j2` (the Python reference) and
`python3 scripts/j2_run.py --searchd PATH` (the shipped engine), then
`python3 scripts/j2_gate.py RUN.json`.

## Roots and special files

| Root | Files |
| --- | --- |
{roots}

| File | Why |
| --- | --- |
{special}

## Slices

| Slice | Queries | Minimum | What it holds |
| --- | ---: | ---: | --- |
{slices}

## What counts as misleading (S5-T8)

Written before any S5-T8 run; `scripts/j2_negatives.py` computes it from a J2
results file. It reads negatives only: the queries of `negatives`,
`negatives-tuning` and `negatives-heldout`, which no file answers.

Each of a negative's first five hits is labelled by what brought it. A hit's words
are the body words of its cited range and the title words of its file (the folders
below the root, then the stem). For each query word, the hit's words it matches
through the query's groups (the Python reference's `core._query_groups` for that
query, so a rule under test is reflected) are labelled:

- **real**: the query word itself, or a word with its fold-groups-v1 key
  (`analyzer_v3.key`), or a verb form of it (`verb_forms.forms`) judged `same` in
  `judgments.json` → `verb_form_judgments`;
- **cross**: a verb form of it judged `cross` there (a form of another word: hop
  and hope, even and evening);
- **near**: a word fuzzy-v1 gave it (a spelling neighbour);
- **stop**: the query word is a stop word (the list below), whatever it matches.

A hit takes the first label of real, cross, near, stop that any of its matches
has; a hit with no match is labelled `other` (reported; none is expected). A hit
labelled stop, near or cross is **misleading**: it is there by a stop word alone,
a spelling neighbour or another word's form. A real-word hit holds a word of the
question, so it is counted apart, not as misleading.

The measure, per set, surface and variant (content, both):

- the mean top-5 hit count: the mean over the set's queries of the hits returned,
  at most five;
- the share of queries whose first hit is misleading;
- the mean misleading hits and, apart, the mean real-word hits in the first five.

No score threshold is defined: a hit counts whatever its score.

The stop words are Lucene's 33 English stop words and `my` (S5-T8 ruling 1 names
it among the common words in file names): {stop_words}.

## Queries

Grade-2 rows only; `judgments.json` holds every row with its note.

| Id | Slice | Mode | Query | Answer (grade 2) |
| --- | --- | --- | --- | --- |
{queries}
"""

SPECIAL = [
    ("home/garden-diary.md", "the long file: a year of daily lines, one section per month"),
    ("laptop/log/homework-tracker.txt", "a long plain-text log, windowed by line-window-v1; one window holds \"dentist appointment\" twice"),
    ("school/trip-permission-museum.md", "CRLF line endings"),
    ("home/shopping-list.md", "CRLF line endings, no headings"),
    ("school/class-rules.md", "UTF-8 byte order mark"),
    ("school/pe-kit.txt", "one line, no final newline"),
    ("school/empty-notes.txt", "zero bytes"),
    ("school/newsletter-autumn.md", "decomposed (NFD) Noël"),
    ("school/letters/letter-home-oct.txt", "ligature ﬁ, as pasted from a PDF"),
    ("school/notes-from-phone.txt", "full-width digits"),
    ("school/spelling-lists.md", "Setext headings"),
    ("school/tamil/tamil-class.md", "Tamil (school root)"),
    ("home/tamil/பாட்டி-கடிதங்கள்.md", "Tamil, with a Tamil file name (home root)"),
    ("laptop/tamil/tamil-stories.md", "Tamil (laptop root)"),
]

SLICE_TEXT = {
    "control": "what today's engine answers; must stay at rank 1",
    "misspelling": "one or two letters off; transpositions marked",
    "morphology": "plural, tense and possessive forms",
    "accent": "accents, ß, ligatures, full-width forms, both directions",
    "tamil": "Tamil inflections, both directions, plus suffix guards",
    "title": "the words name the file (stem or folder), not its body",
    "phrase": "the words adjacent in the answer, apart in a distractor",
    "negatives": "nothing answers; distractors named",
    "title-heldout": "title intent held out from S5-T2's weight; no word of the title slice",
    "misspelling-heldout": "misspellings held out from S5-T3's rule; no typed or meant word of the misspelling slice",
    "morphology-heldout": "plural forms held out from S5-T4's key function, keep-list guards, -ing/-ed, a name-only form",
    "accent-heldout": "accent, width and compatibility forms held out from S5-T4; short words, a merge guard",
    "tamil-heldout": "Tamil inflections held out from S5-T4's suffix list, each rule once, three guards",
    "verbform-heldout": "-ing/-ed/base forms held out from S5-T5's rule; doubled, dropped e, -ied; look-alike guards; held typed words",
    "verbform-cross": "a word whose verb forms (R) reach another word's form; the answer holds its own form (hop and hope, even and evening, tap and tape); judged both sides",
    "precision-control": "what a precision rule must keep at rank 1: stop words in a file name, near spellings, verb forms",
    "negatives-tuning": "S5-T8's negatives for tuning: a stop word in a file name, a near word, a near topic, a cross-word form, Tamil, accent, one word of two held",
    "negatives-heldout": "the same kinds, held out from S5-T8's candidates until each is declared",
    "misspelling-short": "S5-T8 Phase 1c, held out: typed words of 6 or 7 code points two Levenshtein edits off (a swapped pair, a dropped and an added letter, two wrong letters)",
    "negatives-short": "correctly spelt 6 or 7 code point words no file holds, with a near word",
    "misspelling-opening": "held out, written by S5-T8's verifier: typed words of 6 or 7 code points two edits off in the first or second letter, asked as short questions; the answer is every file holding the meant word",
}


def render_readme(files: dict[str, bytes], judgments: dict) -> str:
    roots = "\n".join(f"| `{r}/` | {sum(1 for p in files if p.startswith(r + '/'))} |" for r in ROOTS)
    special = "\n".join(f"| `{p}` | {why} |" for p, why in SPECIAL)
    slices = "\n".join(f"| {s} | {judgments['counts'][s]} | {judgments['slices'][s] or '-'} | {SLICE_TEXT[s]} |"
                       for s in SLICES)
    rows = []
    for item in judgments["queries"]:
        answers = [r for r in item["expected"] if r["grade"] == 2]
        where = "; ".join(f"`{r['root_id']}/{r['path']}` {r['start_line']}-{r['end_line']}" for r in answers) or "none"
        rows.append(f"| {item['id']} | {item['slice']} | {item['mode']} | `{item['query']}` | {where} |")
    total = len(judgments["queries"])
    for path, _ in SPECIAL:
        assert path in files, path
    stop_words = ", ".join(f"`{w}`" for w in judgments["stop_words"])
    return README_HEAD.format(total=total, roots=roots, special=special, slices=slices, queries="\n".join(rows),
                              stop_words=stop_words)


def write_tree(out: Path) -> None:
    files = build_files()
    corpus = Corpus(files)
    judgments = build_judgments(corpus)
    for path, data in files.items():
        target = out / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    (out / "judgments.json").write_text(json.dumps(judgments, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (out / "README.md").write_text(render_readme(files, judgments), encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, default=HERE)
    args = parser.parse_args(argv)
    write_tree(args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

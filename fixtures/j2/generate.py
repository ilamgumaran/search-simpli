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

from src.search_platform import analyzer_v3  # noqa: E402
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
          "verbform-heldout")
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
    """S5-T5's new files keep out of every earlier slice's query words and of their
    fold-groups-v1 forms (the keys `analyzer_v3.key` gives), in body and path, so
    that adding them moves no earlier row by a word they hold."""
    earlier: set[str] = set()
    for spec in queries.QUERIES:
        if spec["slice"] != "verbform-heldout" and spec.get("of") != "verbform-heldout":
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
    negative = spec["slice"] == "negatives"
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
    elif s == "negatives":
        present = [t for t in query_tokens if corpus.df(t) > 0]
        need(bool(present), "at least one query word occurs in the corpus")
        checks.append({"check": "no row with grade 1 or more; at least one query word occurs in the corpus",
                       "present": present})
    elif s != "control":
        raise SystemExit(f"{qid}: unknown slice {s}")

    item = {"slice": s, "id": qid, "question": spec["question"], "query": spec["query"], "mode": spec["mode"],
            "expected": expected}
    if negative:
        item["negative"] = True
        item["negative_of"] = spec["of"]
    if s in ("misspelling", "misspelling-heldout"):
        item["transposition"] = spec["typo"][2]
    if s == "misspelling-heldout":
        item["edit"] = spec["edit"]
    if s == "morphology":
        item["only_form"] = bool(spec.get("only_form"))
    if s == "tamil" and "guard" in spec:
        item["guard"] = spec["guard_kind"]
    if s in ("morphology-heldout", "accent-heldout"):
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
    for name in queries.SLICE_MINIMUMS:
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
        },
        "slices": {name: queries.SLICE_MINIMUMS.get(name, 0) for name in SLICES},
        "counts": counts,
        "files": [{"root_id": p.split("/", 1)[0], "path": p.split("/", 1)[1], "bytes": len(d),
                   "lines": len(corpus.lines[p]), "sha256": hashlib.sha256(d).hexdigest()}
                  for p, d in corpus.files.items()],
        "queries": items,
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
morphology, accent and Tamil slices (S5-T4), a held-out verb-form slice (S5-T5) and named negatives, graded 0 to 2, over three roots. Its numbers are the baseline later
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
    return README_HEAD.format(total=total, roots=roots, special=special, slices=slices, queries="\n".join(rows))


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

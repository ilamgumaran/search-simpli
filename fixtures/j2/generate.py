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
import json  # noqa: E402
import unicodedata  # noqa: E402
from pathlib import Path, PurePosixPath  # noqa: E402

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent.parent))

import content  # noqa: E402
import queries  # noqa: E402
from src.search_platform.core import _filename_tokenize, file_chunks  # noqa: E402

ROOTS = ("school", "home", "laptop")
BOM = b"\xef\xbb\xbf"
SLICES = ("control", "misspelling", "morphology", "accent", "tamil", "title", "phrase", "negatives")
MODES = ("knowledge", "words", "phrase", "prefix")


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


def contains_run(seq: list[str], want: list[str]) -> bool:
    return any(seq[i:i + len(want)] == want for i in range(len(seq) - len(want) + 1))


# ------------------------------------------------------------- judgments ---

class CheckFailed(SystemExit):
    pass


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
    if s == "misspelling":
        typed, meant, swap = spec["typo"]
        need(typed in query_tokens, f"{typed} is a query word")
        need(corpus.df(typed) == 0, f"{typed} occurs in no file (df {corpus.df(typed)})")
        distance = osa_distance(typed, meant)
        need(1 <= distance <= 2, f"{typed}->{meant} distance {distance}")
        need(is_one_swap(typed, meant) == swap, f"{typed}->{meant} transposition flag {swap}")
        need(meant in first, f"{meant} is in the answer")
        checks.append({"check": "misspelt word in no file; Damerau distance 1-2; transposition flag; meant word in the answer",
                       "typed": typed, "meant": meant, "df": 0, "distance": distance, "transposition": swap})
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
    elif s == "title":
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
    if s == "misspelling":
        item["transposition"] = spec["typo"][2]
    if s == "morphology":
        item["only_form"] = bool(spec.get("only_form"))
    if s == "tamil" and "guard" in spec:
        item["guard"] = spec["guard_kind"]
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
            "modes": "knowledge = search_knowledge (lexical, top 10, search_field content and both); words, phrase, prefix = find, first page of 10",
            "negatives": "an empty answer set; rows name the distractors; reported as hit count, top hit and whether it is a named distractor",
            "checks": "asserted by generate.py with the analyzer-v2 simple case fold",
        },
        "slices": {name: queries.SLICE_MINIMUMS.get(name, 0) for name in SLICES},
        "counts": counts,
        "queries": items,
    }


# ---------------------------------------------------------------- readme ---

README_HEAD = """\
# J2: the judged fixture (S5-T1)

Invented content only: the Varnell family of Thistlecombe (Maren, Joss, Pip in
Year 5, Wren in Year 2, Paati their grandmother, Biscuit the dog), Thistlecombe
Primary, Mill Lane, Hollow Woods. No real person, place or product. Phone numbers
are from the ranges set aside for drama.

J2 says where keyword search loses. It holds {total} queries in seven slices
plus named negatives, graded 0 to 2, over three roots. Its numbers are the
baseline later search tasks are judged against (`fixtures/j2/baseline.json`,
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

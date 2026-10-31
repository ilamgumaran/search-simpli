#!/usr/bin/env python3
"""Generate the family-folder fixture and its frozen judgments (S3-T7).

Deterministic and standard-library only. The fixture roots (school/, home/,
laptop/) and judgments.json are written next to this script, or into --out.
Every expected line range and sha256 in judgments.json is computed here from the
files, never typed by hand. Run again after editing content.py; the unit test
regenerates into a temporary folder and compares byte for byte.
"""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent.parent))

import content  # noqa: E402
from src.search_platform.core import _line_chunks, tokenize  # noqa: E402

ROOTS = ("school", "home", "laptop")
BOM = b"\xef\xbb\xbf"
BIG_PATH = "laptop/big-log.txt"
BIG_LINES = 15_500
BIG_PLANTED = {
    4711: "the lighthouse keeper counted seventeen gulls near the harbour wall",
    12003: "a second note about the harbour and the lighthouse in the fog",
}

ATX = re.compile(r"^(#{1,6})[ \t]+(.*?)[ \t]*#*[ \t]*$")
SETEXT = re.compile(r"^(=+|-+)[ \t]*$")


# ------------------------------------------------------------------ files ---

def big_log_bytes() -> bytes:
    """About 1.3 MB of invented household-log lines; a fixed LCG, no randomness."""
    onsets = ["b", "d", "f", "g", "k", "l", "m", "n", "p", "r", "s", "t", "v", "z"]
    vowels = ["a", "e", "i", "o", "u"]
    state = 20261031
    def nxt(limit: int) -> int:
        nonlocal state
        state = (state * 1103515245 + 12345) % (2 ** 31)
        return (state >> 8) % limit
    vocabulary = []
    seen = set()
    while len(vocabulary) < 600:
        word = "".join(onsets[nxt(14)] + vowels[nxt(5)] for _ in range(2 + nxt(2)))
        if word not in seen:
            seen.add(word)
            vocabulary.append(word)
    out = []
    for number in range(1, BIG_LINES + 1):
        if number in BIG_PLANTED:
            out.append(f"{number:05d} {BIG_PLANTED[number]}")
        else:
            out.append(f"{number:05d} " + " ".join(vocabulary[nxt(600)] for _ in range(11)))
    return ("\n".join(out) + "\n").encode("utf-8")


def maths_script_text() -> str:
    code = ["```python"]
    for n in range(2, 13):
        code.append(f"# build the table for {n}")
        code.append(f"table_{n} = [{n} * i for i in range(1, 13)]")
        code.append(f"# print the table for {n}")
        code.append(f'print("{n} times table:", table_{n})')
        code.append(f"assert len(table_{n}) == 12, 'table {n} has twelve rows'")
        code.append("")
    code.append("```")
    return content.MATHS_SCRIPT_HEAD + "\n".join(code) + "\n" + content.MATHS_SCRIPT_TAIL


CHANT_PHRASE = "round the old mill pond"


def chant_text() -> str:
    """A playground chant written one word per line, so the phrase spans five lines.

    The phrase is placed so that the 1,600-character window of line-window-v1 ends
    exactly four lines into it: the window that holds its start stops one word short
    and the next window (which restarts three lines back) begins one word late. No
    single chunk holds the whole phrase: the one known chunk-local miss. The search
    for the offset is deterministic; the assertion keeps it honest.
    """
    pattern = ["clap", "stomp", "turn", "jump"]
    want = tokenize(CHANT_PHRASE)
    head = ["Playground chant, read down the page.", ""]
    for pad in range(150, 400):
        words = [pattern[i % 4] for i in range(pad)] + CHANT_PHRASE.split() + [pattern[i % 4] for i in range(30)]
        text = "\n".join(head + words) + "\n"
        chunks = [tokenize(c) for _, _, c in _line_chunks(text)]
        whole = any(any(c[i:i + len(want)] == want for i in range(len(c))) for c in chunks)
        if not whole:
            return text
    raise SystemExit("no offset puts the chant phrase across a chunk boundary")


def build_files() -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    for path, text in content.FILES.items():
        files[path] = text.encode("utf-8")
    for path, text in content.CRLF_FILES.items():
        files[path] = text.replace("\n", "\r\n").encode("utf-8")
    for path, text in content.BOM_FILES.items():
        files[path] = BOM + text.encode("utf-8")
    files["school/clapping-chant.txt"] = chant_text().encode("utf-8")
    files["laptop/maths-script.md"] = maths_script_text().encode("utf-8")
    files[BIG_PATH] = big_log_bytes()
    return dict(sorted(files.items()))


# --------------------------------------------------------------- analysis ---

def line_spans(data: bytes) -> list[tuple[int, int]]:
    """(start, end) byte offsets of each line, end excluding its terminator (\\n or \\r\\n)."""
    spans = []
    start = 0
    while start < len(data):
        nl = data.find(b"\n", start)
        if nl < 0:
            spans.append((start, len(data)))
            break
        end = nl - 1 if nl > start and data[nl - 1:nl] == b"\r" else nl
        spans.append((start, end))
        start = nl + 1
    return spans


def text_lines(data: bytes) -> list[str]:
    body = data[len(BOM):] if data.startswith(BOM) else data
    return [body[s:e].decode("utf-8") for s, e in line_spans(body)]


class Corpus:
    def __init__(self, files: dict[str, bytes]):
        self.files = files
        self.lines = {p: text_lines(d) for p, d in files.items()}
        self._outline = {}

    def anchor(self, path: str, needle: str) -> int:
        hits = [i + 1 for i, line in enumerate(self.lines[path]) if needle in line]
        if len(hits) != 1:
            raise SystemExit(f"anchor {needle!r} in {path}: {len(hits)} matches, need exactly 1")
        return hits[0]

    def span_sha(self, path: str, start: int, end: int) -> tuple[str, int]:
        """sha256 and length of the original bytes from line `start` to line `end`,
        terminators between lines kept, the last line's terminator excluded.
        A BOM is a prefix of line 1's bytes only when start is 1; fixtures avoid that."""
        data = self.files[path]
        offset = len(BOM) if data.startswith(BOM) else 0
        spans = line_spans(data[offset:])
        chunk = data[offset + spans[start - 1][0]: offset + spans[end - 1][1]]
        return hashlib.sha256(chunk).hexdigest(), len(chunk)

    def outline(self, path: str) -> dict:
        if path in self._outline:
            return self._outline[path]
        lines = self.lines[path]
        front = None
        first = 0
        if lines and lines[0] == "---":
            for i in range(1, len(lines)):
                if lines[i] == "---":
                    fields = {}
                    for item in lines[1:i]:
                        key, _, value = item.partition(":")
                        fields[key.strip()] = value.strip()
                    front = {"start_line": 1, "end_line": i + 1, "fields": fields}
                    first = i + 1
                    break
        heads = []
        in_fence = False
        i = first
        while i < len(lines):
            line = lines[i]
            if line.startswith("```"):
                in_fence = not in_fence
            elif not in_fence:
                m = ATX.match(line)
                if m:
                    heads.append({"level": len(m.group(1)), "text": m.group(2), "line": i + 1})
                elif (line.strip() and i + 1 < len(lines) and SETEXT.match(lines[i + 1])
                        and not line.startswith(("-", "*", "+", "#", "`"))):
                    level = 1 if lines[i + 1].startswith("=") else 2
                    heads.append({"level": level, "text": line.strip(), "line": i + 1})
                    i += 1
            i += 1
        total = len(lines)
        for n, head in enumerate(heads):
            end = total
            for later in heads[n + 1:]:
                if later["level"] <= head["level"]:
                    end = later["line"] - 1
                    break
            head["end_line"] = end
        result = {"front_matter": front, "headings": heads, "lines": total, "chunker": "md-section-v1"}
        self._outline[path] = result
        return result

    def section_path(self, path: str, line: int) -> list[str]:
        stack: list[dict] = []
        for head in self.outline(path)["headings"]:
            if head["line"] > line:
                break
            stack = [h for h in stack if h["level"] < head["level"]] + [head]
        return [h["text"] for h in stack]

    def heading_lines(self, path: str) -> list[int]:
        return [h["line"] for h in self.outline(path)["headings"]]

    def tokens(self, path: str) -> list[tuple[str, int]]:
        return [(t, n + 1) for n, line in enumerate(self.lines[path]) for t in tokenize(line)]

    def phrase(self, phrase: str) -> list[dict]:
        want = tokenize(phrase)
        hits = []
        for path in self.files:
            toks = self.tokens(path)
            for i in range(len(toks) - len(want) + 1):
                if [t for t, _ in toks[i:i + len(want)]] == want:
                    start, end = toks[i][1], toks[i + len(want) - 1][1]
                    hits.append(entry(path, start, end, chunk_local_miss=not self.in_one_chunk(path, want)))
        return sorted_entries(hits)

    def in_one_chunk(self, path: str, want: list[str]) -> bool:
        """True when some line-window-v1 chunk of the file holds the whole phrase."""
        text = "\n".join(self.lines[path])
        for _, _, chunk in _line_chunks(text):
            toks = tokenize(chunk)
            if any(toks[i:i + len(want)] == want for i in range(len(toks))):
                return True
        return False

    def prefix(self, prefix: str) -> list[dict]:
        hits = []
        for path in self.files:
            seen = set()
            for token, line in self.tokens(path):
                if token.startswith(prefix) and line not in seen:
                    seen.add(line)
                    hits.append(entry(path, line, line))
        return sorted_entries(hits)

    def both(self, a: str, b: str) -> list[dict]:
        hits = []
        for path in self.files:
            for n, line in enumerate(self.lines[path]):
                toks = set(tokenize(line))
                if a in toks and b in toks:
                    hits.append(entry(path, n + 1, n + 1))
        return sorted_entries(hits)


def entry(path: str, start: int, end: int, **extra) -> dict:
    root, _, rest = path.partition("/")
    item = {"root_id": root, "path": rest, "start_line": start, "end_line": end}
    for key, value in extra.items():
        if value:
            item[key] = value
    return item


def sorted_entries(items: list[dict]) -> list[dict]:
    return sorted(items, key=lambda e: (e["root_id"], e["path"], e["start_line"], e["end_line"]))


# ------------------------------------------------------------- judgments ---

def build_judgments(corpus: Corpus) -> dict:
    A = corpus.anchor
    sp = corpus.section_path

    def span(path, first, last=None, **extra):
        a = A(path, first)
        b = A(path, last) if last else a
        item = entry(path, a, b)
        item["section_path"] = sp(path, a)
        item.update(extra)
        return item

    scenarios = []

    def scenario(number, title, question, kind, **fields):
        scenarios.append({"id": f"uc007-{number:02d}", "scenario": number, "title": title,
                          "question": question, "kind": kind, **fields})

    scenario(1, "Find tide table", "Find tide table.", "words", query="tide table", mode="words",
             expected=corpus.both("tide", "table"),
             rule="every line holding both words; a hit counts when its line range overlaps")
    scenario(2, "Exact phrase count me in", "Find the exact phrase count me in.", "phrase",
             query="count me in", mode="phrase", ref="phrase:p1")
    scenario(3, "Prefix photosyn", "Which notes mention anything starting with photosyn?", "prefix",
             query="photosyn*", mode="prefix", ref="prefix:x1")
    scenario(4, "Outline of science-notes.md", "Show me the outline of science-notes.md.", "outline",
             root_id="school", path="science-notes.md", ref="outline:o1")
    scenario(5, "Open lines 40 to 60", "Open lines 40 to 60 of that file.", "read_span",
             root_id="school", path="science-notes.md", ref="read_span:s1", context_lines=1)
    scenario(6, "Spelling test next week",
             "What did the teacher say about the spelling test next week?", "answer",
             query="teacher said spelling test next week", mode="words",
             expected=[span("school/notes.md", "Ms Orrin said the spelling test", "Practise the tricky ones")],
             citation="school/notes.md > Class notes > Week 7 > Spelling")
    scenario(7, "Band concert date", "When is the band concert?", "answer",
             query="when is the band concert", mode="words",
             expected=[span("school/notes.md", "- Band concert: Friday 6"),
                       span("school/newsletter-oct.md", "- Band concert: Friday 6")],
             note="the date sits inside a list item; the citation names the heading the item sits under")
    scenario(8, "Newts", "Is there anything in my folders about newts?", "empty",
             query="newts", mode="words", expected=[], expected_empty=True,
             note="the corpus holds no such word; the answer must say the folders hold nothing about it")
    pi = "laptop/project-ideas.md"
    sections = []
    for head in corpus.outline(pi)["headings"]:
        lines = corpus.lines[pi]
        i = head["line"]  # 0-based index of the line after the heading
        while i < head["end_line"] and not lines[i].strip():
            i += 1
        j = i
        while j < head["end_line"] and lines[j].strip() and not ATX.match(lines[j]):
            j += 1
        sections.append({"section_path": sp(pi, head["line"]), "heading_line": head["line"],
                         "first_span": {"start_line": i + 1, "end_line": j} if j > i else None})
    scenario(9, "Summarise the project-ideas note", "Summarise the project-ideas note.", "summary",
             root_id="laptop", path="project-ideas.md", outline_ref="outline:o2",
             expected_sections=sections,
             note="outline plus the first span of each section (first paragraph or list under the heading)")
    scenario(10, "After the dough rests", "What does the recipe say to do after the dough rests?", "phrase_neighbour",
             query="the dough rests", mode="phrase", ref="phrase:p2",
             words_query="what to do after the dough rests",
             expected_neighbour=span("home/recipes/bread.md", "4. Tip it out"),
             note="the phrase hit is step 3; the step after it is step 4 (the next span)")

    def lifecycle(number, title, question, steps):
        scenario(number, title, question, "lifecycle", status="not implemented until S3-T3/T4", steps=steps)

    lifecycle(11, "A new file lands; a pending file shows by name",
              "A new file lands in the iCloud folder on another device; a file not yet downloaded shows as pending.", [
        {"op": "apply_changes", "changes": [{"op": "add", "root_id": "home", "path": "inbox/firefly-note.md",
                                              "text": "# Firefly note\n\nWe saw one firefly by the pond.\n"}],
         "expect_report": {"added": 1, "changed": 0, "removed": 0, "pending": 0}},
        {"op": "find", "query": "firefly", "mode": "words",
         "expect_hits": [{"root_id": "home", "path": "inbox/firefly-note.md", "start_line": 1, "end_line": 3}]},
        {"op": "apply_changes", "changes": [{"op": "pending", "root_id": "home", "path": "inbox/late-arrival.md", "size": 5000}],
         "expect_report": {"pending": 1}},
        {"op": "index_status", "expect": {"pending_paths": [{"root_id": "home", "path": "inbox/late-arrival.md"}]}},
        {"op": "apply_changes", "changes": [{"op": "add", "root_id": "home", "path": "inbox/late-arrival.md",
                                              "text": "# Late arrival\n\nThe parcel came by canal boat.\n"}],
         "expect_report": {"added": 1, "pending": 0}},
        {"op": "find", "query": "canal", "mode": "words",
         "expect_hits": [{"root_id": "home", "path": "inbox/late-arrival.md", "start_line": 1, "end_line": 3}]},
    ])
    soup = "home/recipes/soup.md"
    lifecycle(12, "A note is renamed", "A note is renamed; old citations stop and the new name works.", [
        {"op": "find", "query": "lentils", "mode": "words", "roots": ["home"],
         "expect_hits_include": [entry(soup, 1, len(corpus.lines[soup]))]},
        {"op": "apply_changes", "changes": [{"op": "move", "root_id": "home", "path": "recipes/soup-v2.md",
                                              "moved_from": "recipes/soup.md"}],
         "expect_report": {"moved": 1, "added": 0, "removed": 0}},
        {"op": "find", "query": "lentils", "mode": "words", "roots": ["home"],
         "expect_paths_include": ["recipes/soup-v2.md"], "expect_paths_exclude": ["recipes/soup.md"]},
    ])
    lifecycle(13, "A folder is removed", "A folder is removed from the app; nothing from it is returned again.", [
        {"op": "find", "query": "robot rover motors", "mode": "words", "roots": ["laptop"],
         "expect_hits_include": [entry(pi, 1, 1)]},
        {"op": "apply_changes", "changes": [{"op": "remove_root", "root_id": "laptop"}],
         "expect_report": {"roots_removed": 1}},
        {"op": "find", "query": "robot rover motors", "mode": "words", "expect_empty": True},
        {"op": "index_status", "expect": {"roots": ["school", "home"], "no_trace_of_roots": ["laptop"]}},
    ])
    # the lifecycle probe above uses a placeholder line range; the real range is the whole
    # first match, so pin it to the actual lines now.
    robot = A(pi, "A small rover that follows a line")
    scenarios[-1]["steps"][0]["expect_hits_include"] = [entry(pi, robot, robot)]

    phrase_specs = [
        ("p1", "count me in", "a phrase wrapped over two lines in one section, plus two plain occurrences"),
        ("p2", "the dough rests", "a phrase inside a numbered step"),
        ("p3", CHANT_PHRASE,
         "the known chunk-local miss: five one-word lines straddle a 1,600-character window edge, so no single chunk holds the phrase"),
        ("p4", "the the", "the repeated-tokens file: adjacent identical words are a legal phrase"),
        ("p5", "பள்ளி விடுமுறை", "Tamil phrase in a Tamil file, two occurrences"),
    ]
    phrase = []
    for pid, text, why in phrase_specs:
        hits = corpus.phrase(text)
        misses = [h for h in hits if h.get("chunk_local_miss")]
        item = {"id": pid, "query": text, "mode": "phrase", "why": why,
                "expected": [{k: v for k, v in h.items() if k != "chunk_local_miss"} for h in hits],
                "expected_engine_miss": [{k: v for k, v in h.items() if k != "chunk_local_miss"} for h in misses]}
        phrase.append(item)

    prefix_specs = [
        ("x1", "photosyn", "words that begin the same way across three files"),
        ("x2", "spell", "one prefix covers the words spell and spelling (names, notes and lists)"),
        ("x3", "harbo", "includes one hit deep inside the file larger than 1 MB"),
        ("x4", "lighthou", "a prefix that is also a whole word; a planted line in the large file"),
        ("x5", "கணி", "Tamil prefix of a whole token"),
    ]
    prefix = []
    for pid, text, why in prefix_specs:
        prefix.append({"id": pid, "query": text + "*", "mode": "prefix", "prefix": text,
                       "why": why, "expected": corpus.prefix(text)})

    outline_specs = [
        ("o1", "school/science-notes.md", "Setext and ATX headings mixed, depth 3, front matter"),
        ("o2", pi, "ATX headings to depth 3 with front matter"),
        ("o3", "school/spelling-lists.md", "Setext only, no front matter"),
        ("o4", "laptop/maths-script.md", "hash-sign lines inside a fenced block are not headings"),
        ("o5", "home/crlf-shopping.md", "CRLF line endings: same line numbers as LF"),
    ]
    outline = []
    for oid, path, why in outline_specs:
        root, _, rest = path.partition("/")
        outline.append({"id": oid, "root_id": root, "path": rest, "why": why, **corpus.outline(path)})

    def rs(rid, path, start, end, why, context_lines=1):
        sha, size = corpus.span_sha(path, start, end)
        root, _, rest = path.partition("/")
        return {"id": rid, "root_id": root, "path": rest, "start_line": start, "end_line": end,
                "context_lines": context_lines, "byte_length": size, "sha256": sha, "why": why}

    read_span = [
        rs("s1", "school/science-notes.md", 40, 60, "the UC-007 example: lines 40 to 60 with one line of context"),
        rs("s2", "home/crlf-shopping.md", 3, 8, "CRLF: the returned bytes keep the inner \\r\\n"),
        rs("s3", "home/bom-checklist.md", 3, 6, "a BOM file: line numbers ignore the BOM; the span starts after line 1"),
        rs("s4", "home/no-final-newline.txt", 3, 4, "ends at the last line, which has no terminator"),
        rs("s5", BIG_PATH, 9000, 9010, "deep inside the file larger than 1 MB"),
    ]
    return {
        "version": 2,
        "pack": "family-folder",
        "roots": list(ROOTS),
        "conventions": {
            "lines": "1-based; a line ends at \\n or \\r\\n; a final line without a terminator counts; an empty file has 0 lines; a BOM is not part of any line",
            "hit_match": "a returned hit matches an expected entry when root_id and path are equal and the line ranges overlap",
            "phrase_prefix": "the expected sets are complete across all pages; tokens come from the analyzer",
            "read_span": "sha256 of the original bytes from the first byte of start_line to the last byte of end_line, inner line terminators kept, the last line's terminator excluded",
            "outline_end_line": "the line before the next heading of the same or higher level, else the last line",
        },
        "gates": {"words_recall_at_5": 0.9, "phrase_recall": 1.0, "outline_exactness": 1.0,
                  "read_span_byte_exact": 1.0, "prefix_recall": 1.0},
        "scenarios": scenarios,
        "phrase": phrase,
        "prefix": prefix,
        "outline": outline,
        "read_span": read_span,
    }


# ---------------------------------------------------------------- readme ---

README_HEAD = """\
# Family-folder fixture and judgment pack (S3-T7)

Invented content only: made-up people, a made-up school (Larkfield Primary),
made-up places. It stands in for the three folders of UC-007: a school folder, a
home folder and a laptop folder. **Frozen**: `judgments.json` is the acceptance
oracle for S3-T1..T6. A later task that needs a judgment changed says so in its
Report, and the change is a reviewed commit, not a silent edit.

Do not edit the files by hand. `python3 fixtures/family-folder/generate.py`
rewrites every file and `judgments.json` (and this README) deterministically from
`content.py` and `generate.py`; `tests/test_family_folder_fixture.py` regenerates
into a temporary folder and compares byte for byte. Every line range, section
path and sha256 below is computed from the files, never typed.

## Roots and special files

| Root | Files | Notes |
| --- | --- | --- |
{roots}

Special files the S3 chunker, reader and tests rely on:

| File | Why |
| --- | --- |
| `laptop/big-log.txt` | {big} bytes, more than 1 MB, deterministic (fixed LCG, no randomness), committed; lines 4711 and 12003 are planted |
| `home/house-rules.md`, `laptop/archive/house-rules-old.md` | identical content under different names and in different roots |
| `home/crlf-shopping.md` | CRLF line endings |
| `home/no-final-newline.txt` | last line has no terminator |
| `home/bom-checklist.md` | UTF-8 byte order mark |
| `home/tamil-notes.md` | Tamil text |
| `home/repeated-tokens.md` | "the the", "to to", "is is" |
| `home/empty.txt` | zero bytes |
| `laptop/maths-script.md` | the long fenced block ({fence} codepoints, more than the 1,600 `max_chars`) with `#` lines that are not headings |
| `laptop/meeting-notes.md` | the second, short fenced block |
| `school/clapping-chant.txt` | one word per line; holds the known chunk-local phrase miss |
| `school/science-notes.md`, `school/spelling-lists.md` | Setext headings (and ATX in the first) |

Front matter is the YAML subset `key: value` (strings only). Headings nest to depth 3.

## Conventions

- Lines are 1-based. A line ends at `\\n` or `\\r\\n`; a final line without a terminator counts; an empty file has 0 lines; a BOM is not part of any line.
- A returned hit matches an expected entry when `root_id` and `path` are equal and the line ranges overlap.
- Phrase and prefix expected sets are complete across all pages. Tokens come from the repository analyzer (`tokenize`), so case is folded and punctuation separates words.
- `read_span`: the sha256 of the original bytes from the first byte of `start_line` to the last byte of `end_line`, inner terminators kept (so CRLF stays CRLF), the last line's terminator excluded. Cases avoid line 1 of the BOM file because a BOM is not a line.
- Outline `end_line` is the line before the next heading of the same or higher level, else the last line. `#` lines inside a fence are not headings. Setext headings report the text line.

## Gates (UC-007)

Phrase recall 1.00, prefix recall 1.00, outline exactness 1.00, `read_span` byte-exact,
words recall@5 at least 0.9. `python3 scripts/relevance_smoke.py --pack family-folder`
runs what the Python reference can answer today (words cases and the empty newt
question) and prints a skipped count for the rest until S3-T1/T2 land.

## The 13 UC-007 scenarios

{scenarios}

## Phrase cases

Expected sets are every adjacent-words occurrence in the folders, after case folding.

{phrase}

**Known expected miss (CAP-19 open decision 1).** Case `p3` is true text in the
folder, but its five words sit on five separate lines that straddle the end of a
1,600-character window of `line-window-v1`: the window holding the first words
stops one word short and the next window, which restarts three lines back, begins
one word late. A chunk-local positional index cannot return it. The judgment lists
it under `expected_engine_miss`; S3-T2's test asserts the miss and the recall gate
counts it as excluded, not as a failure. `generate.py` searches for the placement
and asserts that no single chunk holds the phrase. Every other phrase case is
found.

## Prefix cases

{prefix}

## Outline cases

{outline}

## read_span cases

{read_span}
"""


def build_readme(files: dict[str, bytes], judgments: dict) -> str:
    def cell(items: list[dict]) -> str:
        return "<br>".join(f"`{e['root_id']}/{e['path']}` {e['start_line']}-{e['end_line']}" for e in items) or "none"

    per_root = []
    for root in ROOTS:
        names = [p for p in files if p.startswith(root + "/")]
        md = sum(1 for p in names if p.endswith(".md"))
        per_root.append(f"| `{root}/` | {len(names)} | {md} Markdown, {len(names) - md} text |")
    scen = ["| # | Question | Kind | Expected |", "| --- | --- | --- | --- |"]
    for sc in judgments["scenarios"]:
        if "expected" in sc:
            exp = cell(sc["expected"]) if sc["expected"] else "empty result"
        elif "ref" in sc:
            exp = f"see `{sc['ref']}` below"
        elif sc["kind"] == "summary":
            exp = f"outline of `laptop/project-ideas.md` plus the first span of {len(sc['expected_sections'])} sections"
        else:
            exp = f"{len(sc['steps'])} steps (apply_changes report and find results; S3-T3/T4)"
        if sc["kind"] == "phrase_neighbour":
            exp = f"phrase `p2`; then the next step at {cell([sc['expected_neighbour']])}"
        if sc["kind"] in ("answer",):
            exp += " (section path in `judgments.json`)"
        scen.append(f"| {sc['scenario']} | {sc['question']} | {sc['kind']} | {exp} |")
    phrase = ["| id | Query | Expected | Note |", "| --- | --- | --- | --- |"]
    for c in judgments["phrase"]:
        extra = " **expected engine miss**" if c["expected_engine_miss"] else ""
        phrase.append(f"| {c['id']} | `{c['query']}` | {cell(c['expected'])} | {c['why']}{extra} |")
    prefix = ["| id | Query | Expected lines | Note |", "| --- | --- | --- | --- |"]
    for c in judgments["prefix"]:
        prefix.append(f"| {c['id']} | `{c['query']}` | {cell(c['expected'])} | {c['why']} |")
    outline = ["| id | File | Headings | Note |", "| --- | --- | --- | --- |"]
    for c in judgments["outline"]:
        outline.append(f"| {c['id']} | `{c['root_id']}/{c['path']}` | {len(c['headings'])} over {c['lines']} lines | {c['why']} |")
    rs = ["| id | File | Lines | Bytes | Note |", "| --- | --- | --- | --- | --- |"]
    for c in judgments["read_span"]:
        rs.append(f"| {c['id']} | `{c['root_id']}/{c['path']}` | {c['start_line']}-{c['end_line']} | {c['byte_length']} | {c['why']} |")
    fence = max(len(m) for m in re.findall(r"```python\n(.*?)```", files["laptop/maths-script.md"].decode("utf-8"), re.S))
    return README_HEAD.format(
        roots="\n".join(per_root), big=len(files[BIG_PATH]), fence=fence,
        scenarios="\n".join(scen), phrase="\n".join(phrase), prefix="\n".join(prefix),
        outline="\n".join(outline), read_span="\n".join(rs))


# ----------------------------------------------------------------- main ---

def write_tree(out: Path) -> dict[str, bytes]:
    files = build_files()
    for path, data in files.items():
        target = out / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    judgments = build_judgments(Corpus(files))
    (out / "judgments.json").write_text(
        json.dumps(judgments, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (out / "README.md").write_text(build_readme(files, judgments), encoding="utf-8")
    return files


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--out", type=Path, default=HERE)
    args = parser.parse_args(argv)
    files = write_tree(args.out)
    print(f"wrote {len(files)} files and judgments.json to {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

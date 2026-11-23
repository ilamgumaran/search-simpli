#!/usr/bin/env python3
"""The exact-string question set of `scan` (S6-T24, plan step H3; CAP-25; ADR 0006 section 11).

A second judged set, frozen separately from the 181 text-search questions
(`fixtures/text-search/judgments.json`, untouched). Each question is a `scan`
request (pattern, mode, case, whole word) over the judged folder of S6-T22,
unchanged (`scripts/gen_text_search_corpus.py`, its `corpus_sha256` checked),
and its answer is the exact set of lines, `path:line`, that `scan` must
return: every one of them and no other. For a literal question the answer
also holds each line's match offsets (code points, `[start, end)`).

**The expected lines are derived here, without the engine and without the
Python reference's `scan`:**

- lines are `str.splitlines()` of each file's text, a leading BOM left out
  (the rule `read_span` numbers by);
- a literal is found with `str.find`, non-overlapping and leftmost; under
  `insensitive` both sides are first folded code point by code point with the
  analyser's simple fold (`search_platform.core.simple_fold`, the definition
  the engine's table is generated from); `smart` is `insensitive` unless a
  code point of the pattern changes under that fold;
- a regex question carries, beside the pattern sent to `scan`, a pattern for
  Python's `re` written by hand for this generator (`expect_re`), in which
  `{W}` is a class of the analyser's word code points built here from
  `unicodedata` (letters, digits of every number category, the marks Mn and Mc, ZWNJ, ZWJ;
  no `_`) and `{NW}` its complement;
- `whole_word`: the code points before and after the match are not word code
  points (or are the line's ends).

**And again by `grep`:** a question marked `grep` names the arguments for
`grep -rn` (`-F` or `-E`, `-i`, `-w`) and a pattern in `grep`'s own syntax.
`--freeze` and the test run `grep` over a written copy of the folder with
`LC_ALL=C` and require its `(path, line)` set to equal the generator's. A
question `grep` cannot answer the same way names the reason instead
(`\\w` without `_`, word code points outside ASCII, `smart`).

Usage:

    python3 scripts/exact_string_questions.py --write fixtures/text-search/exact-strings.json
    python3 scripts/exact_string_questions.py --check fixtures/text-search/exact-strings.json
        # exit 1 when the file differs from what this script writes
    python3 scripts/exact_string_questions.py --freeze fixtures/text-search/exact-string-digests.json
        # one digest per question; also runs grep and fails on any disagreement
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT))

import gen_text_search_corpus as corpus_mod  # noqa: E402
from src.search_platform.core import simple_fold  # noqa: E402

JUDGMENTS = ROOT / "fixtures" / "text-search" / "judgments.json"

KINDS = {
    "number": "numbers with punctuation: amounts, dates, phone numbers, durations",
    "code": "codes and identifiers, with hyphens and underscores",
    "quoted": "exact phrases with stop words and punctuation, as a person would quote them",
    "line-shape": "lines of a shape, as a regular expression",
    "case": "the three case options: the same letters with different answers",
    "whole-word": "whole_word on and off, and what a word code point is",
    "tamil": "Tamil script: literals, whole words and \\w with its marks",
    "no-answer": "near misses that occur nowhere; the answer is no line",
}

# ---------------------------------------------------------------------------
# The questions. `grep` is (flags, pattern) or a reason string.
# ---------------------------------------------------------------------------

QUESTIONS: list[dict] = []


def Q(qid, kind, question, pattern, *, mode="literal", case="smart", whole_word=False,
      expect_re=None, grep=None):
    QUESTIONS.append({
        "id": qid, "kind": kind, "question": question,
        "request": {"pattern": pattern, "mode": mode, "case": case, "whole_word": whole_word},
        "expect_re": expect_re, "grep": grep,
    })


def lit_grep(pattern, *flags):
    return {"args": ["-F", *flags], "pattern": pattern}


def re_grep(pattern, *flags):
    return {"args": ["-E", *flags], "pattern": pattern}


SMART = "smart: grep has no smart case"

# number
Q("num-01", "number", "Which line has the amount 45.00?", "45.00", grep=lit_grep("45.00"))
Q("num-02", "number", "Where is 2026-06-17 written?", "2026-06-17", grep=lit_grep("2026-06-17"))
Q("num-03", "number", "Which lines hold the phone number 01632 960418?", "01632 960418", grep=lit_grep("01632 960418"))
Q("num-04", "number", "Every phone number starting 01632 960.", "01632 960", grep=lit_grep("01632 960"))
Q("num-05", "number", "Where does 23.50 appear?", "23.50", grep=lit_grep("23.50"))
Q("num-06", "number", "Where does 120.00 appear?", "120.00", grep=lit_grep("120.00"))
Q("num-07", "number", "Which log lines say a request took 1.8 s?", "1.8 s", grep=lit_grep("1.8 s"))
Q("num-08", "number", "Which lines hold the time 20:3 (twenty past eight to twenty to nine)?", "20:3", grep=lit_grep("20:3"))

# code
Q("code-01", "code", "Where is tool TS-017 mentioned?", "TS-017", case="sensitive", grep=lit_grep("TS-017"))
Q("code-02", "code", "Find invoice INV-2026-014.", "INV-2026-014", case="sensitive", grep=lit_grep("INV-2026-014"))
Q("code-03", "code", "Where is the booking reference GCB-3307?", "GCB-3307", case="sensitive", grep=lit_grep("GCB-3307"))
Q("code-04", "code", "Find 48213-K.", "48213-K", case="sensitive", grep=lit_grep("48213-K"))
Q("code-05", "code", "Where is send_email used?", "send_email", case="sensitive", grep=lit_grep("send_email"))
Q("code-06", "code", "Where is reminded_for used?", "reminded_for", case="sensitive", grep=lit_grep("reminded_for"))
Q("code-07", "code", "Which file has the column loans_2026?", "loans_2026", case="sensitive", grep=lit_grep("loans_2026"))
Q("code-08", "code", "Every tool code from TS-001 to TS-009 and TS-010 onwards that starts TS-0.", "TS-0", case="sensitive", grep=lit_grep("TS-0"))

# quoted
Q("quote-01", "quoted", "\"do not tumble dry\"", "do not tumble dry", grep=lit_grep("do not tumble dry"))
Q("quote-02", "quoted", "\"out of order\"", "out of order", grep=lit_grep("out of order"))
Q("quote-03", "quoted", "\"spare key under the blue pot\"", "spare key under the blue pot", grep=lit_grep("spare key under the blue pot"))
Q("quote-04", "quoted", "\"first Tuesday of the month\"", "first Tuesday of the month", case="sensitive",
  grep=lit_grep("first Tuesday of the month"))
Q("quote-05", "quoted", "\"slow request GET /loans\"", "slow request GET /loans", case="sensitive",
  grep=lit_grep("slow request GET /loans"))
Q("quote-06", "quoted", "\"Gull Cottage, Porthwenna\"", "Gull Cottage, Porthwenna", case="sensitive",
  grep=lit_grep("Gull Cottage, Porthwenna"))
Q("quote-07", "quoted", "The XML declaration's version=\"1.0\".", "version=\"1.0\"", grep=lit_grep("version=\"1.0\""))
Q("quote-08", "quoted", "\"reminder run: 2 sent\"", "reminder run: 2 sent", grep=lit_grep("reminder run: 2 sent"))

# line-shape
Q("shape-01", "line-shape", "Rows that start with a date and a comma.", r"^\d{4}-\d{2}-\d{2},", mode="regex",
  case="sensitive", expect_re=r"^\d{4}-\d{2}-\d{2},", grep=re_grep("^[0-9]{4}-[0-9]{2}-[0-9]{2},"))
Q("shape-02", "line-shape", "Second-level Markdown headings.", r"^## ", mode="regex", case="sensitive",
  expect_re=r"^## ", grep=re_grep("^## "))
Q("shape-03", "line-shape", "Codes of two or three capitals, a hyphen and three digits.", r"\b[A-Z]{2,3}-\d{3}\b",
  mode="regex", case="sensitive",
  expect_re=r"(?<!{W})[A-Z]{2,3}-\d{3}(?!{W})", grep=re_grep("(^|[^A-Za-z0-9_])[A-Z]{2,3}-[0-9]{3}([^A-Za-z0-9_]|$)"))
Q("shape-04", "line-shape", "Log lines at WARN or ERROR.", r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d (WARN|ERROR) ",
  mode="regex", case="sensitive", expect_re=r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d (WARN|ERROR) ",
  grep=re_grep("^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} (WARN|ERROR) "))
Q("shape-05", "line-shape", "A tab, then a phone number, at the end of the line.", "\\t01632 960\\d{3}$", mode="regex",
  case="sensitive", expect_re="\t01632 960\\d{3}$", grep=re_grep("\t01632 960[0-9]{3}$"))
Q("shape-06", "line-shape", "Python functions defined at the start of a line (\\w has no underscore, so "
  "`def send_email(` is not one).", r"^def \w+\(", mode="regex", case="sensitive",
  expect_re=r"^def {W}+\(", grep="\\w has no _ in scan; grep's has")
Q("shape-07", "line-shape", "Amounts with two decimals.", r"\d+\.\d\d\b", mode="regex", case="sensitive",
  expect_re=r"\d+\.\d\d(?!{W})", grep=re_grep("[0-9]+\\.[0-9][0-9]([^A-Za-z0-9_]|$)"))
Q("shape-08", "line-shape", "Four-column CSV rows ending in an amount.", r"^[^,]*,[^,]*,[^,]*,\d+\.\d\d$",
  mode="regex", case="sensitive", expect_re=r"^[^,]*,[^,]*,[^,]*,\d+\.\d\d$",
  grep=re_grep("^[^,]*,[^,]*,[^,]*,[0-9]+\\.[0-9][0-9]$"))

# case
Q("case-01", "case", "pickle (smart: no capital, so any case)", "pickle", grep=lit_grep("pickle", "-i"))
Q("case-02", "case", "Pickle (smart: a capital, so this case only)", "Pickle", grep=lit_grep("Pickle"))
Q("case-03", "case", "pickle, case-sensitive", "pickle", case="sensitive", grep=lit_grep("pickle"))
Q("case-04", "case", "MIRA, case-insensitive", "MIRA", case="insensitive", grep=lit_grep("MIRA", "-i"))
Q("case-05", "case", "bee (smart)", "bee", grep=lit_grep("bee", "-i"))
Q("case-06", "case", "Bee (smart)", "Bee", grep=lit_grep("Bee"))
Q("case-07", "case", "warn (smart): WARN in the logs and the word warn", "warn", grep=lit_grep("warn", "-i"))
Q("case-08", "case", "copper lane (smart)", "copper lane", grep=lit_grep("copper lane", "-i"))

# whole-word
Q("word-01", "whole-word", "bee as a whole word", "bee", whole_word=True, grep=lit_grep("bee", "-i", "-w"))
Q("word-02", "whole-word", "50 as a whole word (after a dot counts: . is not a word code point)", "50",
  whole_word=True, grep=lit_grep("50", "-w"))
Q("word-03", "whole-word", "TS-01 as a whole word: every code continues with a digit", "TS-01",
  case="sensitive", whole_word=True, grep=lit_grep("TS-01", "-w"))
Q("word-04", "whole-word", "loan as a whole word, not loans", "loan", case="sensitive", whole_word=True,
  grep=lit_grep("loan", "-w"))
Q("word-05", "whole-word", "send as a whole word: send_email holds it, because _ is not a word code point",
  "send", case="sensitive", whole_word=True, grep="_ is not a word code point in scan; it is in grep -w")
Q("word-06", "whole-word", "Mira as a whole word", "Mira", whole_word=True, grep=lit_grep("Mira", "-w"))
Q("word-07", "whole-word", "s as a whole word", "s", case="sensitive", whole_word=True, grep=lit_grep("s", "-w"))
Q("word-08", "whole-word", "two digits as a whole word", r"\d{2}", mode="regex", case="sensitive", whole_word=True,
  expect_re=r"(?<!{W})\d{2}(?!{W})", grep=re_grep("[0-9]{2}", "-w"))

# tamil
Q("tamil-01", "tamil", "பொங்கல்", "பொங்கல்", grep=lit_grep("பொங்கல்"))
Q("tamil-02", "tamil", "முறுக்கு", "முறுக்கு", grep=lit_grep("முறுக்கு"))
Q("tamil-03", "tamil", "கோப்பை as a whole word", "கோப்பை", whole_word=True,
  grep="Tamil letters and marks are word code points in scan; in grep's C locale they are bytes")
Q("tamil-04", "tamil", "Words ending in காய் (the vowel signs are marks, inside \\w)", r"\w+காய்", mode="regex",
  case="sensitive", expect_re=r"{W}+காய்", grep="\\w over Tamil: marks are word code points in scan, not in grep")
Q("tamil-05", "tamil", "Headings in Tamil: #, a Tamil letter, then word code points (\\w alone would take every "
  "English heading too)", r"^# [அ-ஹ]\w*", mode="regex", case="sensitive",
  expect_re=r"^# [அ-ஹ]{W}*", grep="a class of Tamil letters and \\w over Tamil: code points in scan, bytes in grep")
Q("tamil-06", "tamil", "மீரா anywhere, also inside மீராவுக்கு", "மீரா", grep=lit_grep("மீரா"))
Q("tamil-07", "tamil", "மீரா as a whole word", "மீரா", whole_word=True,
  grep="Tamil letters and marks are word code points in scan; in grep's C locale they are bytes")
Q("tamil-08", "tamil", "ஜனவரி and a day", r"ஜனவரி \d+", mode="regex", case="sensitive", expect_re=r"ஜனவரி \d+",
  grep=re_grep("ஜனவரி [0-9]+"))

# no-answer
Q("none-01", "no-answer", "142.05", "142.05", grep=lit_grep("142.05"))
Q("none-02", "no-answer", "TS-0170", "TS-0170", case="sensitive", grep=lit_grep("TS-0170"))
Q("none-03", "no-answer", "01632 960419", "01632 960419", grep=lit_grep("01632 960419"))
Q("none-04", "no-answer", "INV-2026-016", "INV-2026-016", case="sensitive", grep=lit_grep("INV-2026-016"))
Q("none-05", "no-answer", "GCB-3308", "GCB-3308", case="sensitive", grep=lit_grep("GCB-3308"))
Q("none-06", "no-answer", "tumble dry do not", "tumble dry do not", grep=lit_grep("tumble dry do not"))
Q("none-07", "no-answer", "A US ZIP+4 code on a line of its own", r"^\d{5}-\d{4}$", mode="regex", case="sensitive",
  expect_re=r"^\d{5}-\d{4}$", grep=re_grep("^[0-9]{5}-[0-9]{4}$"))
Q("none-08", "no-answer", "An ERROR line about a 500", r"ERROR .*\b500\b", mode="regex", case="sensitive",
  expect_re=r"ERROR .*(?<!{W})500(?!{W})", grep=re_grep("ERROR .*(^|[^A-Za-z0-9_])500([^A-Za-z0-9_]|$)"))

# ---------------------------------------------------------------------------
# Deriving the answers.
# ---------------------------------------------------------------------------

WORD_CATEGORIES = {"Lu", "Ll", "Lt", "Lm", "Lo", "Nd", "Nl", "No", "Mn", "Mc"}


def is_word(ch: str) -> bool:
    """The analyser's token code points (analyzer_v2.zig): letters, digits, marks, ZWNJ, ZWJ."""
    return ch in ("\u200c", "\u200d") or unicodedata.category(ch) in WORD_CATEGORIES


def _word_class() -> tuple[str, str]:
    ranges = []
    start = None
    for cp in range(0x110000):
        inside = 0xD800 > cp or cp > 0xDFFF
        inside = inside and is_word(chr(cp))
        if inside and start is None:
            start = cp
        if not inside and start is not None:
            ranges.append((start, cp - 1))
            start = None
    if start is not None:
        ranges.append((start, 0x10FFFF))
    body = "".join(re.escape(chr(a)) if a == b else f"{re.escape(chr(a))}-{re.escape(chr(b))}" for a, b in ranges)
    return f"[{body}]", f"[^{body}]"


_CLASSES: tuple[str, str] | None = None


def compile_expect(template: str) -> re.Pattern:
    global _CLASSES
    if _CLASSES is None:
        _CLASSES = _word_class()
    word, not_word = _CLASSES
    return re.compile(template.replace("{NW}", not_word).replace("{W}", word))


def lines_of(data: bytes) -> list[str]:
    text = data.decode("utf-8")
    if text.startswith("\ufeff"):
        text = text[1:]
    return text.splitlines()


def fold(text: str) -> str:
    return "".join(simple_fold(ch) for ch in text)


def case_applied(request: dict) -> str:
    if request["case"] != "smart":
        return request["case"]
    pattern = request["pattern"]
    if request["mode"] == "regex":
        # Letters of escapes (\d \w \s \b and their capitals) are syntax, not written code points.
        pattern = re.sub(r"\\[dDwWsSbB]", "", pattern)
    return "sensitive" if any(simple_fold(ch) != ch for ch in pattern) else "insensitive"


def literal_spans(line: str, needle: str, insensitive: bool, whole_word: bool) -> list[list[int]]:
    hay = fold(line) if insensitive else line
    pin = fold(needle) if insensitive else needle
    spans = []
    at = 0
    while True:
        found = hay.find(pin, at)
        if found < 0:
            return spans
        end = found + len(pin)
        if whole_word and ((found > 0 and is_word(line[found - 1])) or (end < len(line) and is_word(line[end]))):
            at = found + 1
            continue
        spans.append([found, end])
        at = end


def regex_hits(line: str, pattern: re.Pattern, whole_word: bool) -> bool:
    if not whole_word:
        return pattern.search(line) is not None
    raise AssertionError("whole_word regex questions spell the word test in expect_re")


def answer(corpus: dict[str, bytes], q: dict) -> dict:
    request = q["request"]
    applied = case_applied(request)
    lines: list[str] = []
    offsets: dict[str, list[list[int]]] = {}
    pattern = compile_expect(q["expect_re"]) if request["mode"] == "regex" else None
    if pattern is not None and applied == "insensitive":
        raise AssertionError(f"{q['id']}: a regex question names its case as sensitive")
    for path in sorted(corpus):
        for number, line in enumerate(lines_of(corpus[path]), 1):
            if pattern is None:
                spans = literal_spans(line, request["pattern"], applied == "insensitive", request["whole_word"])
                if spans:
                    lines.append(f"{path}:{number}")
                    offsets[f"{path}:{number}"] = spans
            elif pattern.search(line):
                lines.append(f"{path}:{number}")
    out = {"case_applied": applied, "lines": lines}
    if pattern is None:
        out["offsets"] = offsets
    return out


def check_corpus(corpus: dict[str, bytes]) -> dict:
    recorded = json.loads(JUDGMENTS.read_text(encoding="utf-8"))["corpus"]
    digest = corpus_mod.corpus_digest(corpus)
    if digest != recorded["corpus_sha256"]:
        raise SystemExit(f"the judged folder changed: {digest} != {recorded['corpus_sha256']}")
    return recorded


def questions_data() -> dict:
    corpus = corpus_mod.build_corpus()
    recorded = check_corpus(corpus)
    rows = []
    for q in QUESTIONS:
        row = {key: q[key] for key in ("id", "kind", "question", "request")}
        if q["expect_re"] is not None:
            row["expect_re"] = q["expect_re"]
        row["grep"] = q["grep"] if isinstance(q["grep"], dict) else {"reason": q["grep"]}
        row["expect"] = answer(corpus, q)
        rows.append(row)
    kinds = {kind: {"what": what, "questions": sum(1 for q in QUESTIONS if q["kind"] == kind)} for kind, what in KINDS.items()}
    return {
        "schema": "exact-strings-v1",
        "pack": "text-search",
        "corpus": recorded,
        "conventions": {
            "lines": "1-based; str.splitlines() of the text without a leading BOM (read_span's numbering)",
            "lines_order": "path by bytes, then line: scan's order over one root",
            "offsets": "literal questions: [start, end) code points into the line, non-overlapping, leftmost first",
            "expect_re": "regex questions: the generator's own Python pattern; {W} is the analyser's word code points, {NW} the rest",
            "case_applied": "what smart resolves to: insensitive unless a code point the pattern writes changes under the simple fold",
            "grep": "args and pattern for grep -rn over a copy of the folder with LC_ALL=C; or the reason grep cannot answer the same way",
            "frozen": "fixtures/text-search/exact-string-digests.json holds a sha256 per question over id, kind, question, request, expect_re, grep and expect",
        },
        "kinds": kinds,
        "questions": rows,
    }


def render() -> str:
    return json.dumps(questions_data(), ensure_ascii=False, indent=2) + "\n"


FROZEN_FIELDS = ("id", "kind", "question", "request", "expect_re", "grep", "expect")


def question_digest(row: dict) -> str:
    frozen = {key: row.get(key) for key in FROZEN_FIELDS}
    return hashlib.sha256(json.dumps(frozen, ensure_ascii=False, sort_keys=True).encode("utf-8")).hexdigest()


def render_digests(data: dict) -> str:
    digests = {q["id"]: question_digest(q) for q in data["questions"]}
    return json.dumps({"schema": "exact-string-digests-v1", "fields": list(FROZEN_FIELDS), "questions": digests},
                      indent=2) + "\n"


def grep_lines(folder: Path, spec: dict, grep: str) -> list[str]:
    """`grep -rn` over `folder`, as `path:line` in scan's order."""
    run = subprocess.run([grep, "-rn", *spec["args"], "-e", spec["pattern"], "."], cwd=folder,
                         capture_output=True, env={**os.environ, "LC_ALL": "C"})
    if run.returncode not in (0, 1):
        raise RuntimeError(f"grep failed ({run.returncode}): {run.stderr.decode('utf-8', 'replace')}")
    found = set()
    for raw in run.stdout.split(b"\n"):
        if not raw:
            continue
        path, number, _ = raw.split(b":", 2)
        path = path.decode("utf-8")
        found.add((path[2:] if path.startswith("./") else path, int(number)))
    return [f"{p}:{n}" for p, n in sorted(found, key=lambda item: (item[0].encode("utf-8"), item[1]))]


def grep_disagreements(data: dict, grep: str) -> list[str]:
    problems = []
    with tempfile.TemporaryDirectory() as tmp:
        corpus_mod.write_corpus(Path(tmp) / "judged")
        for q in data["questions"]:
            if "args" not in q["grep"]:
                continue
            got = grep_lines(Path(tmp) / "judged", q["grep"], grep)
            if got != q["expect"]["lines"]:
                problems.append(f"{q['id']}: grep {len(got)} lines, generator {len(q['expect']['lines'])}; "
                                f"grep only {sorted(set(got) - set(q['expect']['lines']))[:5]}, "
                                f"generator only {sorted(set(q['expect']['lines']) - set(got))[:5]}")
    return problems


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[0] not in ("--write", "--check", "--freeze"):
        print(__doc__.split("Usage:")[1], file=sys.stderr)
        return 2
    target = Path(argv[1])
    if argv[0] == "--freeze":
        data = questions_data()
        grep = shutil.which("grep")
        if grep is None:
            print("--freeze needs grep on PATH", file=sys.stderr)
            return 1
        problems = grep_disagreements(data, grep)
        if problems:
            print("grep disagrees with the generator:\n" + "\n".join(problems), file=sys.stderr)
            return 1
        target.write_text(render_digests(data), encoding="utf-8")
        print(f"wrote {target}: {len(data['questions'])} digests; grep agrees on "
              f"{sum(1 for q in data['questions'] if 'args' in q['grep'])}")
        return 0
    text = render()
    if argv[0] == "--write":
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        print(f"wrote {target}: {len(QUESTIONS)} questions")
        return 0
    if not target.is_file() or target.read_text(encoding="utf-8") != text:
        print(f"{target} differs from what scripts/exact_string_questions.py writes", file=sys.stderr)
        return 1
    print(f"{target}: up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""S6-T8: the highlight query set (ruling 3), added to S6-T7's query file.

    python3 -I highlight_queries.py BASE.json FOLDER_OR_CHANGES OUT.json

Reads every text file under FOLDER (or every `add` of a changes JSON, as
J2's is) and adds to BASE's `finds`, in all three modes where they apply:

- Tamil words (any codepoint of U+0B80-U+0BFF), and a two-word Tamil phrase;
- words holding a combining mark (Unicode category M*: Tamil vowel signs,
  or a Latin letter with U+0301 and the like);
- tokens of 15 or more codepoints, and a prefix of each;
- the two words around a gap of 15 or more codepoints of non-word text
  (each word, and the pair as a phrase);
- the first and last word of a file and the first word after each Markdown
  heading mark (a chunk's first and last tokens);
- the field boundaries 14, 15 and 16 in length (one word each where the
  corpus has one).

At most PER_KIND finds per kind, chosen in file order (deterministic). The
counts per kind are printed; a kind the corpus does not have is reported as
0, not invented. Not part of any library.
"""
import base64
import json
import re
import sys
import unicodedata
from pathlib import Path

PER_KIND = 8
WORD = re.compile(r"[^\W_]+(?:[̀-ͯஂ-்ௗ]+[^\W_]*)*", re.UNICODE)


def texts(source: Path):
    if source.is_file():
        changes = json.loads(source.read_text(encoding="utf-8"))["changes"]
        for change in changes:
            if change.get("op") == "add":
                yield change["path"], base64.b64decode(change["content_base64"]).decode("utf-8", "replace")
        return
    for f in sorted(source.rglob("*")):
        if f.is_file() and f.suffix.lower() in (".md", ".txt", ".markdown", ".text", ""):
            try:
                yield str(f.relative_to(source)), f.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue


def has_mark(word: str) -> bool:
    return any(unicodedata.category(c).startswith("M") for c in word)


def main(argv):
    base = json.loads(Path(argv[1]).read_text(encoding="utf-8"))
    kinds = {k: [] for k in ("tamil", "tamil phrase", "combining mark", "long token", "long prefix",
                             "long gap word", "long gap phrase", "chunk first", "chunk last", "heading first",
                             "length 14", "length 15", "length 16")}

    def add(kind, query, mode):
        item = {"query": query, "mode": mode}
        if len(kinds[kind]) < PER_KIND and item not in kinds[kind]:
            kinds[kind].append(item)

    for _, text in texts(Path(argv[2])):
        words = [(m.start(), m.end(), m.group()) for m in WORD.finditer(text)]
        if not words:
            continue
        add("chunk first", words[0][2], "words")
        add("chunk last", words[-1][2], "words")
        for m in re.finditer(r"^#{1,6}[ \t]+(\S+)", text, re.M):
            w = WORD.search(m.group(1))
            if w:
                add("heading first", w.group(), "words")
        for (s0, e0, w0), (s1, e1, w1) in zip(words, words[1:]):
            if s1 - e0 >= 15:
                add("long gap word", w1, "words")
                add("long gap phrase", f"{w0} {w1}", "phrase")
        for i, (_, _, w) in enumerate(words):
            n = len(w)
            if any("஀" <= c <= "௿" for c in w):
                add("tamil", w, "words")
                if i + 1 < len(words) and any("஀" <= c <= "௿" for c in words[i + 1][2]):
                    add("tamil phrase", f"{w} {words[i + 1][2]}", "phrase")
            if has_mark(w):
                add("combining mark", w, "words")
            if n >= 15:
                add("long token", w, "words")
                add("long prefix", w[:6] + "*", "prefix")
            if n in (14, 15, 16):
                add(f"length {n}", w, "words")
    finds = list(base["finds"])
    for kind, items in kinds.items():
        for item in items:
            if item not in finds:
                finds.append(item)
    base["finds"] = finds
    Path(argv[3]).write_text(json.dumps(base, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps({"base_finds": len(json.loads(Path(argv[1]).read_text(encoding='utf-8'))["finds"]),
                      "finds": len(finds), **{k: len(v) for k, v in kinds.items()}}, ensure_ascii=False))


if __name__ == "__main__":
    main(sys.argv)

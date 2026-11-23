#!/usr/bin/env python3
"""S6-T23 Part 1: is every change of the judged set's results a newly read file taking a rank?

    python3 -I order_check.py SEARCHD WRAPPER BEFORE_INDEX AFTER_INDEX NEW_FILES.json > order-check.txt

BEFORE_INDEX is `searchd index` of the real judged folder; AFTER_INDEX the scorer's index of the renamed copy (the
wrapper maps its paths back). NEW_FILES.json is the before engine's scorer JSON (its corpus.files_not_read names the 24). For
every question, form (typed, query) and field (both, content), with --top-k 10, it compares the passages
(path, start_line, end_line) before and after: `same` when equal; `inserted` when removing the newly read files'
passages from the after list leaves a prefix of the before list, in order (the old passages kept their order and
were only pushed down); otherwise `reordered`, which means the added files changed the scores of old passages
(BM25's document count, document frequencies and average length change with them) enough to reorder or replace
them.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def passages(binary: str, index: str, text: str, field: str) -> list[tuple]:
    out = subprocess.run([binary, "evidence", index, text, "--search-field", field, "--top-k", "10"],
                         capture_output=True, check=True).stdout
    env = json.loads(out)
    rows = [r["citation"] for r in env["results"]] if "results" in env else env["evidence"]
    return [(r["path"], r["start_line"], r["end_line"]) for r in rows]


def main(argv: list[str]) -> int:
    searchd, wrapper, before_index, after_index, new_json = argv
    new = set(json.loads(Path(new_json).read_text(encoding="utf-8"))["corpus"]["files_not_read"])
    questions = json.loads((ROOT / "fixtures/text-search/judgments.json").read_text(encoding="utf-8"))["questions"]
    counts, reordered = {}, []
    for field in ("both", "content"):
        for form in ("typed", "query"):
            for q in questions:
                text = q["question"] if form == "typed" else q["query"]
                b = passages(searchd, before_index, text, field)
                a = passages(wrapper, after_index, text, field)
                kept = [p for p in a if p[0] not in new]
                verdict = "same" if a == b else ("inserted" if kept == b[:len(kept)] else "reordered")
                counts[(field, form, verdict)] = counts.get((field, form, verdict), 0) + 1
                if verdict == "reordered":
                    reordered.append(f"{field}/{form} {q['id']}: before {b[:4]} after (old files only) {kept[:4]}")
    for key in sorted(counts):
        print(" ".join(key), counts[key])
    print()
    print("\n".join(reordered))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

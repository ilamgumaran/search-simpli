#!/usr/bin/env python3
"""S5-T5 prototype (builder, Phase 1): what rule R costs on a corpus's dictionary,
in counts (ruling 6), for the two placements ruling 2 allows:

- by generated form: one dictionary lookup per form R generates for a query term
  (`verbforms.forms`), stated per query word and as the maximum over the dictionary;
- by key: a map from each base to the dictionary words having it, built from the
  dictionary once; its entries are the (base, word) pairs over every word R
  applies to.

    python3 scripts/prototypes/s5t5/cost.py CORPUS_DIR [WORD ...]

CORPUS_DIR is e.g. the 10k timing corpus (`scripts/gen_timing_corpus.py DIR 10000`).
Tokens are analyzer-v2's (`core._filename_tokenize`: NFC, simple fold), as the Zig
dictionary holds them; title terms are the files' path tokens. Counts only."""
from __future__ import annotations

import statistics
import sys
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import verbforms as V  # noqa: E402

import src.search_platform.core as core  # noqa: E402
from src.search_platform import analyzer_v3  # noqa: E402

WORDS = ["system", "systems", "hybrid", "retrieval", "indexing", "hashing", "operating", "ranking",
         "schedulers", "tables", "benico", "bazechas", "cycled", "painted", "planting"]


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    root = Path(argv[0])
    words = argv[1:] or WORDS
    body_df: Counter = Counter()
    titles: set = set()
    files = 0
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        files += 1
        text = path.read_text(encoding="utf-8", errors="replace")
        body_df.update(set(core._filename_tokenize(text)))
        rel = path.relative_to(root)
        for part in rel.parent.parts + (rel.stem,):
            titles.update(core._filename_tokenize(part))
    vocabulary = set(body_df) | titles
    eligible = [w for w in vocabulary if V.word_of(w) is not None]
    lookups = [len(V.forms(w)) for w in eligible]
    pairs = sum(len(V.bases(w)) for w in eligible)
    with_base = [w for w in eligible if len(V.bases(w)) > 1]
    keys = {}
    for w in vocabulary:
        keys.setdefault(analyzer_v3.key(w), set()).add(w)
    print(f"corpus: {files} files; dictionary {len(body_df)} body terms, {len(titles)} title terms, "
          f"{len(vocabulary)} distinct")
    print(f"R applies to {len(eligible)} dictionary words (4-49 letters a-z); "
          f"{len(with_base)} of them have a base other than their plural form (-ing, -ed, -ied)")
    print(f"by generated form: lookups per word min {min(lookups)}, median {statistics.median(lookups)}, "
          f"max {max(lookups)}")
    print(f"by key: a base -> words map over the dictionary holds {pairs} (base, word) entries "
          f"({len(eligible)} words, {pairs - len(eligible)} beyond each word's own base)")
    print("per query word: applies | lookups | held forms | v1 group empty | C/E members")
    for w in words:
        t = core._filename_tokenize(w)[0]
        forms = V.forms(t)
        held = [f for f in forms if f in vocabulary]
        mates = keys.get(analyzer_v3.key(t), set())
        empty = not mates
        if empty:
            ce = held
        else:
            cap = max(body_df.get(m, 0) for m in mates)
            ce = [f for f in held if f not in mates and body_df.get(f, 0) <= cap]
        print(f"  {t}: {V.word_of(t) is not None} | {len(forms)} | {held} | {empty} | "
              f"C {held if empty else []} E {ce}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

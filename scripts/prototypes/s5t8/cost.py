#!/usr/bin/env python3
"""S5-T8 prototype (builder, Phase 1b): what each candidate costs on a corpus, in
counts (ruling 4: the cost count on the 10k timing corpus).

    python3 scripts/prototypes/s5t8/cost.py CORPUS_DIR [QUERY ...]

CORPUS_DIR is e.g. the 10k timing corpus (`scripts/gen_timing_corpus.py DIR 10000`).
The index is the Python reference's (`core.build_index`), so the counts are over its
chunks: a term's df is its chunk df. Counts only, no timing.

- W:  title terms the title part scores, today and under W, per query.
- Wb: body postings walked per query (the sum of the query terms' chunk df), today
      and under Wb.
- F:  fuzzy-v1's candidate pool and the distance computations it makes per typed
      word (unchanged under F), and the near words kept, today and under F.
- X:  R's exact lookups (forms generated) over every dictionary word R applies to,
      today and under X, and the shape tests X adds (one per base)."""
from __future__ import annotations

import statistics
import sys
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import rules as R  # noqa: E402

import src.search_platform.core as core  # noqa: E402
from src.search_platform import verb_forms  # noqa: E402

QUERIES = ["hybrid retrieval", "how does the hybrid retrieval work for a search", "the and of to in",
           "the system", "benico", "systm", "retreival", "schedulars", "operating", "opratin", "sistems"]


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    root = Path(argv[0])
    queries = argv[1:] or QUERIES
    index = core.build_index(root)
    chunks = index["chunks"]
    df: Counter = Counter()
    for c in chunks:
        df.update(c["terms"].keys())
    roots = core._title_root_ids(index, None)
    fields = core._title_fields(chunks, roots)
    title_vocabulary = {t for tokens in fields.values() for t in tokens}
    files = len(fields)
    print(f"corpus: {files} files, {len(chunks)} chunks, {len(df)} body terms, {len(title_vocabulary)} title terms")
    stop_df = {w: df.get(w, 0) for w in sorted(R.STOP) if df.get(w, 0)}
    print(f"stop words held in the body (chunk df): {stop_df}")
    print(f"stop words held in titles: {sorted(w for w in R.STOP if w in title_vocabulary)}")
    print("\nper query: W title terms today -> W | Wb body postings today -> Wb")
    for q in queries:
        title_terms = core._filename_tokenize(q)
        kept = [t for t in title_terms if t not in R.STOP] or title_terms
        body = core.tokenize(q)
        body_kept = [t for t in body if t not in R.STOP] if any(t not in R.STOP for t in body) else body
        print(f"  {q!r}: title {len(title_terms)} -> {len(kept)} | postings {sum(df.get(t, 0) for t in body)} -> "
              f"{sum(df.get(t, 0) for t in body_kept)}")
    print("\nF: per typed word that triggers: pool size, distance computations (unchanged), near words today -> F")
    pool = {c: n for c, n in df.items() if n >= 1}
    for t in title_vocabulary:
        pool.setdefault(t, 1)
    today_f, cand_f = R.ORIGINAL["_fuzzy_groups"], R.make_f(d2_min=8)
    for q in queries:
        for term in sorted(set(core.tokenize(q))):
            k = core._fuzzy_max_distance(term)
            if not k or df.get(term) or term in title_vocabulary or not core._fuzzy_latin(term):
                continue
            computed = sum(1 for c in pool if c[:1] == term[:1] and abs(len(c) - len(term)) <= k)
            a = today_f([term], df, title_vocabulary).get(term, ())
            b = cand_f([term], df, title_vocabulary).get(term, ())
            print(f"  {term} ({len(term)} cp, k {k}): pool {len(pool)}, distance computations {computed}, "
                  f"near words {[m for m, _ in a]} -> {[m for m, _ in b]}")
    vocabulary = set(df) | title_vocabulary
    eligible = [w for w in vocabulary if verb_forms.word_of(w) is not None]
    r_lookups = [len(verb_forms.forms(w)) for w in eligible]
    x_lookups = [len(R.x_forms(w)) for w in eligible]
    bases = sum(len(verb_forms.bases(w)) for w in eligible)
    changed = [w for w in eligible if set(R.x_forms(w)) != set(verb_forms.forms(w))]
    held_dropped = sum(1 for w in eligible for f in verb_forms.forms(w)
                       if f in vocabulary and f not in R.x_forms(w))
    print(f"\nX: R applies to {len(eligible)} dictionary words; lookups per word today min {min(r_lookups)}, "
          f"median {statistics.median(r_lookups)}, max {max(r_lookups)}, total {sum(r_lookups)}; under X min "
          f"{min(x_lookups)}, median {statistics.median(x_lookups)}, max {max(x_lookups)}, total {sum(x_lookups)}; "
          f"shape tests added {bases} (one per base); words whose forms X changes {len(changed)}; held forms X "
          f"drops over the whole dictionary {held_dropped}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""S2-T4 bar (b): every query word that matches no chunk is in `warnings`.

For each of the snapshots `capture_query_outputs.py` leaves in --work (the
1,000- and 10,000-chunk timing corpora, lexical) and the 1,000-chunk vector
snapshot (lexical, hybrid and vector modes), run

* 200 random 1-6 word queries drawn from the corpus vocabulary (every word
  matches, so there must be no `query_term_unmatched` at all), and
* 50 queries with 1-3 planted unknown words (some capitalised, one repeated)
  among real ones,

(the vector snapshot has labelled chunks and the queries carry no labels, so a
word found only in labelled chunks counts as matching nothing), and compare the set of `query_term_unmatched` terms with the words the corpus
really lacks (computed from the corpus files, not from the engine). Exact
equality is required in lexical and hybrid mode (no missing word, no extra
word); in vector mode there must be no `query_term_unmatched` at all (the words
are not used there).

    python3 -I scripts/check_unmatched_warnings.py --lib LIB --work WORKDIR
"""

from __future__ import annotations

import argparse
import json
import random
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from capture_query_outputs import Library  # noqa: E402

PLANTED = ["dinosaurus", "zqxjv", "Quokkaz", "flibbertigibbet", "xyzzy42", "WOMBATQ"]


def vocabulary_of(folder: Path, skip_labelled: bool = False) -> set[str]:
    """Words of the corpus files. `skip_labelled` drops the chunks that
    `capture_query_outputs.py` gives a required label (every 11th file in sorted
    order): a query without that label cannot reach them, so a word found only
    there matches no chunk the request may see."""
    words: set[str] = set()
    files = sorted(p for p in folder.rglob("*") if p.is_file())
    for number, path in enumerate(files):
        if skip_labelled and number % 11 == 0:
            continue
        words.update(re.findall(r"[a-z0-9]+", path.read_text(encoding="utf-8").lower()))
    return words


def build_queries(vocabulary: list[str], rng: random.Random) -> list[str]:
    queries = [" ".join(rng.choice(vocabulary) for _ in range(rng.randint(1, 6))) for _ in range(200)]
    for number in range(50):
        words = [rng.choice(vocabulary) for _ in range(rng.randint(1, 5))]
        for _ in range(rng.randint(1, 3)):
            words.insert(rng.randint(0, len(words)), rng.choice(PLANTED) + (str(number) if rng.random() < 0.5 else ""))
        if number % 10 == 0:
            words.append(words[0])  # a repeated word is reported once
        queries.append(" ".join(words))
    return queries


def unmatched_terms(report: dict) -> list[str]:
    return [w["term"] for w in report["warnings"] if w["code"] == "query_term_unmatched"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--lib", required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=20261009)
    args = parser.parse_args()
    lib = Library(args.lib)
    rng = random.Random(args.seed)

    targets = [
        ("c1k", args.work / "snap-c1k", args.work / "c1k", ["lexical", "hybrid"]),
        ("c10k", args.work / "snap-c10k", args.work / "c10k", ["lexical", "hybrid"]),
        ("c1k-vectors", args.work / "snap-synthetic-vectors", args.work / "c1k", ["lexical", "hybrid", "vector"]),
    ]
    checked = planted_found = failures = 0
    for name, snapshot, folder, modes in targets:
        vocabulary = vocabulary_of(folder, skip_labelled=name == "c1k-vectors")
        handle = lib.open(snapshot)
        for text in build_queries(sorted(vocabulary), rng):
            expected = {word.lower() for word in re.findall(r"[A-Za-z0-9]+", text)} - vocabulary
            for mode in modes:
                vector = [1.0, 0.0, 1.0, 0.0] if name == "c1k-vectors" and mode != "lexical" else []
                report = json.loads(lib.query(handle, text, vector, 5, {"retrieval_mode": mode}))
                got = unmatched_terms(report)
                want = set() if mode == "vector" else expected
                checked += 1
                if mode != "vector":
                    planted_found += len(want)
                if sorted(got) != sorted(want) or len(got) != len(set(got)):
                    failures += 1
                    print(f"FAIL {name} {mode}: {text!r}: warned {sorted(got)}, expected {sorted(want)}")
        lib.lib.ss_close(handle)
    print(f"checked {checked} query runs, {planted_found} unmatched words expected and found, {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())

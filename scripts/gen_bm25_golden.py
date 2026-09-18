#!/usr/bin/env python3
"""Generate the BM25 cross-language conformance golden fixture (S1-T1
acceptance criterion 2: "BM25 results identical between Python and Zig for
both analyzers").

Calls the real `search_platform.core.build_index`/`core.search` (lexical
mode, k1=1.2 b=0.75, the same formula `zig/src/scoring.zig` implements) as
the oracle. Two corpora:

- `fixtures/app-text` (plain ASCII English): queried with mixed-case terms
  to exercise casefolding; every token in ASCII text falls in the same
  Unicode-category set as ASCII alnum, and casefold == lower for ASCII, so
  this corpus is a valid conformance target for *both* `analyzer-v1`
  (Zig's ASCII analyzer) and `analyzer-v2` (Unicode) -- Python's `tokenize()`
  has only ever had the one (Unicode-category) definition.
- `fixtures/tamil/passages` (Tamil): `analyzer-v2` only; `analyzer-v1` is
  ASCII-only by design and is not expected to do anything useful with
  Tamil script (documented, not silently claimed).

Run: `python3 scripts/gen_bm25_golden.py > fixtures/bm25-golden.json`

Determinism (S1-T3, docs/tasks/S1-T3.md, optional-if-cheap item; round-A
verdict, docs/tasks/S1-T1.md non-blocking finding 4): three consecutive runs
used to produce three different files (md5s differed) in the last ULP of a
couple of `lexical_score` values, because the Python reference's BM25
accumulation order depends on dict/set iteration order, which depends on
`PYTHONHASHSEED`. Pinning the seed makes "regenerate and diff" a meaningful
byte-for-byte check instead of one that happens to pass because the Zig
test's 1e-4 tolerance absorbs the drift. `PYTHONHASHSEED` must be set before
the interpreter starts (it cannot be changed from within a running
process), so this script pins it by re-executing itself once with the
environment variable set, rather than requiring every caller to remember
`PYTHONHASHSEED=0 python3 scripts/gen_bm25_golden.py`.
"""
import json
import os
import sys
from pathlib import Path

_PINNED_HASH_SEED = "0"

if os.environ.get("PYTHONHASHSEED") != _PINNED_HASH_SEED:
    os.environ["PYTHONHASHSEED"] = _PINNED_HASH_SEED
    os.execv(sys.executable, [sys.executable] + sys.argv)

sys.path.insert(0, "src")
from search_platform import core  # noqa: E402

APP_TEXT_QUERIES = [
    "Fractions",
    "ANSWER",
    "shapes",
    "Decimals",
    "practice",
    "Persona",
    "learner",
    "Rubric",
]

TAMIL_QUERIES = [
    "மழை",
    "ஆசிரியர்",
    "இட்லி",
    "யானை",
    "பொங்கல்",
    "ரயில்கள்",
    "காய்கறிகள்",
    "உடற்பயிற்சி",
    "வீணை",
    "நூலகம்",
]


def run(root: str, queries: list[str]) -> list[dict]:
    index = core.build_index(Path(root), vector_mode="none")
    out = []
    for query in queries:
        hits = core.search(index, query, top_k=50, retrieval_mode="lexical")
        out.append(
            {
                "query": query,
                "ranking": [
                    {
                        "path": hit["citation"]["path"],
                        "start_line": hit["citation"]["start_line"],
                        "end_line": hit["citation"]["end_line"],
                        "fused_score": hit["score"],
                        "lexical_rank": hit["ranking"]["lexical"]["rank"],
                        "lexical_score": hit["ranking"]["lexical"]["score"],
                    }
                    for hit in hits
                ],
            }
        )
    return out


def main() -> None:
    payload = {
        "bm25": {"k1": 1.2, "b": 0.75},
        "app_text": run("fixtures/app-text", APP_TEXT_QUERIES),
        "tamil": run("fixtures/tamil/passages", TAMIL_QUERIES),
    }
    print(json.dumps(payload, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()

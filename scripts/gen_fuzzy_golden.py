#!/usr/bin/env python3
"""Generate fuzzy-v1's cross-language golden (S5-T3, docs/fuzzy-v1.md).

The Python reference (`search_platform.core.search`, lexical, `content`) answers
every knowledge query of the J2 pack (`fixtures/j2/judgments.json`) plus planted
cases over J2's chunked files, indexed as `relevance_smoke.py --pack j2` indexes
them: one union index of the three roots, the root ids stripped from the title
field (`title_root_ids`). The golden records each chunk's id, path, lines and term
counts, and per query the expansions (`fuzzy_expansions`) and every chunk with a
positive lexical score: that score (body BM25 with the groups, plus the title part
on the chunk that received it) and the title part. `zig/src/fuzzy_test.zig` builds
an index from the same term counts, derives the title field from the same paths and
compares the expansions exactly and the scores to f32 tolerance.

A query whose words the reference's body analyzer and the file-name analyzer
analyse differently is left out and named in `skipped`. Since S5-T4 both fold
simply (the `ß` row), so none is. The reference runs with fold-groups-v1 off
(`fold=""`), as `zig/src/fuzzy_test.zig` runs the engine: the golden is fuzzy-v1's
alone.

The planted cases, each checked here before it is written:
- `tamil`: a Tamil word one swap from a held one. Not Latin, so never expanded
  (plant P4: without the script check the engine would expand it);
- `first-letter`: a Latin word whose first letter alone differs from a held one.
  The first code point is kept, so never expanded (plant P5);
- `short`: a 4-code-point word one edit from a held one. Below 5 code points, so
  never expanded (plant P6);
- `expanded`: misspellings of held words, each expanded.

Run: `python3 scripts/gen_fuzzy_golden.py > fixtures/fuzzy-golden.json`
(PYTHONHASHSEED is pinned by re-executing, as `gen_bm25_golden.py` does).
"""
import json
import os
import shutil
import sys
import tempfile
from collections import Counter
from pathlib import Path

_PINNED_HASH_SEED = "0"

if os.environ.get("PYTHONHASHSEED") != _PINNED_HASH_SEED:
    os.environ["PYTHONHASHSEED"] = _PINNED_HASH_SEED
    os.execv(sys.executable, [sys.executable] + sys.argv)

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
from search_platform import core  # noqa: E402

PACK = ROOT / "fixtures" / "j2"

# (id, kind, query (its first word the typed one), the held word it is near)
PLANTED = [
    ("f-tamil-1", "tamil", "நூகலம் சனிக்கிழமை", "நூலகம்"),
    ("f-tamil-2", "tamil", "திறந்தத வேண்டும்", "திறந்தது"),
    ("f-first-1", "first-letter", "jedgehog", "hedgehog"),
    ("f-first-2", "first-letter", "mavender windfall", "lavender"),
    ("f-short-1", "short", "wrem", "wren"),
    ("f-short-2", "short", "shad lane", "shed"),
    ("f-expanded-1", "expanded", "hedgehgo", "hedgehog"),
    ("f-expanded-2", "expanded", "lavendar greenhose", "lavender"),
    ("f-expanded-3", "expanded", "blackbrid sparrows", "blackbird"),
]


def main() -> None:
    judgments = json.loads((PACK / "judgments.json").read_text(encoding="utf-8"))
    roots = judgments["roots"]
    scratch = Path(os.environ.get("TMPDIR") or tempfile.gettempdir())
    with tempfile.TemporaryDirectory(dir=scratch) as temporary:
        union = Path(temporary) / "union"
        for root in roots:
            shutil.copytree(PACK / root, union / root)
        index = core.build_index(union, filename_index=True)
    chunks = sorted(index["chunks"], key=lambda c: (c["path"].encode("utf-8"), c["start_line"], c["end_line"],
                                                     c["id"].encode("utf-8")))
    document_frequency: Counter[str] = Counter()
    for chunk in chunks:
        document_frequency.update(chunk["terms"].keys())

    def answer(query: str) -> dict:
        hits = core.search(index, query, top_k=len(chunks), candidate_k=len(chunks), retrieval_mode="lexical",
                           title_root_ids=roots, fold="")
        scored = []
        for hit in hits:
            lexical = hit["ranking"]["lexical"]["score"]
            if not lexical or lexical <= 0:
                continue
            title = (hit["ranking"].get("title") or {}).get("score")
            scored.append({"id": hit["chunk_id"], "lexical": lexical, "title": title})
        scored.sort(key=lambda h: h["id"].encode("utf-8"))
        return {"expansions": core.fuzzy_expansions(index, query, title_root_ids=roots), "chunks": scored}

    queries, skipped = [], []
    for q in judgments["queries"]:
        if q["mode"] != "knowledge":
            continue
        if sorted(set(core.tokenize(q["query"]))) != sorted(set(core._filename_tokenize(q["query"]))):
            skipped.append(q["id"])
            continue
        queries.append({"id": q["id"], "kind": "j2", "query": q["query"], **answer(q["query"])})
    for qid, kind, query, near in PLANTED:
        typed = core._filename_tokenize(query)[0]
        if document_frequency[near] < 1 or document_frequency[typed] != 0:
            raise SystemExit(f"gen_fuzzy_golden: {qid}: {near!r} must be held and {typed!r} not")
        if core._osa_within(typed, near, 2) is None:
            raise SystemExit(f"gen_fuzzy_golden: {qid}: {typed!r} is not near {near!r}")
        row = {"id": qid, "kind": kind, "query": query, **answer(query)}
        if (typed in row["expansions"]) != (kind == "expanded"):
            raise SystemExit(f"gen_fuzzy_golden: {qid}: expansions {row['expansions']} for a {kind} case")
        if kind == "expanded" and near not in row["expansions"][typed]:
            raise SystemExit(f"gen_fuzzy_golden: {qid}: {near!r} not among {row['expansions'][typed]}")
        queries.append(row)
    json.dump({
        "policy_id": core.FUZZY_POLICY_ID,
        "title_policy_id": core.TITLE_POLICY_ID,
        "roots": roots,
        "chunks": [{"id": c["id"], "path": c["path"], "start_line": c["start_line"], "end_line": c["end_line"],
                    "terms": {t: c["terms"][t] for t in sorted(c["terms"], key=lambda t: t.encode("utf-8"))}}
                   for c in chunks],
        "skipped": skipped,
        "queries": queries,
    }, sys.stdout, ensure_ascii=False, indent=1)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()

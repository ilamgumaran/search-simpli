#!/usr/bin/env python3
"""Generate the title field's cross-language golden (S5-T2 ruling 10).

The Python reference (`search_platform.core._title_scores`, `title-field-v1`) scores
every knowledge query of the J2 pack (`fixtures/j2/judgments.json`) against the
title field of J2's chunked files, as `relevance_smoke.py --pack j2` indexes them: one
union index of the three roots, the root ids stripped (`title_root_ids`). The golden
records the record paths, the roots and, per query, every file with a positive title
part and its weighted score (w 2.5, unscoped statistics), sorted by path.
`zig/src/title_field_test.zig` derives the field from the same paths and compares the
files and the scores to f32 tolerance.

Run: `python3 scripts/gen_title_golden.py > fixtures/title-field-golden.json`
(PYTHONHASHSEED is pinned by re-executing, as `gen_bm25_golden.py` does).
"""
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

_PINNED_HASH_SEED = "0"

if os.environ.get("PYTHONHASHSEED") != _PINNED_HASH_SEED:
    os.environ["PYTHONHASHSEED"] = _PINNED_HASH_SEED
    os.execv(sys.executable, [sys.executable] + sys.argv)

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
from search_platform import core  # noqa: E402

PACK = ROOT / "fixtures" / "j2"


def main() -> None:
    judgments = json.loads((PACK / "judgments.json").read_text(encoding="utf-8"))
    roots = judgments["roots"]
    with tempfile.TemporaryDirectory() as scratch:
        union = Path(scratch) / "union"
        for root in roots:
            shutil.copytree(PACK / root, union / root)
        index = core.build_index(union, filename_index=True)
    chunks = index["chunks"]
    paths = sorted({chunk["path"] for chunk in chunks}, key=lambda p: p.encode("utf-8"))
    queries = []
    for q in judgments["queries"]:
        if q["mode"] != "knowledge":
            continue
        scores = core._title_scores(chunks, q["query"], tuple(roots), core.TITLE_WEIGHT)
        queries.append({
            "id": q["id"],
            "query": q["query"],
            "files": [{"path": path, "score": scores[path]}
                      for path in sorted(scores, key=lambda p: p.encode("utf-8")) if scores[path] > 0],
        })
    json.dump({
        "policy_id": core.TITLE_POLICY_ID,
        "weight": core.TITLE_WEIGHT,
        "roots": roots,
        "paths": paths,
        "queries": queries,
    }, sys.stdout, indent=1, ensure_ascii=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()

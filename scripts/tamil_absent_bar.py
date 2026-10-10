#!/usr/bin/env python3
"""S1-T14 bar: hits per absent Tamil query, and success@1 of the existing
Tamil judged set, both through `searchd` on a snapshot built by `searchd index`.

    python3 scripts/tamil_absent_bar.py <searchd> <scratch-dir>

Exit status 0 only when every absent query has 0 hits and success@1 is 1.00.
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def query(searchd: str, snap: Path, text: str) -> list[dict]:
    out = subprocess.run(
        [searchd, "query", str(snap), text, "--json", "--top-k", "50"],
        check=True, capture_output=True, text=True,
    ).stdout
    return json.loads(out)["results"]


def main() -> int:
    searchd, scratch = sys.argv[1], Path(sys.argv[2])
    scratch.mkdir(parents=True, exist_ok=True)
    snap = scratch / "tamil-snap"
    subprocess.run([searchd, "index", str(ROOT / "fixtures/tamil/passages"), "--out", str(snap)],
                   check=True, capture_output=True)
    ok = True
    absent = json.loads((ROOT / "fixtures/tamil-absent-judgments.json").read_text("utf-8"))["queries"]
    total = 0
    with_hits = 0
    for q in absent:
        n = len(query(searchd, snap, q["query"]))
        total += n
        with_hits += n > 0
        ok &= n == 0
        print(f"absent {q['id']:<20} hits={n}")
    judged = json.loads((ROOT / "fixtures/tamil/judgments.json").read_text("utf-8"))["queries"]
    top1 = 0
    for q in judged:
        res = query(searchd, snap, q["query"])
        want = {r["path"].split("/")[-1] for r in q["relevant"]}
        top1 += bool(res) and res[0]["path"] in want
    rate = top1 / len(judged)
    ok &= rate == 1.0
    print(f"absent queries: {len(absent)}, queries with hits: {with_hits}, total hits: {total}")
    print(f"existing Tamil set success@1: {top1}/{len(judged)} = {rate:.2f}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

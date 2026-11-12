#!/usr/bin/env python3
"""J2 through the release `searchd` in CI (S5-T6 rulings 3-5, review R02).

  ci_j2_native.py run --searchd PATH --expect-queries N --output RUN.json
  ci_j2_native.py differences RUN.json [--baseline fixtures/j2/baseline.json]
  ci_j2_native.py plant RUN.json --output PLANTED.json

run: J2 through the given binary (`scripts/j2_run.py`'s runner: one index, one
`searchd serve`, every knowledge row under `content` and `both`, every find row),
then checks that the run is whole and native: the surface is `searchd`, the
binary's SHA-256 is the given file's, the pack holds N queries and both variants
hold a record for every one of them (no skip, no fallback to the Python
reference: nothing here imports it). It prints, and annotates as a notice, the
binary, its source commit and the policy ids. The gate is `scripts/j2_gate.py`.

differences: every cell where the run differs from the committed `searchd`
baseline (recorded on macOS arm64): each query whose first grade-2 rank moved,
with its top 10 and their scores and ties, each slice metric that moved and each
negative that moved. Information for ruling 4: a warning per row, never a
failure (the gate decides). Exit 0, or 2 on a usage error.

plant: the deliberately worse candidate of ruling 5. Every graded query's first
grade-2 hit is removed from its list and the records are scored again with the
code both surfaces score with (relevance_smoke.py's j2_record and j2_summarise).
Before planting, the unchanged lists are scored again and must reproduce the
run exactly, so the planted run differs from the real one by the plant alone.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# The repository root first: scripts/relevance_smoke.py is a wrapper of the root module.
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(ROOT))

from ci_annotations import Annotations  # noqa: E402
from relevance_smoke import J2_VARIANTS, PACKS, j2_record, j2_summarise  # noqa: E402

PACK = PACKS["j2"]
BASELINE = ROOT / "fixtures" / "j2" / "baseline.json"
METRICS = ("success_at_1", "mrr_at_10", "ndcg_at_10", "recall_at_5")


class Usage(Exception):
    pass


def judgments() -> dict:
    return json.loads((PACK / "judgments.json").read_text(encoding="utf-8"))


def load(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise Usage(f"cannot read {path}: {exc}") from exc


def whole_and_native(results: dict, binary: Path, expect: int, judged: dict) -> list[str]:
    """Problems that make a run not a full native run; empty when it is one."""
    problems = []
    ids = [q["id"] for q in judged["queries"]]
    if len(ids) != expect:
        problems.append(f"the pack holds {len(ids)} queries, the job expects {expect} (update --expect-queries "
                        "with the reviewed judgment change)")
    if results.get("surface") != "searchd":
        problems.append(f"the run's surface is {results.get('surface')!r}, not 'searchd'")
    sha = hashlib.sha256(binary.read_bytes()).hexdigest()
    have = results.get("engine", {}).get("binary", {}).get("sha256")
    if have != sha:
        problems.append(f"the run names binary {have}, the job built {sha}")
    for variant in J2_VARIANTS:
        queries = results.get("runs", {}).get(variant, {}).get("queries")
        if queries is None:
            problems.append(f"variant {variant} did not run")
            continue
        missing = [q for q in ids if q not in queries]
        extra = [q for q in queries if q not in ids]
        if missing or extra:
            problems.append(f"{variant}: {len(missing)} queries without a record ({', '.join(missing[:10])}), "
                            f"{len(extra)} not in the pack")
        graded = [q["id"] for q in judged["queries"] if not q.get("negative")]
        unscored = [q for q in graded if q in queries and "first_grade2_rank" not in queries[q]]
        if unscored:
            problems.append(f"{variant}: {len(unscored)} graded queries carry no first grade-2 rank "
                            f"({', '.join(unscored[:10])})")
    return problems


def identify(results: dict) -> str:
    engine = results["engine"]
    binary = engine["binary"]
    policies = engine.get("policies") or {}
    named = ", ".join(f"{k} {v}" for k, v in policies.items())
    return (f"searchd sha256 {binary['sha256']} ({binary['size']} B, {binary['optimize']}, zig {binary.get('zig')}) "
            f"built from commit {engine.get('commit')}; natives digest {engine.get('natives_digest')} "
            f"(matches the committed SOURCE-SHA256: {engine.get('natives_digest_matches_committed')}); "
            f"policies: {named}")


def cmd_run(args, notes: Annotations) -> int:
    import j2_run  # noqa: E402 (runs searchd; imported here so `plant` needs no binary)
    binary = args.searchd.resolve()
    if not binary.is_file():
        raise Usage(f"no searchd at {binary}")
    scratch = args.output.resolve().parent / "j2-run-scratch"
    scratch.mkdir(parents=True, exist_ok=True)
    results = j2_run.run_searchd(binary, scratch, "ReleaseSmall")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    judged = judgments()
    problems = whole_and_native(results, binary, args.expect_queries, judged)
    for problem in problems:
        print(f"FAIL {problem}")
        notes.add("error", "J2 native run incomplete", problem)
    if problems:
        return 1
    who = identify(results)
    count = len(judged["queries"])
    print(f"J2 native: {who}")
    print(f"J2 native: {count} queries, each with a record under {' and '.join(J2_VARIANTS)}; none skipped")
    for variant, run in results["runs"].items():
        print(f"  {variant}: " + ", ".join(f"{n} MRR@10 {m['mrr_at_10']:.3f}" for n, m in run["slices"].items()))
    notes.add("notice", "J2 native run", f"{count} queries x {len(J2_VARIANTS)} variants, none skipped. {who}")
    return 0


def hit_text(hit: dict) -> str:
    return f"{hit['rank']} {hit['root_id']}/{hit['path']}:{hit['start_line']}-{hit['end_line']} g{hit['grade']} {hit['score']:.9g}"


def differences(results: dict, baseline: dict) -> list[tuple[str, str]]:
    """(title, message) per differing row against the baseline's searchd cells."""
    if results.get("judgments_sha256") != baseline.get("judgments_sha256"):
        raise Usage("the run and the baseline judge different judgments.json files")
    base_runs = baseline["surfaces"]["searchd"]["runs"]
    rows = []
    for variant in J2_VARIANTS:
        run, base = results["runs"][variant], base_runs[variant]
        for qid, before in base["first_grade2_rank"].items():
            record = run["queries"][qid]
            now = record.get("first_grade2_rank")
            if now == before:
                continue
            top = "; ".join(hit_text(h) for h in record["hits"])
            rows.append((f"J2 x86_64 vs baseline: {variant} {qid}",
                         f"{qid} ({record['slice']}, {record['query']!r}) first grade-2 rank {before} -> {now}; "
                         f"ties {record['ties']}; top {len(record['hits'])}: {top}"))
        for name, b in base["slices"].items():
            r = run["slices"][name]
            moved = [f"{m} {b[m]:.6f} -> {r[m]:.6f}" for m in METRICS if abs(b[m] - r[m]) > 1e-9]
            if moved:
                rows.append((f"J2 x86_64 vs baseline: {variant} slice {name}", "; ".join(moved)))
        for qid, b in base["negatives"].items():
            r = run["negatives"][qid]
            if (b["returned"], b["top_hit"]) != (r["returned"], r["top_hit"]):
                rows.append((f"J2 x86_64 vs baseline: {variant} negative {qid}",
                             f"{b['returned']} hits, top {b['top_hit']} -> {r['returned']} hits, top {r['top_hit']}"))
    return rows


def cmd_differences(args, notes: Annotations) -> int:
    results, baseline = load(args.run), load(args.baseline)
    rows = differences(results, baseline)
    cells = sum(len(baseline["surfaces"]["searchd"]["runs"][v]["first_grade2_rank"]) for v in J2_VARIANTS)
    print(f"J2 native against the baseline's searchd cells (recorded {baseline['recorded']}, "
          f"binary {baseline['surfaces']['searchd']['binary']['sha256'][:12]}): {len(rows)} rows differ")
    for title, message in rows:
        print(f"  {title}: {message}")
        notes.add("warning", title, message)
    if not rows:
        notes.add("notice", "J2 x86_64 vs baseline", f"no row differs: every first grade-2 rank ({cells} over "
                  f"both variants), slice metric and negative equals the macOS arm64 baseline")
    return 0


def rescore(results: dict, judged: dict, drop_answer: bool) -> dict:
    by_id = {q["id"]: q for q in judged["queries"]}
    runs = {}
    for variant in J2_VARIANTS:
        records = {}
        for qid, record in results["runs"][variant]["queries"].items():
            hits = [dict(h) for h in record["hits"]]
            if drop_answer and not by_id[qid].get("negative"):
                first = next((i for i, h in enumerate(hits) if h["grade"] == 2), None)
                if first is not None:
                    del hits[first]
            records[qid] = j2_record(by_id[qid], hits)
        runs[variant] = j2_summarise(judged, records)
    return runs


def plant(results: dict, judged: dict | None = None) -> dict:
    judged = judged or judgments()
    same = rescore(results, judged, drop_answer=False)
    if json.loads(json.dumps(same)) != json.loads(json.dumps(results["runs"])):
        raise Usage("scoring the unchanged lists again does not reproduce the run; the plant would not be "
                    "the only difference")
    planted = dict(results)
    planted["runs"] = rescore(results, judged, drop_answer=True)
    planted["plant"] = "S5-T6 ruling 5: every graded query's first grade-2 hit removed, records scored again"
    return planted


def cmd_plant(args, notes: Annotations) -> int:
    planted = plant(load(args.run))
    args.output.write_text(json.dumps(planted, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"planted run written: {args.output}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run")
    run.add_argument("--searchd", type=Path, required=True)
    run.add_argument("--expect-queries", type=int, required=True)
    run.add_argument("--output", type=Path, required=True)
    diff = sub.add_parser("differences")
    diff.add_argument("run", type=Path)
    diff.add_argument("--baseline", type=Path, default=BASELINE)
    planted = sub.add_parser("plant")
    planted.add_argument("run", type=Path)
    planted.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    notes = Annotations()
    try:
        return {"run": cmd_run, "differences": cmd_differences, "plant": cmd_plant}[args.command](args, notes)
    except Usage as exc:
        print(f"ci_j2_native: {exc}", file=sys.stderr)
        notes.add("error", f"J2 native {args.command}", str(exc))
        return 2
    finally:
        sys.stdout.flush()
        notes.flush()


if __name__ == "__main__":
    raise SystemExit(main())

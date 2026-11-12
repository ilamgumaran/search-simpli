#!/usr/bin/env python3
"""The J2 regression gate (S5-T1): compare a run with the committed baseline.

  j2_gate.py RUN.json [--baseline fixtures/j2/baseline.json] [--allow ALLOW.json] [--annotate]

RUN.json is a results file from `relevance_smoke.py --pack j2` (the Python
reference) or `scripts/j2_run.py` (searchd). It is compared with the same
surface in the baseline, variant by variant (search_field content and both).
The run fails (exit 1) when, in either variant:

  (a) a slice's MRR@10 is lower than the baseline's by more than 0.02;
  (b) a control query whose first grade-2 hit was at rank 1 in the baseline is
      not at rank 1 now (the allow-list never excuses this);
  (c) a query's first grade-2 rank worsens by more than 3 places and the
      allow-list does not name it. Not in the top 10 counts as 11; a query the
      baseline did not find cannot worsen.

The negatives are information rows: their changes are printed, never gated.
Exit 2 is a usage error: a file that cannot be read, a schema it does not
know, a run and baseline that judge different judgments.json files, or a
surface or variant the baseline lacks. Otherwise each slice's deltas on all
four metrics are printed and the exit is 0.

The allow-list is a file the task that moves a judgment commits beside it:
{"task": "S5-Tn", "queries": [{"id": "m04", "why": "..."}]}. An absent file is
an empty list. fixtures/j2/allow.json is read when it exists and --allow is
not given.

--annotate (S5-T6, CI) also prints each failure, and a usage error, as a GitHub
workflow annotation (`::error title=...::`, scripts/ci_annotations.py), so a
reader of the check-runs API sees which rows failed without the job log.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.append(str(Path(__file__).resolve().parent))

from ci_annotations import Annotations  # noqa: E402

BASELINE = ROOT / "fixtures" / "j2" / "baseline.json"
ALLOW = ROOT / "fixtures" / "j2" / "allow.json"
MRR_DROP = 0.02
RANK_WORSENING = 3
NOT_FOUND = 11
EPSILON = 1e-9
METRICS = ("success_at_1", "mrr_at_10", "ndcg_at_10", "recall_at_5")


class Usage(Exception):
    pass


def load(path: Path, what: str) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise Usage(f"cannot read the {what} {path}: {exc}") from exc


def allowed_ids(path: Path | None) -> dict[str, str]:
    if path is None:
        path = ALLOW if ALLOW.is_file() else None
    if path is None:
        return {}
    allow = load(path, "allow-list")
    if not isinstance(allow.get("queries"), list):
        raise Usage(f"the allow-list {path} has no queries list")
    out = {}
    for item in allow["queries"]:
        if not isinstance(item, dict) or not item.get("id") or not item.get("why"):
            raise Usage(f"every allow-list entry needs an id and a why: {item!r}")
        out[item["id"]] = item["why"]
    return out


def run_ranks(run: dict) -> dict[str, int | None]:
    return {qid: r["first_grade2_rank"] for qid, r in run["queries"].items() if "first_grade2_rank" in r}


def judge(run: dict, base: dict, allow: dict[str, str]) -> tuple[list[str], list[str]]:
    """Failures and report lines for one variant."""
    failures: list[str] = []
    lines: list[str] = []
    lines.append(f"    {'slice':<12} {'n':>3}  " + "  ".join(f"{m:>22}" for m in METRICS))
    for name, b in base["slices"].items():
        if name not in run["slices"]:
            raise Usage(f"the run has no slice {name}")
        r = run["slices"][name]
        cells = []
        for metric in METRICS:
            cells.append(f"{b[metric]:6.3f} -> {r[metric]:6.3f} ({r[metric] - b[metric]:+.3f})")
        lines.append(f"    {name:<12} {r['n']:>3}  " + "  ".join(f"{c:>22}" for c in cells))
        if b["mrr_at_10"] - r["mrr_at_10"] > MRR_DROP + EPSILON:
            failures.append(f"(a) slice {name}: MRR@10 {b['mrr_at_10']:.3f} -> {r['mrr_at_10']:.3f}, "
                            f"a drop of {b['mrr_at_10'] - r['mrr_at_10']:.3f} (limit {MRR_DROP})")
    ranks = run_ranks(run)
    slice_of = base["slice_of"]
    for qid, before in base["first_grade2_rank"].items():
        if qid not in ranks:
            raise Usage(f"the run has no query {qid}")
        now = ranks[qid]
        if slice_of[qid] == "control" and before == 1 and now != 1:
            failures.append(f"(b) control {qid} lost rank 1 (now {now if now else 'not in the top 10'})"
                            + ("; the allow-list does not excuse a control loss" if qid in allow else ""))
            continue
        if before is None:
            continue
        worse = (now if now is not None else NOT_FOUND) - before
        if worse > RANK_WORSENING:
            if qid in allow:
                lines.append(f"    allowed: {qid} first grade-2 rank {before} -> {now} ({allow[qid]})")
            else:
                failures.append(f"(c) {qid} ({slice_of[qid]}): first grade-2 rank {before} -> "
                                f"{now if now else 'not in the top 10'}, worse by {worse} (limit {RANK_WORSENING})")
    for qid, b in base["negatives"].items():
        r = run["negatives"].get(qid)
        if r is None:
            raise Usage(f"the run has no negative {qid}")
        if (b["returned"], b["top_hit"], b["top_is_named_distractor"]) != (r["returned"], r["top_hit"], r["top_is_named_distractor"]):
            lines.append(f"    negative {qid} (information): {b['returned']} hits, top {b['top_hit']} -> "
                         f"{r['returned']} hits, top {r['top_hit']}, named distractor {r['top_is_named_distractor']}")
    return failures, lines


def gate(run_path: Path, baseline_path: Path, allow_path: Path | None, notes: Annotations | None = None) -> int:
    run = load(run_path, "run")
    baseline = load(baseline_path, "baseline")
    if run.get("schema") != "j2-results-v1" or baseline.get("schema") != "j2-baseline-v1":
        raise Usage(f"unknown schema: run {run.get('schema')}, baseline {baseline.get('schema')}")
    if run["judgments_sha256"] != baseline["judgments_sha256"]:
        raise Usage("the run and the baseline judge different judgments.json files "
                    f"({run['judgments_sha256'][:12]} against {baseline['judgments_sha256'][:12]})")
    surface = run.get("surface")
    if surface not in baseline["surfaces"]:
        raise Usage(f"the baseline has no surface {surface!r}")
    allow = allowed_ids(allow_path)
    base_runs = baseline["surfaces"][surface]["runs"]
    print(f"J2 gate: {surface} run {run_path.name} against the baseline of {baseline['recorded']} "
          f"(engine {str(baseline['engine_commit'])[:9]}){'; allow-list ' + ', '.join(sorted(allow)) if allow else ''}")
    failures: list[str] = []
    for variant, base in base_runs.items():
        if variant not in run["runs"]:
            raise Usage(f"the run has no variant {variant!r}")
        found, lines = judge(run["runs"][variant], base, allow)
        print(f"  search_field {variant}: {'pass' if not found else 'FAIL'}")
        print("\n".join(lines))
        failures += [f"{variant}: {f}" for f in found]
    for failure in failures:
        print(f"FAIL {failure}")
        if notes is not None:
            variant, _, rule = failure.partition(": ")
            notes.add("error", f"J2 gate {surface} {variant}", rule)
    print(f"J2 gate: {'FAIL' if failures else 'pass'}")
    return 1 if failures else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("run", type=Path)
    parser.add_argument("--baseline", type=Path, default=BASELINE)
    parser.add_argument("--allow", type=Path)
    parser.add_argument("--annotate", action="store_true", help="also print failures as workflow annotations")
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        return 2 if exc.code else 0
    notes = Annotations() if args.annotate else None
    try:
        return gate(args.run, args.baseline, args.allow, notes)
    except Usage as exc:
        print(f"j2_gate: {exc}", file=sys.stderr)
        if notes is not None:
            notes.add("error", "J2 gate usage error", str(exc))
        return 2
    finally:
        if notes is not None:
            sys.stdout.flush()
            notes.flush()


if __name__ == "__main__":
    raise SystemExit(main())

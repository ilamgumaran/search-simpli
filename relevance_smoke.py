#!/usr/bin/env python3
"""Build a local index, evaluate graded relevance, and enforce smoke gates."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import tempfile
import time
from pathlib import Path

from src.search_platform.core import (
    build_index,
    load_index,
    outline,
    read_span,
    save_index,
    search,
)
from src.search_platform.evaluation import RETRIEVAL_MODES, evaluate_modes, load_suite
from src.search_platform.providers import (
    DEFAULT_FASTEMBED_MODEL,
    FastEmbedProvider,
    ProviderError,
    provider_from_index,
)


PROFILE_VERSION = 1
METRICS = {
    "ndcg": "mean_ndcg_at_k",
    "mrr": "mean_reciprocal_rank",
    "recall": "macro_recall_at_k",
    "success": "success_at_k",
}


def profile_id(index: dict, suite_path: Path, modes: list[str], top_k: int) -> str:
    identity = {
        "profile_version": PROFILE_VERSION,
        "suite_sha256": hashlib.sha256(suite_path.read_bytes()).hexdigest(),
        "sources": index["source_files"],
        "vector_mode": index.get("vector_mode", "none"),
        "embedding": index.get("embedding"),
        "modes": modes,
        "top_k": top_k,
    }
    encoded = json.dumps(identity, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def gate_failures(
    report: dict,
    minima: dict[str, float],
    *,
    baseline: dict | None = None,
    max_regression: float = 0.0,
) -> list[str]:
    failures = []
    reports = {item["mode"]: item for item in report["evaluation"]["reports"]}
    for mode, current in reports.items():
        for name, minimum in minima.items():
            key = METRICS[name]
            if current[key] < minimum:
                failures.append(
                    f"{mode} {key}={current[key]:.6f} is below minimum {minimum:.6f}"
                )
    if baseline is not None:
        if baseline.get("profile_id") != report.get("profile_id"):
            raise ValueError("baseline profile_id does not match corpus, suite, modes, and top_k")
        baseline_reports = {
            item["mode"]: item for item in baseline["evaluation"]["reports"]
        }
        for mode, current in reports.items():
            if mode not in baseline_reports:
                raise ValueError(f"baseline has no report for mode {mode!r}")
            for key in METRICS.values():
                allowed = baseline_reports[mode][key] - max_regression
                if current[key] < allowed:
                    failures.append(
                        f"{mode} {key}={current[key]:.6f} regressed below "
                        f"baseline {baseline_reports[mode][key]:.6f} minus {max_regression:.6f}"
                    )
    return failures


def run_smoke(
    corpus: Path,
    suite_path: Path,
    *,
    modes: list[str],
    vector_mode: str,
    top_k: int,
    minima: dict[str, float],
    baseline: dict | None = None,
    max_regression: float = 0.0,
    model: str = DEFAULT_FASTEMBED_MODEL,
    model_cache: Path = Path(".search/models"),
    index_path: Path | None = None,
    save_index_path: Path | None = None,
) -> dict:
    if index_path is not None:
        build_started = time.perf_counter()
        index = load_index(index_path)
        build_ms = (time.perf_counter() - build_started) * 1_000.0
        if index.get("root") != str(corpus.expanduser().resolve()):
            raise ValueError("prebuilt index root does not match the smoke corpus")
        vector_mode = index.get("vector_mode", "none")
        provider = (
            provider_from_index(index, cache_dir=model_cache)
            if vector_mode == "neural" and any(mode in {"vector", "hybrid"} for mode in modes)
            else None
        )
        index_source = "prebuilt"
    else:
        provider = (
            FastEmbedProvider(model_name=model, cache_dir=model_cache)
            if vector_mode == "neural"
            else None
        )
        build_started = time.perf_counter()
        index = build_index(corpus, vector_mode=vector_mode, embedding_provider=provider)
        build_ms = (time.perf_counter() - build_started) * 1_000.0
        if save_index_path is not None:
            save_index(index, save_index_path)
        index_source = "built"
    suite = load_suite(suite_path)
    evaluation_started = time.perf_counter()
    evaluation = evaluate_modes(
        index, suite, modes, top_k=top_k, embedding_provider=provider
    )
    evaluation_ms = (time.perf_counter() - evaluation_started) * 1_000.0
    report = {
        "profile_version": PROFILE_VERSION,
        "profile_id": profile_id(index, suite_path, modes, top_k),
        "corpus": str(corpus.resolve()),
        "suite": str(suite_path.resolve()),
        "vector_mode": vector_mode,
        "index_source": index_source,
        "index_path": (
            str((index_path or save_index_path).resolve())
            if (index_path or save_index_path)
            else None
        ),
        "timing_ms": {"build": build_ms, "evaluation": evaluation_ms},
        "evaluation": evaluation,
    }
    failures = gate_failures(
        report,
        minima,
        baseline=baseline,
        max_regression=max_regression,
    )
    report["gate"] = {
        "minima": minima,
        "baseline_profile_id": baseline.get("profile_id") if baseline else None,
        "max_absolute_regression": max_regression if baseline else None,
        "passed": not failures,
        "failures": failures,
    }
    return report


PACKS = {"family-folder": Path(__file__).resolve().parent / "fixtures" / "family-folder"}
PACK_WORDS_GATE = 0.9
# Case kinds the Python reference cannot answer yet: skipped with a count, never silently.
NOT_YET = {
    "phrase": "phrase search: S3-T2",
    "prefix": "prefix search: S3-T2",
}
# Case kinds the Python reference answers since S3-T1 (outline from md-section-v1,
# read_span from the original bytes); judged for exactness, not recall.
EXACT_KINDS = ("outline", "read_span")


def _overlaps(hit: dict, expected: dict) -> bool:
    return (
        hit["path"] == f"{expected['root_id']}/{expected['path']}"
        and hit["start_line"] <= expected["end_line"]
        and expected["start_line"] <= hit["end_line"]
    )


def run_pack(name: str, *, top_k: int = 5) -> dict:
    """Run a frozen judgment pack through the Python reference (lexical, one union index).

    Roots are copied side by side so a hit path reads `root/path`, the shape of a
    root_id plus a path. Cases the reference cannot answer yet are counted as skipped.
    """
    pack_dir = PACKS[name]
    judgments = json.loads((pack_dir / "judgments.json").read_text(encoding="utf-8"))
    cases: list[dict] = []
    skipped: dict[str, int] = {}

    def skip(kind: str, count: int = 1) -> None:
        skipped[kind] = skipped.get(kind, 0) + count

    with tempfile.TemporaryDirectory() as scratch:
        union = Path(scratch) / "union"
        for root in judgments["roots"]:
            shutil.copytree(pack_dir / root, union / root)
        index = build_index(union)

        def retrieve(case_id: str, query: str, expected: list[dict]) -> None:
            hits = [
                {"path": r["citation"]["path"], "start_line": r["citation"]["start_line"],
                 "end_line": r["citation"]["end_line"]}
                for r in search(index, query, top_k=top_k, retrieval_mode="lexical")
            ]
            covered = sum(1 for e in expected if any(_overlaps(h, e) for h in hits))
            cases.append({"id": case_id, "query": query, "expected": len(expected),
                          "covered": covered, "recall": covered / len(expected)})

        def run_outline(case: dict) -> bool:
            got = outline(index, f"{case['root_id']}/{case['path']}")
            want = {key: case[key] for key in ("front_matter", "headings", "lines", "chunker")}
            return got == want

        def run_read_span(case: dict) -> bool:
            got = read_span(index, f"{case['root_id']}/{case['path']}", case["start_line"],
                            case["end_line"], case["context_lines"])
            return (got["sha256"] == case["sha256"]
                    and len(got["text"].encode("utf-8")) == case["byte_length"])

        exact: dict[str, list[dict]] = {kind: [] for kind in EXACT_KINDS}
        for case in judgments["outline"]:
            exact["outline"].append({"id": case["id"], "exact": run_outline(case)})
        for case in judgments["read_span"]:
            exact["read_span"].append({"id": case["id"], "exact": run_read_span(case)})
        by_case = {f"{kind}:{c['id']}": c for kind in EXACT_KINDS for c in judgments[kind]}

        def run_summary(sc: dict) -> bool:
            full = f"{sc['root_id']}/{sc['path']}"
            if not run_outline(by_case[sc["outline_ref"]]):
                return False
            chunks = [c for c in index["chunks"] if c["path"] == full]
            for want in sc["expected_sections"]:
                mine = sorted((c for c in chunks if c["section_path"] == want["section_path"]
                               and c["heading_line"] == want["heading_line"]),
                              key=lambda c: c["start_line"])
                span = want["first_span"]
                if not mine or not (mine[0]["start_line"] <= span["end_line"]
                                    and span["start_line"] <= mine[0]["end_line"]):
                    return False
            return True

        newt = None
        by_ref = {c["id"]: c for kind in ("phrase", "prefix") for c in judgments[kind]}
        for sc in judgments["scenarios"]:
            kind = sc["kind"]
            if kind in ("words", "answer"):
                retrieve(sc["id"], sc["query"], sc["expected"])
            elif kind == "empty":
                newt = not search(index, sc["query"], top_k=top_k, retrieval_mode="lexical")
            elif kind == "phrase_neighbour":
                expected = list(by_ref[sc["ref"].split(":")[1]]["expected"]) + [sc["expected_neighbour"]]
                retrieve(sc["id"], sc["words_query"], expected)
                skip("scenario phrase/neighbour step")
            elif kind == "outline":
                exact["outline"].append({"id": sc["id"], "exact": run_outline(by_case[sc["ref"]])})
            elif kind == "read_span":
                exact["read_span"].append({"id": sc["id"], "exact": run_read_span(by_case[sc["ref"]])})
            elif kind == "summary":
                exact["outline"].append({"id": sc["id"], "exact": run_summary(sc)})
            elif kind == "lifecycle":
                skip("scenario lifecycle (S3-T3/T4)")
            else:
                skip(f"scenario {kind}")
    for kind in NOT_YET:
        skip(kind, len(judgments[kind]))
    recalls = [c["recall"] for c in cases]
    words_recall = sum(recalls) / len(recalls) if recalls else 0.0
    exactness = {kind: (sum(1 for c in items if c["exact"]) / len(items) if items else 0.0)
                 for kind, items in exact.items()}
    passed = (words_recall >= PACK_WORDS_GATE and newt is True
              and all(value == 1.0 for value in exactness.values()))
    return {
        "pack": name,
        "version": judgments["version"],
        "counts": {"scenarios": len(judgments["scenarios"]),
                   **{k: len(judgments[k]) for k in (*NOT_YET, *EXACT_KINDS)}},
        "words_recall_at_k": words_recall,
        "top_k": top_k,
        "words_cases": cases,
        "newt_empty": newt,
        "exact_cases": exact,
        "exactness": exactness,
        "skipped": skipped,
        "gate": {"words_recall_at_k_min": PACK_WORDS_GATE, "exactness_min": 1.0, "passed": passed},
    }


def print_pack_report(report: dict) -> None:
    counts = report["counts"]
    print(f"pack {report['pack']} (judgments version {report['version']}): "
          f"{counts['scenarios']} scenarios, {counts['phrase']} phrase, {counts['prefix']} prefix, "
          f"{counts['outline']} outline, {counts['read_span']} read_span")
    print(f"words recall@{report['top_k']}: {report['words_recall_at_k']:.3f} "
          f"over {len(report['words_cases'])} cases (gate >= {report['gate']['words_recall_at_k_min']})")
    for case in report["words_cases"]:
        print(f"  {case['id']} {case['covered']}/{case['expected']} expected spans in top "
              f"{report['top_k']}: {case['query']!r}")
    print(f"empty result for the newt question: {'pass' if report['newt_empty'] else 'FAIL'}")
    for kind, items in report["exact_cases"].items():
        exact = sum(1 for c in items if c["exact"])
        misses = [c["id"] for c in items if not c["exact"]]
        print(f"{kind} exactness: {exact}/{len(items)} (gate 1.00)" + (f" misses {misses}" if misses else ""))
    total = sum(report["skipped"].values())
    print(f"not yet implemented: {total} skipped")
    for kind, count in sorted(report["skipped"].items()):
        print(f"  {kind}: {count}")
    print(f"gate: {'pass' if report['gate']['passed'] else 'FAIL'}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run a dependency-free, graded relevance smoke test over a file corpus."
    )
    parser.add_argument("corpus", type=Path, nargs="?")
    parser.add_argument("suite", type=Path, nargs="?")
    parser.add_argument("--pack", choices=sorted(PACKS), help="run a frozen judgment pack instead of corpus + suite")
    parser.add_argument("--mode", action="append", choices=RETRIEVAL_MODES, dest="modes")
    parser.add_argument(
        "--vector-mode", choices=("none", "hash", "cooccurrence", "neural"), default="none"
    )
    parser.add_argument("--model", default=DEFAULT_FASTEMBED_MODEL)
    parser.add_argument("--model-cache", type=Path, default=Path(".search/models"))
    parser.add_argument("--index", type=Path, help="reuse a prebuilt Search Simpli index")
    parser.add_argument("--save-index", type=Path, help="persist the newly built index for later runs")
    parser.add_argument("--top-k", type=int, default=10)
    parser.add_argument("--min-ndcg", type=float)
    parser.add_argument("--min-mrr", type=float)
    parser.add_argument("--min-recall", type=float)
    parser.add_argument("--min-success", type=float)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--max-regression", type=float, default=0.0)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    if args.pack:
        if args.corpus or args.suite:
            parser.error("--pack takes no corpus or suite")
        report = run_pack(args.pack)
        print_pack_report(report)
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        return 0 if report["gate"]["passed"] else 1
    if not args.corpus or not args.suite:
        parser.error("corpus and suite are required unless --pack is given")
    if args.top_k < 1:
        parser.error("--top-k must be at least 1")
    if args.max_regression < 0.0:
        parser.error("--max-regression must be non-negative")
    if args.index and args.save_index:
        parser.error("--index and --save-index are mutually exclusive")
    minima = {
        name: value
        for name, value in {
            "ndcg": args.min_ndcg,
            "mrr": args.min_mrr,
            "recall": args.min_recall,
            "success": args.min_success,
        }.items()
        if value is not None
    }
    if any(not 0.0 <= value <= 1.0 for value in minima.values()):
        parser.error("minimum relevance metrics must be between 0 and 1")
    baseline = json.loads(args.baseline.read_text(encoding="utf-8")) if args.baseline else None
    try:
        report = run_smoke(
            args.corpus,
            args.suite,
            modes=args.modes or ["lexical"],
            vector_mode=args.vector_mode,
            top_k=args.top_k,
            minima=minima,
            baseline=baseline,
            max_regression=args.max_regression,
            model=args.model,
            model_cache=args.model_cache,
            index_path=args.index,
            save_index_path=args.save_index,
        )
    except (OSError, ProviderError, ValueError) as exc:
        print(f"relevance smoke error: {exc}", file=sys.stderr)
        return 2
    rendered = json.dumps(report, indent=2, ensure_ascii=False)
    print(rendered)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered + "\n", encoding="utf-8")
    return 0 if report["gate"]["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

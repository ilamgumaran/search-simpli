#!/usr/bin/env python3
"""Build a local index, evaluate graded relevance, and enforce smoke gates."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from pathlib import Path

from src.search_platform.core import build_index, load_index, save_index
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


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run a dependency-free, graded relevance smoke test over a file corpus."
    )
    parser.add_argument("corpus", type=Path)
    parser.add_argument("suite", type=Path)
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

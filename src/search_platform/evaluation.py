from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Iterable

from .core import load_index, search
from .providers import EmbeddingProvider, ProviderError, provider_from_index


SUITE_VERSION = 2
SUPPORTED_SUITE_VERSIONS = (1, 2)
RETRIEVAL_MODES = ("lexical", "vector", "hybrid")


def load_suite(path: Path) -> dict:
    suite = json.loads(path.read_text(encoding="utf-8"))
    validate_suite(suite)
    return suite


def validate_suite(suite: object) -> None:
    if not isinstance(suite, dict) or suite.get("version") not in SUPPORTED_SUITE_VERSIONS:
        raise ValueError(
            f"evaluation suite version must be one of {SUPPORTED_SUITE_VERSIONS}"
        )
    suite_version = suite["version"]
    queries = suite.get("queries")
    if not isinstance(queries, list) or not queries:
        raise ValueError("evaluation suite must contain at least one query")
    seen_ids: set[str] = set()
    for position, item in enumerate(queries):
        if not isinstance(item, dict):
            raise ValueError(f"queries[{position}] must be an object")
        query_id = item.get("id")
        if not isinstance(query_id, str) or not query_id:
            raise ValueError(f"queries[{position}].id must be a non-empty string")
        if query_id in seen_ids:
            raise ValueError(f"duplicate query id: {query_id}")
        seen_ids.add(query_id)
        if not isinstance(item.get("query"), str) or not item["query"].strip():
            raise ValueError(f"queries[{position}].query must be a non-empty string")
        if "path_prefix" in item and not isinstance(item["path_prefix"], str):
            raise ValueError(f"queries[{position}].path_prefix must be a string")
        relevant = item.get("relevant")
        if not isinstance(relevant, list) or not relevant:
            raise ValueError(f"queries[{position}].relevant must contain at least one judgment")
        seen_judgments: set[tuple[object, object]] = set()
        for judgment_position, judgment in enumerate(relevant):
            if not isinstance(judgment, dict) or not any(
                isinstance(judgment.get(field), str) and judgment[field]
                for field in ("chunk_id", "path")
            ):
                raise ValueError(
                    f"queries[{position}].relevant[{judgment_position}] must contain chunk_id or path"
                )
            identity = (judgment.get("chunk_id"), judgment.get("path"))
            if identity in seen_judgments:
                raise ValueError(f"queries[{position}] contains duplicate judgment {identity!r}")
            seen_judgments.add(identity)
            grade = judgment.get("grade")
            if suite_version == 1:
                if grade is not None:
                    raise ValueError("graded judgments require evaluation suite version 2")
            elif isinstance(grade, bool) or not isinstance(grade, int) or not 1 <= grade <= 3:
                raise ValueError(
                    f"queries[{position}].relevant[{judgment_position}].grade must be an integer from 1 to 3"
                )


def _matches(result: dict, judgment: dict) -> bool:
    if "chunk_id" in judgment and result["chunk_id"] != judgment["chunk_id"]:
        return False
    if "path" in judgment and result["citation"]["path"] != judgment["path"]:
        return False
    return True


def _grade(judgment: dict, suite_version: int) -> int:
    return 1 if suite_version == 1 else judgment["grade"]


def _ranked_relevance(
    results: list[dict], judgments: list[dict], suite_version: int
) -> tuple[list[int], set[int]]:
    """Map ranked results to grades while counting each judgment at most once."""
    unmatched = set(range(len(judgments)))
    matched: set[int] = set()
    grades: list[int] = []
    for result in results:
        candidates = [index for index in unmatched if _matches(result, judgments[index])]
        if not candidates:
            grades.append(0)
            continue
        best = max(candidates, key=lambda index: (_grade(judgments[index], suite_version), -index))
        unmatched.remove(best)
        matched.add(best)
        grades.append(_grade(judgments[best], suite_version))
    return grades, matched


def discounted_cumulative_gain(grades: Iterable[int]) -> float:
    return sum(
        ((2**grade) - 1) / math.log2(rank + 1)
        for rank, grade in enumerate(grades, start=1)
        if grade > 0
    )


def normalized_dcg(ranked_grades: list[int], ideal_grades: list[int], top_k: int) -> float:
    ideal = discounted_cumulative_gain(sorted(ideal_grades, reverse=True)[:top_k])
    if ideal == 0.0:
        return 0.0
    return discounted_cumulative_gain(ranked_grades[:top_k]) / ideal


def evaluate_mode(
    index: dict,
    suite: dict,
    mode: str,
    *,
    top_k: int,
    embedding_provider: EmbeddingProvider | None = None,
) -> dict:
    if mode not in RETRIEVAL_MODES:
        raise ValueError(f"unknown retrieval mode: {mode}")
    per_query = []
    reciprocal_rank_sum = 0.0
    recall_sum = 0.0
    ndcg_sum = 0.0
    successful_queries = 0
    for item in suite["queries"]:
        results = search(
            index,
            item["query"],
            top_k=top_k,
            path_prefix=item.get("path_prefix"),
            retrieval_mode=mode,
            embedding_provider=embedding_provider,
        )
        ranked_grades, matched_judgment_indexes = _ranked_relevance(
            results, item["relevant"], suite["version"]
        )
        recall = len(matched_judgment_indexes) / len(item["relevant"])
        first_rank = next(
            (rank for rank, grade in enumerate(ranked_grades, start=1) if grade > 0),
            None,
        )
        reciprocal_rank = 1.0 / first_rank if first_rank is not None else 0.0
        ndcg = normalized_dcg(
            ranked_grades,
            [_grade(judgment, suite["version"]) for judgment in item["relevant"]],
            top_k,
        )
        recall_sum += recall
        reciprocal_rank_sum += reciprocal_rank
        ndcg_sum += ndcg
        if first_rank is not None:
            successful_queries += 1
        per_query.append(
            {
                "id": item["id"],
                "query": item["query"],
                "first_relevant_rank": first_rank,
                "recall": recall,
                "ndcg_at_k": ndcg,
                "returned": [result["chunk_id"] for result in results],
                "returned_paths": [result["citation"]["path"] for result in results],
                "returned_relevance_grades": ranked_grades,
            }
        )

    query_count = len(suite["queries"])
    return {
        "mode": mode,
        "top_k": top_k,
        "query_count": query_count,
        "macro_recall_at_k": recall_sum / query_count,
        "success_at_k": successful_queries / query_count,
        "mean_reciprocal_rank": reciprocal_rank_sum / query_count,
        "mean_ndcg_at_k": ndcg_sum / query_count,
        "queries": per_query,
    }


def evaluate_modes(
    index: dict,
    suite: dict,
    modes: Iterable[str],
    *,
    top_k: int,
    embedding_provider: EmbeddingProvider | None = None,
) -> dict:
    validate_suite(suite)
    if top_k < 1:
        raise ValueError("top_k must be at least 1")
    selected_modes = list(modes)
    reports = [
        evaluate_mode(
            index,
            suite,
            mode,
            top_k=top_k,
            embedding_provider=embedding_provider,
        )
        for mode in selected_modes
    ]
    warnings = []
    vector_modes_selected = any(mode in {"vector", "hybrid"} for mode in selected_modes)
    if index.get("vector_mode") == "hash" and vector_modes_selected:
        warnings.append(
            "vector_mode=hash validates vector and fusion mechanics but does not measure semantic meaning"
        )
    if index.get("vector_mode") == "cooccurrence" and vector_modes_selected:
        warnings.append(
            "cooccurrence_ppmi is a corpus-trained distributional baseline, not a modern neural embedding model"
        )
    return {
        "suite_version": suite["version"],
        "index": {
            "root": index["root"],
            "version": index["version"],
            "vector_mode": index.get("vector_mode", "none"),
            "embedding": index.get("embedding"),
            "chunks": index["stats"]["chunks"],
        },
        "warnings": warnings,
        "reports": reports,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Compare retrieval modes against relevance judgments.")
    parser.add_argument("index", type=Path)
    parser.add_argument("suite", type=Path)
    parser.add_argument("--top-k", type=int, default=5)
    parser.add_argument("--mode", action="append", choices=RETRIEVAL_MODES, dest="modes")
    parser.add_argument("--model-cache", type=Path, default=Path(".search/models"))
    args = parser.parse_args(argv)
    index = load_index(args.index)
    selected_modes = args.modes or RETRIEVAL_MODES
    try:
        report = evaluate_modes(
            index,
            load_suite(args.suite),
            selected_modes,
            top_k=args.top_k,
            embedding_provider=(
                provider_from_index(index, cache_dir=args.model_cache)
                if any(mode in {"vector", "hybrid"} for mode in selected_modes)
                else None
            ),
        )
    except ProviderError as exc:
        print(f"embedding provider error: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Iterable

from .core import load_index, search
from .providers import EmbeddingProvider, ProviderError, provider_from_index


SUITE_VERSION = 1
RETRIEVAL_MODES = ("lexical", "vector", "hybrid")


def load_suite(path: Path) -> dict:
    suite = json.loads(path.read_text(encoding="utf-8"))
    validate_suite(suite)
    return suite


def validate_suite(suite: object) -> None:
    if not isinstance(suite, dict) or suite.get("version") != SUITE_VERSION:
        raise ValueError(f"evaluation suite version must be {SUITE_VERSION}")
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
        for judgment_position, judgment in enumerate(relevant):
            if not isinstance(judgment, dict) or not any(
                isinstance(judgment.get(field), str) and judgment[field]
                for field in ("chunk_id", "path")
            ):
                raise ValueError(
                    f"queries[{position}].relevant[{judgment_position}] must contain chunk_id or path"
                )


def _matches(result: dict, judgment: dict) -> bool:
    if "chunk_id" in judgment and result["chunk_id"] != judgment["chunk_id"]:
        return False
    if "path" in judgment and result["citation"]["path"] != judgment["path"]:
        return False
    return True


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
        matched_judgments = [
            judgment
            for judgment in item["relevant"]
            if any(_matches(result, judgment) for result in results)
        ]
        recall = len(matched_judgments) / len(item["relevant"])
        first_rank = next(
            (
                rank
                for rank, result in enumerate(results, start=1)
                if any(_matches(result, judgment) for judgment in item["relevant"])
            ),
            None,
        )
        reciprocal_rank = 1.0 / first_rank if first_rank is not None else 0.0
        recall_sum += recall
        reciprocal_rank_sum += reciprocal_rank
        if first_rank is not None:
            successful_queries += 1
        per_query.append(
            {
                "id": item["id"],
                "query": item["query"],
                "first_relevant_rank": first_rank,
                "recall": recall,
                "returned": [result["chunk_id"] for result in results],
                "returned_paths": [result["citation"]["path"] for result in results],
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

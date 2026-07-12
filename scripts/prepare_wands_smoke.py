#!/usr/bin/env python3
"""Prepare a deterministic, closed-positive WANDS relevance smoke profile."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import sys
from collections import defaultdict
from pathlib import Path


LABEL_GRADES = {"Exact": 2, "Partial": 1}
SELECTION_VERSION = "wands-closed-positive-v1"
PRODUCT_RENDER_VERSION = "wands-product-summary-v1"


def _read_tsv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def _stable_order(values: set[str] | list[str], seed: str) -> list[str]:
    return sorted(
        values,
        key=lambda value: (hashlib.sha256(f"{seed}:{value}".encode()).hexdigest(), value),
    )


def _product_path(product_id: str) -> str:
    if not product_id.isdigit():
        raise ValueError(f"WANDS product id must be numeric, got {product_id!r}")
    return f"product-{int(product_id):05d}.md"


def _clean(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip()


def _render_product(product: dict[str, str], max_chars: int) -> str:
    fields = [
        ("Product", product.get("product_name", "")),
        ("Class", product.get("product_class", "")),
        ("Category", product.get("category hierarchy", "")),
        ("Description", product.get("product_description", "")),
        ("Features", product.get("product_features", "")),
    ]
    text = " | ".join(
        f"{label}: {_clean(value)}"
        for label, value in fields
        if value.strip()
    )
    if len(text) > max_chars:
        text = text[: max_chars - 1].rstrip() + "…"
    return text + "\n"


def prepare_wands_sample(
    dataset_dir: Path,
    output: Path,
    *,
    max_products: int,
    max_queries: int,
    seed: str,
    product_max_chars: int = 1_500,
) -> dict:
    if max_products < 1 or max_queries < 1:
        raise ValueError("max_products and max_queries must be positive")
    if not 128 <= product_max_chars <= 1_500:
        raise ValueError("product_max_chars must be between 128 and 1500")
    if output.exists() and any(output.iterdir()):
        raise ValueError(f"output directory must be absent or empty: {output}")

    products = {row["product_id"]: row for row in _read_tsv(dataset_dir / "product.csv")}
    queries = {row["query_id"]: row for row in _read_tsv(dataset_dir / "query.csv")}
    labels = _read_tsv(dataset_dir / "label.csv")
    positives: dict[str, dict[str, int]] = defaultdict(dict)
    explicit_irrelevant: dict[str, set[str]] = defaultdict(set)
    for row in labels:
        query_id, product_id, label = row["query_id"], row["product_id"], row["label"]
        if query_id not in queries or product_id not in products:
            raise ValueError(f"label references unknown query/product: {query_id}/{product_id}")
        if label in LABEL_GRADES:
            positives[query_id][product_id] = LABEL_GRADES[label]
        elif label == "Irrelevant":
            explicit_irrelevant[query_id].add(product_id)
        else:
            raise ValueError(f"unknown WANDS label: {label!r}")

    selected_queries: list[str] = []
    selected_products: set[str] = set()
    for query_id in _stable_order(set(positives), f"{seed}:query"):
        if len(selected_queries) >= max_queries:
            break
        candidate_products = selected_products | set(positives[query_id])
        if len(candidate_products) <= max_products:
            selected_queries.append(query_id)
            selected_products = candidate_products
    if not selected_queries:
        raise ValueError("product cap is too small to retain every positive for any query")

    # Prefer explicitly judged negatives for the chosen queries, then fill with
    # stable corpus distractors. Every selected query keeps all of its positives.
    judged_negatives = set().union(
        *(explicit_irrelevant[query_id] for query_id in selected_queries)
    )
    candidates = _stable_order(judged_negatives - selected_products, f"{seed}:negative")
    candidates += _stable_order(
        set(products) - selected_products - judged_negatives,
        f"{seed}:distractor",
    )
    for product_id in candidates:
        if len(selected_products) >= min(max_products, len(products)):
            break
        selected_products.add(product_id)

    corpus = output / "corpus"
    corpus.mkdir(parents=True, exist_ok=True)
    for product_id in sorted(selected_products, key=lambda value: int(value)):
        (corpus / _product_path(product_id)).write_text(
            _render_product(products[product_id], product_max_chars), encoding="utf-8"
        )

    suite_queries = []
    positive_judgment_count = 0
    for query_id in selected_queries:
        judgments = [
            {"path": _product_path(product_id), "grade": grade}
            for product_id, grade in sorted(
                positives[query_id].items(), key=lambda item: (-item[1], int(item[0]))
            )
        ]
        positive_judgment_count += len(judgments)
        suite_queries.append(
            {
                "id": f"wands-{query_id}",
                "query": queries[query_id]["query"],
                "relevant": judgments,
                "metadata": {
                    "wands_query_id": query_id,
                    "query_class": queries[query_id].get("query_class", ""),
                },
            }
        )
    suite = {
        "version": 2,
        "metadata": {
            "source": "Wayfair WANDS",
            "source_url": "https://github.com/wayfair/WANDS",
            "license": "MIT",
            "selection_version": SELECTION_VERSION,
            "product_render_version": PRODUCT_RENDER_VERSION,
            "product_max_chars": product_max_chars,
            "seed": seed,
            "grade_mapping": {"Exact": 2, "Partial": 1, "Irrelevant/unjudged": 0},
            "sample_is_comparable_to_full_wands": False,
        },
        "queries": suite_queries,
    }
    (output / "judgments.json").write_text(
        json.dumps(suite, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    explicit_negative_pairs = sum(
        len(explicit_irrelevant[query_id] & selected_products)
        for query_id in selected_queries
    )
    manifest = {
        "selection_version": SELECTION_VERSION,
        "product_render_version": PRODUCT_RENDER_VERSION,
        "product_max_chars": product_max_chars,
        "seed": seed,
        "available": {"products": len(products), "queries": len(queries), "labels": len(labels)},
        "selected": {
            "products": len(selected_products),
            "queries": len(selected_queries),
            "positive_judgments": positive_judgment_count,
            "explicit_irrelevant_pairs_in_corpus": explicit_negative_pairs,
        },
        "requested_caps": {"products": max_products, "queries": max_queries},
        "selection_rule": (
            "SHA-256 query order; retain a query only when all Exact/Partial products fit; "
            "fill remaining product slots with explicitly judged negatives then stable distractors"
        ),
        "limitations": [
            "This capped diagnostic is not score-comparable to full-corpus WANDS runs.",
            "WANDS has 480 queries, so a 1,000-query WANDS profile is impossible.",
            "Unjudged products are treated as grade 0, as in pooled offline evaluation.",
        ],
    }
    (output / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset_dir", type=Path, help="WANDS dataset directory containing TSV files")
    parser.add_argument("output", type=Path)
    parser.add_argument("--max-products", type=int, default=10_000)
    parser.add_argument("--max-queries", type=int, default=1_000)
    parser.add_argument("--product-max-chars", type=int, default=1_500)
    parser.add_argument("--seed", default="search-simpli-wands-v1")
    args = parser.parse_args(argv)
    try:
        manifest = prepare_wands_sample(
            args.dataset_dir,
            args.output,
            max_products=args.max_products,
            max_queries=args.max_queries,
            seed=args.seed,
            product_max_chars=args.product_max_chars,
        )
    except (OSError, ValueError) as exc:
        print(f"WANDS preparation error: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

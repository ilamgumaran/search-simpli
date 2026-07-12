from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .core import build_index, context_envelope, load_index, save_index, search
from .providers import (
    DEFAULT_FASTEMBED_MODEL,
    FastEmbedProvider,
    ProviderError,
    provider_from_index,
)
from .access import load_access_rules, normalize_labels


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Index local knowledge and retrieve cited evidence.")
    commands = parser.add_subparsers(dest="command", required=True)

    index_command = commands.add_parser("index", help="Index a directory of text and source files.")
    index_command.add_argument("root", type=Path)
    index_command.add_argument("--out", type=Path, default=Path(".search/index.json"))
    index_command.add_argument(
        "--vector-mode", choices=("none", "hash", "cooccurrence", "neural"), default="none"
    )
    index_command.add_argument("--model", default=DEFAULT_FASTEMBED_MODEL)
    index_command.add_argument("--model-cache", type=Path, default=Path(".search/models"))
    index_command.add_argument("--access-rules", type=Path)
    index_command.add_argument(
        "--incremental-from",
        type=Path,
        help="reuse unchanged files/chunks/vectors from a compatible previous index",
    )

    for name, help_text in (
        ("query", "Show ranked passages for a person."),
        ("context", "Emit a model/tool-friendly evidence envelope."),
    ):
        command = commands.add_parser(name, help=help_text)
        command.add_argument("index", type=Path)
        command.add_argument("query")
        command.add_argument("--top-k", type=int, default=5)
        command.add_argument("--candidate-k", type=int, default=100)
        command.add_argument("--path-prefix")
        command.add_argument("--mode", choices=("lexical", "vector", "hybrid"), default="hybrid")
        command.add_argument("--model-cache", type=Path, default=Path(".search/models"))
        command.add_argument("--principal-label", action="append", default=[])
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.command == "index":
        try:
            provider = (
                FastEmbedProvider(model_name=args.model, cache_dir=args.model_cache)
                if args.vector_mode == "neural"
                else None
            )
        except ProviderError as exc:
            print(f"embedding provider error: {exc}", file=sys.stderr)
            return 2
        index = build_index(
            args.root,
            vector_mode=args.vector_mode,
            embedding_provider=provider,
            access_rules=load_access_rules(args.access_rules) if args.access_rules else None,
            previous_index=load_index(args.incremental_from) if args.incremental_from else None,
        )
        save_index(index, args.out)
        print(json.dumps({"index": str(args.out), **index["stats"]}, indent=2))
        return 0

    index = load_index(args.index)
    principal_labels = normalize_labels(args.principal_label)
    try:
        provider = (
            None
            if args.mode == "lexical"
            else provider_from_index(index, cache_dir=args.model_cache)
        )
    except ProviderError as exc:
        print(f"embedding provider error: {exc}", file=sys.stderr)
        return 2
    if args.command == "context":
        payload = context_envelope(
            index,
            args.query,
            top_k=args.top_k,
            candidate_k=args.candidate_k,
            path_prefix=args.path_prefix,
            retrieval_mode=args.mode,
            embedding_provider=provider,
            principal_labels=principal_labels,
        )
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 0

    results = search(
        index,
        args.query,
        top_k=args.top_k,
        candidate_k=args.candidate_k,
        path_prefix=args.path_prefix,
        retrieval_mode=args.mode,
        embedding_provider=provider,
        principal_labels=principal_labels,
    )
    if not results:
        print("No evidence found.")
        return 0
    for position, result in enumerate(results, start=1):
        citation = result["citation"]
        print(f"{position}. {citation['path']}:{citation['start_line']}-{citation['end_line']} score={result['score']:.6f}")
        print(result["content"])
        print()
    return 0

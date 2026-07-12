from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .core import embed_query, load_index
from .providers import ProviderError, provider_from_index


def embed_payload(index: dict, query: str, embedding_provider=None) -> dict:
    vector = embed_query(index, query, embedding_provider)
    embedding = index.get("embedding")
    return {
        "query": query,
        "model_id": embedding["model_id"] if embedding else "none",
        "dimensions": len(vector),
        "vector": vector,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Embed a query using an index's exact vector model.")
    parser.add_argument("index", type=Path)
    parser.add_argument("query")
    parser.add_argument("--vector-only", action="store_true")
    parser.add_argument("--model-cache", type=Path, default=Path(".search/models"))
    args = parser.parse_args(argv)
    index = load_index(args.index)
    try:
        payload = embed_payload(
            index, args.query, provider_from_index(index, cache_dir=args.model_cache)
        )
    except ProviderError as exc:
        print(f"embedding provider error: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(payload["vector"] if args.vector_only else payload, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

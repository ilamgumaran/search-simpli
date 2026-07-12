#!/usr/bin/env python3
"""Reproducible files/folders indexing scale benchmark.

The synthetic embedding provider measures vector movement and serialization,
not neural inference quality or model latency. Use it to isolate indexing and
artifact costs while the Zig benchmark isolates query execution.
"""

from __future__ import annotations

import argparse
import json
import platform
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

from src.search_platform.core import build_index, save_index


class SyntheticEmbeddingProvider:
    def __init__(self, dimensions: int) -> None:
        self.dimensions = dimensions
        self.embedded_chunks = 0
        self._vector = [1.0] + [0.0] * (dimensions - 1)

    @property
    def metadata(self) -> dict:
        return {
            "model_id": f"synthetic-scale-{self.dimensions}-v1",
            "model_family": "synthetic-scale",
            "type": "neural",
            "dimensions": self.dimensions,
            "normalization": "l2",
            "semantic": False,
            "provider": {"type": "synthetic-benchmark"},
        }

    def embed_documents(self, texts: list[str]) -> list[list[float]]:
        self.embedded_chunks += len(texts)
        return [self._vector.copy() for _ in texts]

    def embed_queries(self, texts: list[str]) -> list[list[float]]:
        return [self._vector.copy() for _ in texts]


def timed_build(**kwargs: object) -> tuple[dict, float]:
    started = time.perf_counter_ns()
    index = build_index(**kwargs)
    elapsed_ms = (time.perf_counter_ns() - started) / 1_000_000
    return index, elapsed_ms


def write_corpus(root: Path, document_count: int) -> None:
    for number in range(document_count):
        directory = root / f"group-{number // 100:05d}"
        directory.mkdir(exist_ok=True)
        (directory / f"document-{number:06d}.md").write_text(
            "Search benchmark evidence for files and folders.\n"
            f"Document number {number} discusses topic {number % 97}, lexical retrieval, "
            "semantic vectors, citations, and agent tools.\n",
            encoding="utf-8",
        )


def benchmark_size(document_count: int, dimensions: int) -> dict:
    with tempfile.TemporaryDirectory(prefix="search-scale-") as temporary:
        root = Path(temporary) / "knowledge"
        root.mkdir()
        write_corpus(root, document_count)

        none_full, none_full_ms = timed_build(root=root, vector_mode="none")
        none_incremental, none_incremental_ms = timed_build(
            root=root,
            vector_mode="none",
            previous_index=none_full,
        )
        none_path = Path(temporary) / "none-index.json"
        save_index(none_full, none_path)

        neural_full_provider = SyntheticEmbeddingProvider(dimensions)
        neural_full, neural_full_ms = timed_build(
            root=root,
            vector_mode="neural",
            embedding_provider=neural_full_provider,
        )
        neural_incremental_provider = SyntheticEmbeddingProvider(dimensions)
        neural_incremental, neural_incremental_ms = timed_build(
            root=root,
            vector_mode="neural",
            embedding_provider=neural_incremental_provider,
            previous_index=neural_full,
        )
        neural_path = Path(temporary) / "synthetic-neural-index.json"
        save_index(neural_full, neural_path)

        return {
            "documents": document_count,
            "chunks": none_full["stats"]["chunks"],
            "none": {
                "full_build_ms": round(none_full_ms, 3),
                "unchanged_incremental_ms": round(none_incremental_ms, 3),
                "artifact_bytes": none_path.stat().st_size,
                "reused_chunks": none_incremental["stats"]["incremental"]["reused_chunks"],
            },
            "synthetic_neural": {
                "dimensions": dimensions,
                "full_build_ms": round(neural_full_ms, 3),
                "unchanged_incremental_ms": round(neural_incremental_ms, 3),
                "artifact_bytes": neural_path.stat().st_size,
                "full_embedded_chunks": neural_full_provider.embedded_chunks,
                "incremental_embedded_chunks": neural_incremental_provider.embedded_chunks,
                "reused_chunks": neural_incremental["stats"]["incremental"]["reused_chunks"],
            },
        }


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--sizes", type=int, nargs="+", default=[100, 1_000, 5_000])
    result.add_argument("--dimensions", type=int, default=384)
    result.add_argument("--out", type=Path)
    return result


def main() -> int:
    args = parser().parse_args()
    if any(size < 1 for size in args.sizes):
        raise SystemExit("all sizes must be positive")
    if args.dimensions < 1:
        raise SystemExit("dimensions must be positive")
    payload = {
        "benchmark": "python-files-folders-indexing-v1",
        "recorded_at": datetime.now(timezone.utc).isoformat(),
        "python": platform.python_version(),
        "platform": platform.platform(),
        "notes": [
            "Corpus creation is excluded from build timings.",
            "Synthetic vectors measure pipeline and JSON costs, not model inference latency.",
            "Each document is one small UTF-8 Markdown file and produces one chunk.",
        ],
        "results": [benchmark_size(size, args.dimensions) for size in args.sizes],
    }
    encoded = json.dumps(payload, indent=2) + "\n"
    if args.out is not None:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(encoded, encoding="utf-8")
    print(encoded, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

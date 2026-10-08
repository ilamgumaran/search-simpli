from __future__ import annotations

import argparse
import json
from pathlib import Path

from .core import load_index


INTERCHANGE_VERSION = 1
# The default stays the ASCII analyzer every interchange file named before
# contract 1.1.0, so existing exports are unchanged.
ZIG_ANALYZER_ID = "ascii-alnum-v1"
# contracts/snapshot-interchange.schema.json's `analyzer_id` enum (1.1.0).
SUPPORTED_ANALYZER_IDS = ("ascii-alnum-v1", "analyzer-v2")


def build_interchange(index: dict, *, generation: int = 1, analyzer_id: str = ZIG_ANALYZER_ID) -> dict:
    if isinstance(generation, bool) or not isinstance(generation, int) or generation < 1:
        raise ValueError("generation must be a positive integer")
    if analyzer_id not in SUPPORTED_ANALYZER_IDS:
        raise ValueError(f"analyzer_id must be one of {', '.join(SUPPORTED_ANALYZER_IDS)}")
    embedding = index.get("embedding")
    embedding_model_id = embedding["model_id"] if embedding else "none"
    documents = []
    dimensions = None
    for chunk in index["chunks"]:
        vector = chunk.get("vector") or []
        if vector:
            if dimensions is None:
                dimensions = len(vector)
            elif len(vector) != dimensions:
                raise ValueError("index contains inconsistent vector dimensions")
        documents.append(
            {
                "id": chunk["id"],
                "path": chunk["path"],
                "start_line": chunk["start_line"],
                "end_line": chunk["end_line"],
                "text": chunk["text"],
                "vector": vector,
                "required_labels": sorted(set(chunk.get("required_labels", []))),
            }
        )
    if dimensions is None and embedding_model_id != "none":
        raise ValueError("embedding metadata exists but the index has no vectors")
    return {
        "format_version": INTERCHANGE_VERSION,
        "generation": generation,
        "analyzer_id": analyzer_id,
        "embedding_model_id": embedding_model_id,
        "documents": documents,
    }


def save_interchange(payload: dict, output: Path) -> None:
    output = output.expanduser()
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    temporary.replace(output)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Export a reference index for Zig segment construction.")
    parser.add_argument("index", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--generation", type=int, default=1)
    parser.add_argument(
        "--analyzer",
        choices=SUPPORTED_ANALYZER_IDS,
        default=ZIG_ANALYZER_ID,
        help="analyzer_id Zig tokenizes with (default: %(default)s; analyzer-v2 is Unicode-aware)",
    )
    args = parser.parse_args(argv)
    payload = build_interchange(load_index(args.index), generation=args.generation, analyzer_id=args.analyzer)
    save_interchange(payload, args.out)
    print(
        json.dumps(
            {
                "output": str(args.out),
                "generation": payload["generation"],
                "documents": len(payload["documents"]),
                "embedding_model_id": payload["embedding_model_id"],
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

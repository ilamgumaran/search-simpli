from __future__ import annotations

import argparse
import json
from pathlib import Path

from .core import load_index


INTERCHANGE_VERSION = 1
ZIG_ANALYZER_ID = "ascii-alnum-v1"


def build_interchange(index: dict, *, generation: int = 1) -> dict:
    if isinstance(generation, bool) or not isinstance(generation, int) or generation < 1:
        raise ValueError("generation must be a positive integer")
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
        "analyzer_id": ZIG_ANALYZER_ID,
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
    args = parser.parse_args(argv)
    payload = build_interchange(load_index(args.index), generation=args.generation)
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

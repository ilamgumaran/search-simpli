from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path
from typing import Any, TextIO

from .core import context_envelope, load_index
from .providers import EmbeddingProvider, ProviderError, provider_from_index
from .access import is_authorized, normalize_labels


class ToolFailure(Exception):
    def __init__(self, code: int, message: str, data: Any | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = data


class KnowledgeTools:
    """Narrow, read-only operations over one immutable local index snapshot."""

    def __init__(
        self,
        index: dict,
        embedding_provider: EmbeddingProvider | None = None,
        principal_labels: list[str] | None = None,
    ) -> None:
        self.index = index
        self.embedding_provider = embedding_provider
        self.principal_labels = normalize_labels(principal_labels or [])
        self._chunks_by_id = {chunk["id"]: chunk for chunk in index["chunks"]}

    def handle(self, request: Any) -> dict:
        request_id = request.get("id") if isinstance(request, dict) else None
        try:
            if not isinstance(request, dict) or request.get("jsonrpc") != "2.0":
                raise ToolFailure(-32600, "Invalid Request")
            if "id" not in request or not isinstance(request.get("method"), str):
                raise ToolFailure(-32600, "Invalid Request")
            params = request.get("params", {})
            if not isinstance(params, dict):
                raise ToolFailure(-32602, "Invalid params", "params must be an object")
            result = self.call(request["method"], params)
            return {"jsonrpc": "2.0", "id": request_id, "result": result}
        except ToolFailure as exc:
            error: dict[str, Any] = {"code": exc.code, "message": exc.message}
            if exc.data is not None:
                error["data"] = exc.data
            return {"jsonrpc": "2.0", "id": request_id, "error": error}

    def call(self, method: str, params: dict) -> dict:
        if method == "search_knowledge":
            self._reject_unknown(params, {"query", "top_k", "candidate_k", "path_prefix", "retrieval_mode"})
            query = self._required_string(params, "query")
            top_k = params.get("top_k", 5)
            if isinstance(top_k, bool) or not isinstance(top_k, int) or not 1 <= top_k <= 100:
                raise ToolFailure(-32602, "Invalid params", "top_k must be an integer from 1 to 100")
            candidate_k = params.get("candidate_k", 100)
            if (
                isinstance(candidate_k, bool)
                or not isinstance(candidate_k, int)
                or not top_k <= candidate_k <= 10_000
            ):
                raise ToolFailure(
                    -32602,
                    "Invalid params",
                    "candidate_k must be an integer from top_k to 10000",
                )
            path_prefix = self._optional_string(params, "path_prefix")
            retrieval_mode = params.get("retrieval_mode", "hybrid")
            if not isinstance(retrieval_mode, str) or retrieval_mode not in {"lexical", "vector", "hybrid"}:
                raise ToolFailure(
                    -32602,
                    "Invalid params",
                    "retrieval_mode must be lexical, vector, or hybrid",
                )
            return context_envelope(
                self.index,
                query,
                top_k=top_k,
                candidate_k=candidate_k,
                path_prefix=path_prefix,
                retrieval_mode=retrieval_mode,
                embedding_provider=self.embedding_provider,
                principal_labels=self.principal_labels,
            )

        if method == "read_chunk":
            self._reject_unknown(params, {"chunk_id", "path_prefix"})
            chunk_id = self._required_string(params, "chunk_id")
            path_prefix = self._optional_string(params, "path_prefix")
            chunk = self._chunks_by_id.get(chunk_id)
            if (
                chunk is None
                or (path_prefix is not None and not chunk["path"].startswith(path_prefix))
                or not is_authorized(chunk.get("required_labels", []), self.principal_labels)
            ):
                raise ToolFailure(-32004, "Chunk not found", {"chunk_id": chunk_id})
            return {
                "chunk_id": chunk["id"],
                "citation": {
                    "path": chunk["path"],
                    "start_line": chunk["start_line"],
                    "end_line": chunk["end_line"],
                },
                "content": chunk["text"],
            }

        if method == "list_sources":
            self._reject_unknown(params, {"path_prefix"})
            path_prefix = self._optional_string(params, "path_prefix")
            counts = Counter(
                chunk["path"]
                for chunk in self.index["chunks"]
                if path_prefix is None or chunk["path"].startswith(path_prefix)
                if is_authorized(chunk.get("required_labels", []), self.principal_labels)
            )
            return {
                "sources": [{"path": path, "chunks": counts[path]} for path in sorted(counts)],
                "count": len(counts),
            }

        if method == "index_status":
            self._reject_unknown(params, set())
            stats = self.index["stats"]
            return {
                "ready": True,
                "version": self.index["version"],
                "created_at": self.index["created_at"],
                "root": self.index["root"],
                "vector_mode": self.index.get("vector_mode", "none"),
                "embedding": self.index.get("embedding"),
                "files": stats["files"],
                "chunks": stats["chunks"],
                "skipped": stats["skipped"],
                "incremental": stats.get("incremental"),
            }

        raise ToolFailure(-32601, "Method not found", {"method": method})

    @staticmethod
    def _reject_unknown(params: dict, allowed: set[str]) -> None:
        unknown = sorted(set(params) - allowed)
        if unknown:
            raise ToolFailure(-32602, "Invalid params", {"unknown": unknown})

    @staticmethod
    def _required_string(params: dict, name: str) -> str:
        value = params.get(name)
        if not isinstance(value, str) or not value.strip():
            raise ToolFailure(-32602, "Invalid params", f"{name} must be a non-empty string")
        return value

    @staticmethod
    def _optional_string(params: dict, name: str) -> str | None:
        value = params.get(name)
        if value is None:
            return None
        if not isinstance(value, str):
            raise ToolFailure(-32602, "Invalid params", f"{name} must be a string")
        return value


def serve(tools: KnowledgeTools, input_stream: TextIO, output_stream: TextIO) -> None:
    for line in input_stream:
        if not line.strip():
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError as exc:
            response = {
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32700, "message": "Parse error", "data": {"line": exc.lineno, "column": exc.colno}},
            }
        else:
            response = tools.handle(request)
        output_stream.write(json.dumps(response, ensure_ascii=False, separators=(",", ":")) + "\n")
        output_stream.flush()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Expose a local knowledge index as JSON-lines tools.")
    parser.add_argument("index", type=Path)
    parser.add_argument("--model-cache", type=Path, default=Path(".search/models"))
    parser.add_argument("--principal-label", action="append", default=[])
    args = parser.parse_args(argv)
    index = load_index(args.index)
    try:
        provider = provider_from_index(index, cache_dir=args.model_cache)
    except ProviderError as exc:
        print(f"embedding provider error: {exc}", file=sys.stderr)
        return 2
    serve(
        KnowledgeTools(index, provider, args.principal_label),
        sys.stdin,
        sys.stdout,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

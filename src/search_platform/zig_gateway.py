from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any, Protocol, TextIO

from .core import embed_query, load_index
from .providers import EmbeddingProvider, ProviderError, provider_from_index
from .access import normalize_labels


class BackendFailure(RuntimeError):
    """The persisted engine process could not complete a protocol exchange."""


class GatewayConfigurationError(RuntimeError):
    """The query model and persisted snapshot are not vector-compatible."""


class JsonRpcBackend(Protocol):
    def call(self, request: Any) -> dict: ...


class JsonLineProcess:
    """Synchronous JSON-RPC client for one newline-delimited child process."""

    def __init__(self, command: list[str], *, cwd: Path | None = None) -> None:
        self.process = subprocess.Popen(
            command,
            cwd=cwd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        if self.process.stdin is None or self.process.stdout is None:  # pragma: no cover
            self.close()
            raise BackendFailure("backend process did not expose stdin/stdout")

    def call(self, request: Any) -> dict:
        if self.process.poll() is not None:
            raise BackendFailure(f"backend process exited with status {self.process.returncode}")
        assert self.process.stdin is not None and self.process.stdout is not None
        try:
            self.process.stdin.write(json.dumps(request, ensure_ascii=False, separators=(",", ":")) + "\n")
            self.process.stdin.flush()
            response_line = self.process.stdout.readline()
        except (BrokenPipeError, OSError) as exc:
            raise BackendFailure("backend transport failed") from exc
        if not response_line:
            status = self.process.poll()
            raise BackendFailure(f"backend closed its response stream (status {status})")
        try:
            response = json.loads(response_line)
        except json.JSONDecodeError as exc:
            raise BackendFailure("backend emitted invalid JSON") from exc
        if not isinstance(response, dict):
            raise BackendFailure("backend emitted a non-object JSON-RPC response")
        return response

    def close(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()

    def __enter__(self) -> JsonLineProcess:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


class EmbeddingGateway:
    """Add compatible query vectors while preserving the public tool contract."""

    def __init__(
        self,
        index: dict,
        backend: JsonRpcBackend,
        embedding_provider: EmbeddingProvider | None = None,
        principal_labels: list[str] | None = None,
    ) -> None:
        self.index = index
        self.backend = backend
        self.embedding_provider = embedding_provider
        self.principal_labels = normalize_labels(principal_labels or [])
        embedding = index.get("embedding")
        self.model_id = embedding["model_id"] if embedding else "none"
        self.dimensions = embedding["dimensions"] if embedding else 0
        status_response = backend.call(
            {"jsonrpc": "2.0", "id": "__gateway_status__", "method": "index_status", "params": {}}
        )
        status = status_response.get("result") if isinstance(status_response, dict) else None
        if not isinstance(status, dict):
            raise GatewayConfigurationError("backend did not return index status")
        actual_model = status.get("embedding_model_id")
        actual_dimensions = status.get("vector_dimensions")
        if actual_model != self.model_id or actual_dimensions != self.dimensions:
            raise GatewayConfigurationError(
                "query model does not match snapshot: "
                f"expected {self.model_id!r}/{self.dimensions}, "
                f"got {actual_model!r}/{actual_dimensions!r}"
            )
        self.status = status

    def handle(self, request: Any) -> dict:
        if not isinstance(request, dict):
            return self.backend.call(request)
        method = request.get("method")
        if method not in {"search_knowledge", "read_chunk", "list_sources"}:
            return self.backend.call(request)
        params = request.get("params")
        if not isinstance(params, dict):
            return self.backend.call(request)
        if "principal_labels" in params:
            return self._error(
                request.get("id"),
                -32602,
                "Invalid params",
                "principal_labels are managed by the authenticated gateway",
            )
        forwarded = dict(request)
        forwarded_params = dict(params)
        forwarded_params["principal_labels"] = self.principal_labels
        forwarded["params"] = forwarded_params
        if method != "search_knowledge":
            return self.backend.call(forwarded)
        if "query_vector" in params:
            return self._error(
                request.get("id"),
                -32602,
                "Invalid params",
                "query_vector is managed by the embedding gateway",
            )
        mode = params.get("retrieval_mode", "hybrid")
        if mode not in {"vector", "hybrid"} or self.dimensions == 0:
            return self.backend.call(forwarded)
        query = params.get("query")
        if not isinstance(query, str) or not query.strip():
            return self.backend.call(forwarded)
        vector = embed_query(self.index, query, self.embedding_provider)
        if len(vector) != self.dimensions:
            return self._error(
                request.get("id"),
                -32010,
                "Query embedding failed",
                "embedding provider returned incompatible dimensions",
            )
        forwarded_params["query_vector"] = vector
        return self.backend.call(forwarded)

    @staticmethod
    def _error(request_id: Any, code: int, message: str, data: Any) -> dict:
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": code, "message": message, "data": data},
        }


def serve(gateway: EmbeddingGateway, input_stream: TextIO, output_stream: TextIO) -> None:
    for line in input_stream:
        if not line.strip():
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError as exc:
            response = {
                "jsonrpc": "2.0",
                "id": None,
                "error": {
                    "code": -32700,
                    "message": "Parse error",
                    "data": {"line": exc.lineno, "column": exc.colno},
                },
            }
        else:
            try:
                response = gateway.handle(request)
            except BackendFailure as exc:
                request_id = request.get("id") if isinstance(request, dict) else None
                response = EmbeddingGateway._error(
                    request_id, -32011, "Search backend unavailable", str(exc)
                )
            except ProviderError as exc:
                request_id = request.get("id") if isinstance(request, dict) else None
                response = EmbeddingGateway._error(
                    request_id, -32010, "Query embedding failed", str(exc)
                )
        output_stream.write(json.dumps(response, ensure_ascii=False, separators=(",", ":")) + "\n")
        output_stream.flush()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Expose the persisted Zig engine with automatic, model-matched query embedding."
    )
    parser.add_argument("index", type=Path, help="Python model/index used to build the Zig snapshot")
    parser.add_argument("snapshot", type=Path, help="published Zig snapshot directory")
    parser.add_argument("--zig", default="zig", help="Zig executable path")
    parser.add_argument(
        "--zig-dir",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "zig",
        help="directory containing build.zig",
    )
    parser.add_argument("--zig-cache-dir", type=Path, help="optional Zig project cache directory")
    parser.add_argument("--zig-global-cache-dir", type=Path, help="optional Zig global cache directory")
    parser.add_argument("--model-cache", type=Path, default=Path(".search/models"))
    parser.add_argument("--principal-label", action="append", default=[])
    args = parser.parse_args(argv)
    command = [args.zig, "build"]
    if args.zig_cache_dir is not None:
        command.extend(["--cache-dir", str(args.zig_cache_dir.expanduser().resolve())])
    if args.zig_global_cache_dir is not None:
        command.extend(
            ["--global-cache-dir", str(args.zig_global_cache_dir.expanduser().resolve())]
        )
    command.extend(["run", "--", "serve", str(args.snapshot.expanduser().resolve())])
    try:
        with JsonLineProcess(command, cwd=args.zig_dir.expanduser().resolve()) as backend:
            index = load_index(args.index)
            gateway = EmbeddingGateway(
                index,
                backend,
                provider_from_index(index, cache_dir=args.model_cache),
                args.principal_label,
            )
            serve(gateway, sys.stdin, sys.stdout)
    except (BackendFailure, GatewayConfigurationError, ProviderError, OSError, ValueError) as exc:
        print(f"zig gateway startup failed: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

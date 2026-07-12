import io
import json
import tempfile
import unittest
from pathlib import Path
from typing import Any

from src.search_platform.core import build_index
from src.search_platform.zig_gateway import (
    EmbeddingGateway,
    GatewayConfigurationError,
    serve,
)


class FakeBackend:
    def __init__(self, model_id: str, dimensions: int) -> None:
        self.model_id = model_id
        self.dimensions = dimensions
        self.requests: list[Any] = []

    def call(self, request: Any) -> dict:
        self.requests.append(request)
        if isinstance(request, dict) and request.get("method") == "index_status":
            return {
                "jsonrpc": "2.0",
                "id": request.get("id"),
                "result": {
                    "ready": True,
                    "generation": 1,
                    "embedding_model_id": self.model_id,
                    "vector_dimensions": self.dimensions,
                },
            }
        return {"jsonrpc": "2.0", "id": request.get("id"), "result": {"forwarded": True}}


def semantic_index() -> dict:
    temporary = tempfile.TemporaryDirectory()
    root = Path(temporary.name)
    (root / "car.md").write_text("A car is a road vehicle with wheels.", encoding="utf-8")
    (root / "auto.md").write_text("An automobile is a road vehicle with wheels.", encoding="utf-8")
    index = build_index(root, vector_mode="cooccurrence")
    temporary.cleanup()
    return index


class ZigGatewayTests(unittest.TestCase):
    def test_semantic_search_is_embedded_and_forwarded(self) -> None:
        index = semantic_index()
        backend = FakeBackend(index["embedding"]["model_id"], index["embedding"]["dimensions"])
        gateway = EmbeddingGateway(index, backend)
        response = gateway.handle(
            {
                "jsonrpc": "2.0",
                "id": 7,
                "method": "search_knowledge",
                "params": {"query": "car", "retrieval_mode": "vector", "path_prefix": "public/"},
            }
        )

        self.assertEqual(response["id"], 7)
        forwarded = backend.requests[-1]
        self.assertEqual(len(forwarded["params"]["query_vector"]), index["embedding"]["dimensions"])
        self.assertEqual(forwarded["params"]["path_prefix"], "public/")

    def test_model_instance_mismatch_fails_at_startup(self) -> None:
        index = semantic_index()
        backend = FakeBackend("cooccurrence-ppmi-v1-sha256-wrong", index["embedding"]["dimensions"])
        with self.assertRaisesRegex(GatewayConfigurationError, "does not match"):
            EmbeddingGateway(index, backend)

    def test_lexical_search_and_non_search_methods_are_transparent(self) -> None:
        index = semantic_index()
        backend = FakeBackend(index["embedding"]["model_id"], index["embedding"]["dimensions"])
        gateway = EmbeddingGateway(index, backend)
        lexical = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "search_knowledge",
            "params": {"query": "car", "retrieval_mode": "lexical"},
        }
        read = {"jsonrpc": "2.0", "id": 2, "method": "read_chunk", "params": {"chunk_id": "x"}}
        gateway.handle(lexical)
        gateway.handle(read)

        self.assertNotIn("query_vector", backend.requests[-2]["params"])
        self.assertEqual(backend.requests[-1]["method"], "read_chunk")
        self.assertEqual(backend.requests[-1]["params"], {"chunk_id": "x", "principal_labels": []})

    def test_callers_cannot_override_query_vectors(self) -> None:
        index = semantic_index()
        backend = FakeBackend(index["embedding"]["model_id"], index["embedding"]["dimensions"])
        gateway = EmbeddingGateway(index, backend)
        before = len(backend.requests)
        response = gateway.handle(
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "search_knowledge",
                "params": {"query": "car", "query_vector": [1.0]},
            }
        )

        self.assertEqual(response["error"]["code"], -32602)
        self.assertEqual(len(backend.requests), before)

    def test_gateway_injects_principal_and_rejects_caller_forgery(self) -> None:
        index = semantic_index()
        backend = FakeBackend(index["embedding"]["model_id"], index["embedding"]["dimensions"])
        gateway = EmbeddingGateway(index, backend, principal_labels=["tenant:acme"])
        gateway.handle(
            {
                "jsonrpc": "2.0",
                "id": 10,
                "method": "list_sources",
                "params": {"path_prefix": "private/"},
            }
        )
        forged = gateway.handle(
            {
                "jsonrpc": "2.0",
                "id": 11,
                "method": "read_chunk",
                "params": {"chunk_id": "x", "principal_labels": ["admin"]},
            }
        )

        self.assertEqual(backend.requests[-1]["params"]["principal_labels"], ["tenant:acme"])
        self.assertEqual(forged["error"]["code"], -32602)

    def test_json_lines_server_recovers_after_parse_error(self) -> None:
        index = semantic_index()
        backend = FakeBackend(index["embedding"]["model_id"], index["embedding"]["dimensions"])
        gateway = EmbeddingGateway(index, backend)
        input_stream = io.StringIO(
            "not-json\n"
            + json.dumps({"jsonrpc": "2.0", "id": 8, "method": "index_status", "params": {}})
            + "\n"
        )
        output_stream = io.StringIO()
        serve(gateway, input_stream, output_stream)
        responses = [json.loads(line) for line in output_stream.getvalue().splitlines()]

        self.assertEqual(responses[0]["error"]["code"], -32700)
        self.assertEqual(responses[1]["id"], 8)


if __name__ == "__main__":
    unittest.main()

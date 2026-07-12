import io
import json
import math
import tempfile
import unittest
from pathlib import Path

from src.search_platform.core import build_index, embed_query, search
from src.search_platform.providers import ProviderMismatch
from src.search_platform.zig_gateway import EmbeddingGateway, serve


class TinyProvider:
    def __init__(self, model_id: str = "tiny-neural-v1") -> None:
        self._metadata = {
            "model_id": model_id,
            "model_family": "tiny-test",
            "type": "neural",
            "dimensions": 2,
            "semantic": True,
            "provider": {"type": "test"},
        }

    @property
    def metadata(self) -> dict:
        return dict(self._metadata)

    @staticmethod
    def _vector(text: str) -> list[float]:
        lowered = text.casefold()
        if "car" in lowered or "automobile" in lowered or "vehicle" in lowered:
            return [2.0, 0.0]
        if "doctor" in lowered or "physician" in lowered or "medical" in lowered:
            return [0.0, 3.0]
        return [-1.0, -1.0]

    def embed_documents(self, texts: list[str]) -> list[list[float]]:
        return [self._vector(text) for text in texts]

    def embed_queries(self, texts: list[str]) -> list[list[float]]:
        return [self._vector(text) for text in texts]


class FakeBackend:
    def __init__(self, model_id: str, dimensions: int) -> None:
        self.model_id = model_id
        self.dimensions = dimensions
        self.requests = []

    def call(self, request):
        self.requests.append(request)
        if request.get("method") == "index_status":
            return {
                "jsonrpc": "2.0",
                "id": request["id"],
                "result": {
                    "ready": True,
                    "embedding_model_id": self.model_id,
                    "vector_dimensions": self.dimensions,
                },
            }
        return {"jsonrpc": "2.0", "id": request["id"], "result": {"ok": True}}


class FailingQueryProvider(TinyProvider):
    def embed_queries(self, texts: list[str]) -> list[list[float]]:
        raise ProviderMismatch("provider inference stopped")


class ProviderTests(unittest.TestCase):
    def test_external_provider_indexes_documents_and_embeds_queries(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "target").mkdir()
            (root / "target" / "auto.md").write_text(
                "An automobile transports people.", encoding="utf-8"
            )
            (root / "target" / "physician.md").write_text(
                "A physician is a medical professional.", encoding="utf-8"
            )
            provider = TinyProvider()
            index = build_index(root, vector_mode="neural", embedding_provider=provider)
            results = search(
                index,
                "car",
                retrieval_mode="vector",
                path_prefix="target/",
                top_k=1,
                embedding_provider=provider,
            )
            lexical_without_provider = search(
                index, "automobile", retrieval_mode="lexical", top_k=1
            )

        self.assertEqual(index["embedding"]["model_id"], "tiny-neural-v1")
        self.assertEqual(results[0]["citation"]["path"], "target/auto.md")
        self.assertEqual(lexical_without_provider[0]["citation"]["path"], "target/auto.md")
        self.assertAlmostEqual(math.sqrt(sum(value * value for value in index["chunks"][0]["vector"])), 1.0)

    def test_query_provider_identity_must_match_index(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "one.md").write_text("An automobile is a vehicle.", encoding="utf-8")
            index = build_index(root, vector_mode="neural", embedding_provider=TinyProvider())

        with self.assertRaisesRegex(ProviderMismatch, "does not match"):
            embed_query(index, "car", TinyProvider("wrong-model"))

    def test_neural_mode_requires_provider(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "one.md").write_text("evidence", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "requires exactly one"):
                build_index(root, vector_mode="neural")

    def test_gateway_uses_external_query_provider(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "one.md").write_text("An automobile is a vehicle.", encoding="utf-8")
            provider = TinyProvider()
            index = build_index(root, vector_mode="neural", embedding_provider=provider)
        backend = FakeBackend("tiny-neural-v1", 2)
        gateway = EmbeddingGateway(index, backend, provider)
        gateway.handle(
            {
                "jsonrpc": "2.0",
                "id": 4,
                "method": "search_knowledge",
                "params": {"query": "car", "retrieval_mode": "vector"},
            }
        )

        self.assertEqual(backend.requests[-1]["params"]["query_vector"], [1.0, 0.0])

    def test_gateway_returns_structured_provider_runtime_error(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "one.md").write_text("An automobile is a vehicle.", encoding="utf-8")
            index = build_index(root, vector_mode="neural", embedding_provider=TinyProvider())
        backend = FakeBackend("tiny-neural-v1", 2)
        gateway = EmbeddingGateway(index, backend, FailingQueryProvider())
        request = {
            "jsonrpc": "2.0",
            "id": 9,
            "method": "search_knowledge",
            "params": {"query": "car", "retrieval_mode": "vector"},
        }
        output = io.StringIO()
        serve(gateway, io.StringIO(json.dumps(request) + "\n"), output)
        response = json.loads(output.getvalue())

        self.assertEqual(response["error"]["code"], -32010)
        self.assertIn("provider inference stopped", response["error"]["data"])


if __name__ == "__main__":
    unittest.main()

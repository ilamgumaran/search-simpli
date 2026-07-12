import tempfile
import unittest
import json
from pathlib import Path

from src.search_platform.core import build_index, load_index
from src.search_platform.embedding import embed_payload


class EmbeddingTests(unittest.TestCase):
    def test_query_uses_stored_cooccurrence_model(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "car.md").write_text("A car is a road vehicle with wheels.", encoding="utf-8")
            (root / "auto.md").write_text("An automobile is a road vehicle with wheels.", encoding="utf-8")
            index = build_index(root, vector_mode="cooccurrence")
            payload = embed_payload(index, "car")

        self.assertTrue(payload["model_id"].startswith("cooccurrence-ppmi-v1-sha256-"))
        self.assertEqual(payload["model_id"], index["embedding"]["model_id"])
        self.assertEqual(payload["dimensions"], index["embedding"]["dimensions"])
        self.assertTrue(any(payload["vector"]))

    def test_no_vector_index_returns_explicit_empty_embedding(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "one.md").write_text("lexical evidence", encoding="utf-8")
            payload = embed_payload(build_index(root), "evidence")

        self.assertEqual(payload, {"query": "evidence", "model_id": "none", "dimensions": 0, "vector": []})

    def test_trained_model_identity_is_deterministic_and_corpus_specific(self) -> None:
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            first_root = Path(first)
            second_root = Path(second)
            (first_root / "one.md").write_text("car road automobile wheels", encoding="utf-8")
            (second_root / "one.md").write_text("car clinic automobile doctor", encoding="utf-8")
            first_id = build_index(first_root, vector_mode="cooccurrence")["embedding"]["model_id"]
            first_repeat = build_index(first_root, vector_mode="cooccurrence")["embedding"]["model_id"]
            second_id = build_index(second_root, vector_mode="cooccurrence")["embedding"]["model_id"]

        self.assertEqual(first_id, first_repeat)
        self.assertNotEqual(first_id, second_id)

    def test_loading_a_legacy_family_only_index_derives_exact_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "one.md").write_text("car road automobile wheels", encoding="utf-8")
            index = build_index(root, vector_mode="cooccurrence")
            expected = index["embedding"]["model_id"]
            index["embedding"]["model_id"] = "cooccurrence-ppmi-v1"
            index["embedding"].pop("model_family")
            index["vector_model"]["model_id"] = "cooccurrence-ppmi-v1"
            index["vector_model"].pop("model_family")
            index_path = root / "legacy.json"
            index_path.write_text(json.dumps(index), encoding="utf-8")

            loaded = load_index(index_path)

        self.assertEqual(loaded["embedding"]["model_id"], expected)
        self.assertEqual(loaded["vector_model"]["model_id"], expected)


if __name__ == "__main__":
    unittest.main()

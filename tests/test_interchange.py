import tempfile
import unittest
from pathlib import Path

from src.search_platform.core import build_index
from src.search_platform.interchange import build_interchange


class InterchangeTests(unittest.TestCase):
    def test_exports_citations_vectors_and_model_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "car.md").write_text("A car is a road vehicle with wheels.", encoding="utf-8")
            (root / "auto.md").write_text("An automobile is a road vehicle with wheels.", encoding="utf-8")
            index = build_index(root, vector_mode="cooccurrence")
            payload = build_interchange(index, generation=7)

        self.assertEqual(payload["format_version"], 1)
        self.assertEqual(payload["generation"], 7)
        self.assertEqual(payload["analyzer_id"], "ascii-alnum-v1")
        self.assertEqual(payload["embedding_model_id"], index["embedding"]["model_id"])
        self.assertTrue(payload["embedding_model_id"].startswith("cooccurrence-ppmi-v1-sha256-"))
        self.assertEqual(len(payload["documents"]), 2)
        self.assertTrue(payload["documents"][0]["vector"])
        self.assertEqual(payload["documents"][0]["required_labels"], [])
        self.assertGreaterEqual(payload["documents"][0]["start_line"], 1)

    def test_no_vector_index_uses_explicit_none_model(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "one.md").write_text("lexical evidence", encoding="utf-8")
            payload = build_interchange(build_index(root), generation=1)

        self.assertEqual(payload["embedding_model_id"], "none")
        self.assertEqual(payload["documents"][0]["vector"], [])

    def test_generation_is_validated(self) -> None:
        with self.assertRaisesRegex(ValueError, "generation"):
            build_interchange({"chunks": [], "embedding": None}, generation=0)


if __name__ == "__main__":
    unittest.main()

import tempfile
import unittest
from pathlib import Path

from src.search_platform.core import build_index, context_envelope, search, tokenize


class SearchTests(unittest.TestCase):
    def test_tokenizer_is_case_insensitive_and_unicode_aware(self) -> None:
        self.assertEqual(tokenize("Zig, ZIG — café"), ["zig", "zig", "café"])

    def test_index_search_and_citation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "orchard.md").write_text("Apples grow in an orchard.\nPears grow there too.\n", encoding="utf-8")
            (root / "engine.md").write_text("An inverted index stores postings for lexical retrieval.\n", encoding="utf-8")
            index = build_index(root, vector_mode="none")
            results = search(index, "apple orchard", top_k=1)

        self.assertEqual(index["stats"]["files"], 2)
        self.assertEqual(results[0]["citation"]["path"], "orchard.md")
        self.assertEqual(results[0]["citation"]["start_line"], 1)
        self.assertIsNotNone(results[0]["ranking"]["lexical"]["rank"])

    def test_context_contract_and_path_filter(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "public").mkdir()
            (root / "private").mkdir()
            (root / "public" / "guide.md").write_text("Hybrid retrieval uses rank fusion.", encoding="utf-8")
            (root / "private" / "notes.md").write_text("Hybrid retrieval experiment notes.", encoding="utf-8")
            index = build_index(root)
            payload = context_envelope(index, "hybrid retrieval", path_prefix="public/")

        self.assertEqual(payload["tool"], "search_knowledge")
        self.assertTrue(payload["results"])
        self.assertTrue(all(item["citation"]["path"].startswith("public/") for item in payload["results"]))
        self.assertTrue(payload["answer_policy"]["ground_in_results"])

    def test_retrieval_modes_are_explicit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "guide.md").write_text("An inverted index stores lexical postings.", encoding="utf-8")
            index = build_index(root, vector_mode="hash")
            lexical = search(index, "inverted postings", retrieval_mode="lexical")
            vector = search(index, "inverted postings", retrieval_mode="vector")

        self.assertTrue(lexical)
        self.assertIsNotNone(lexical[0]["ranking"]["lexical"]["rank"])
        self.assertIsNone(lexical[0]["ranking"]["vector"]["rank"])
        self.assertTrue(vector)
        self.assertIsNone(vector[0]["ranking"]["lexical"]["rank"])
        self.assertIsNotNone(vector[0]["ranking"]["vector"]["rank"])

        with self.assertRaisesRegex(ValueError, "retrieval_mode"):
            search(index, "postings", retrieval_mode="unknown")
        with self.assertRaisesRegex(ValueError, "candidate_k"):
            search(index, "postings", top_k=2, candidate_k=1)

    def test_cooccurrence_vectors_cross_a_vocabulary_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "training").mkdir()
            (root / "target").mkdir()
            (root / "unrelated").mkdir()
            (root / "training" / "car.md").write_text(
                "A car is a vehicle with wheels and an engine used on a road.", encoding="utf-8"
            )
            (root / "target" / "automobile.md").write_text(
                "An automobile is a vehicle with wheels and an engine used on a road.", encoding="utf-8"
            )
            (root / "unrelated" / "fruit.md").write_text(
                "An apple is a fruit that grows in an orchard on a tree.", encoding="utf-8"
            )
            index = build_index(root, vector_mode="cooccurrence")
            lexical = search(
                index, "car", path_prefix="target/", retrieval_mode="lexical", top_k=1
            )
            semantic = search(
                index, "car", path_prefix="target/", retrieval_mode="vector", top_k=1
            )

        self.assertEqual(lexical, [])
        self.assertEqual(semantic[0]["citation"]["path"], "target/automobile.md")
        self.assertGreater(semantic[0]["ranking"]["vector"]["score"], 0)
        self.assertEqual(index["vector_model"]["type"], "cooccurrence_ppmi")
        self.assertEqual(index["embedding"]["model_family"], "cooccurrence-ppmi-v1")
        self.assertTrue(index["embedding"]["model_id"].startswith("cooccurrence-ppmi-v1-sha256-"))
        self.assertTrue(index["embedding"]["semantic"])


if __name__ == "__main__":
    unittest.main()

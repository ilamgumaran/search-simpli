import tempfile
import unittest
from pathlib import Path

from src.search_platform.core import build_index
from src.search_platform.evaluation import (
    evaluate_modes,
    normalized_dcg,
    validate_suite,
)


class EvaluationTests(unittest.TestCase):
    def test_judged_metrics_for_lexical_retrieval(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "engine.md").write_text("An inverted index stores lexical postings.", encoding="utf-8")
            (root / "agent.md").write_text("An agent cites retrieved evidence.", encoding="utf-8")
            index = build_index(root, vector_mode="none")
            suite = {
                "version": 1,
                "queries": [
                    {
                        "id": "postings",
                        "query": "inverted lexical postings",
                        "relevant": [{"path": "engine.md"}],
                    },
                    {
                        "id": "citations",
                        "query": "agent cited evidence",
                        "relevant": [{"path": "agent.md"}],
                    },
                ],
            }
            report = evaluate_modes(index, suite, ["lexical"], top_k=1)["reports"][0]

        self.assertEqual(report["macro_recall_at_k"], 1.0)
        self.assertEqual(report["success_at_k"], 1.0)
        self.assertEqual(report["mean_reciprocal_rank"], 1.0)

    def test_hash_vector_evaluation_is_labeled(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "one.md").write_text("hybrid retrieval", encoding="utf-8")
            index = build_index(root, vector_mode="hash")
            suite = {
                "version": 1,
                "queries": [{"id": "one", "query": "hybrid", "relevant": [{"path": "one.md"}]}],
            }
            report = evaluate_modes(index, suite, ["vector", "hybrid"], top_k=1)

        self.assertEqual(len(report["warnings"]), 1)
        self.assertIn("does not measure semantic meaning", report["warnings"][0])

    def test_suite_validation_rejects_duplicate_ids(self) -> None:
        suite = {
            "version": 1,
            "queries": [
                {"id": "same", "query": "one", "relevant": [{"path": "one.md"}]},
                {"id": "same", "query": "two", "relevant": [{"path": "two.md"}]},
            ],
        }
        with self.assertRaisesRegex(ValueError, "duplicate query id"):
            validate_suite(suite)

    def test_cooccurrence_evaluation_is_labeled_as_a_baseline(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "one.md").write_text("a car is a road vehicle", encoding="utf-8")
            (root / "two.md").write_text("an automobile is a road vehicle", encoding="utf-8")
            index = build_index(root, vector_mode="cooccurrence")
            suite = {
                "version": 1,
                "queries": [{"id": "one", "query": "car", "relevant": [{"path": "two.md"}]}],
            }
            report = evaluate_modes(index, suite, ["vector"], top_k=2)

        self.assertIn("not a modern neural embedding model", report["warnings"][0])

    def test_graded_ndcg_rewards_ideal_early_ordering(self) -> None:
        ideal = normalized_dcg([3, 2, 1], [3, 2, 1], 3)
        swapped = normalized_dcg([2, 3, 1], [3, 2, 1], 3)

        self.assertEqual(ideal, 1.0)
        self.assertGreater(swapped, 0.0)
        self.assertLess(swapped, ideal)

    def test_duplicate_chunks_from_one_relevant_path_gain_only_once(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "product.md").write_text(
                ("bronze reading lamp " * 100) + "\n" + ("bronze reading lamp " * 100),
                encoding="utf-8",
            )
            index = build_index(root, vector_mode="none")
            suite = {
                "version": 2,
                "queries": [
                    {
                        "id": "lamp",
                        "query": "bronze reading lamp",
                        "relevant": [{"path": "product.md", "grade": 3}],
                    }
                ],
            }
            report = evaluate_modes(index, suite, ["lexical"], top_k=2)["reports"][0]

        self.assertEqual(report["queries"][0]["returned_relevance_grades"], [3, 0])
        self.assertEqual(report["mean_ndcg_at_k"], 1.0)

    def test_version_two_requires_bounded_integer_grades(self) -> None:
        suite = {
            "version": 2,
            "queries": [
                {"id": "one", "query": "lamp", "relevant": [{"path": "one.md"}]}
            ],
        }
        with self.assertRaisesRegex(ValueError, "grade must be an integer from 1 to 3"):
            validate_suite(suite)

    def test_duplicate_judgments_are_rejected(self) -> None:
        suite = {
            "version": 2,
            "queries": [
                {
                    "id": "one",
                    "query": "lamp",
                    "relevant": [
                        {"path": "one.md", "grade": 3},
                        {"path": "one.md", "grade": 1},
                    ],
                }
            ],
        }
        with self.assertRaisesRegex(ValueError, "duplicate judgment"):
            validate_suite(suite)


if __name__ == "__main__":
    unittest.main()

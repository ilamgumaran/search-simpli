import unittest
import tempfile
from pathlib import Path

from relevance_smoke import gate_failures, run_smoke


def _report(ndcg=0.8, mrr=0.7, recall=0.6, success=0.9):
    return {
        "profile_id": "same-profile",
        "evaluation": {
            "reports": [
                {
                    "mode": "lexical",
                    "mean_ndcg_at_k": ndcg,
                    "mean_reciprocal_rank": mrr,
                    "macro_recall_at_k": recall,
                    "success_at_k": success,
                }
            ]
        },
    }


class RelevanceSmokeTests(unittest.TestCase):
    def test_minimum_gate_reports_metric_and_mode(self):
        failures = gate_failures(_report(ndcg=0.79), {"ndcg": 0.8})

        self.assertEqual(len(failures), 1)
        self.assertIn("lexical mean_ndcg_at_k", failures[0])

    def test_matching_baseline_allows_bounded_absolute_regression(self):
        failures = gate_failures(
            _report(ndcg=0.79),
            {},
            baseline=_report(ndcg=0.8),
            max_regression=0.01,
        )

        self.assertEqual(failures, [])

    def test_baseline_profile_must_match(self):
        baseline = _report()
        baseline["profile_id"] = "different-profile"

        with self.assertRaisesRegex(ValueError, "profile_id"):
            gate_failures(_report(), {}, baseline=baseline)

    def test_saved_index_can_be_reused_for_the_same_profile(self):
        root = Path(__file__).resolve().parents[1]
        corpus = root / "fixtures" / "relevance-smoke" / "corpus"
        suite = root / "fixtures" / "relevance-smoke" / "judgments.json"
        with tempfile.TemporaryDirectory() as temporary:
            index_path = Path(temporary) / "index.json"
            built = run_smoke(
                corpus,
                suite,
                modes=["lexical"],
                vector_mode="none",
                top_k=10,
                minima={},
                save_index_path=index_path,
            )
            reused = run_smoke(
                corpus,
                suite,
                modes=["lexical"],
                vector_mode="none",
                top_k=10,
                minima={},
                index_path=index_path,
            )

        self.assertEqual(built["profile_id"], reused["profile_id"])
        self.assertEqual(built["evaluation"]["reports"], reused["evaluation"]["reports"])
        self.assertEqual(built["index_source"], "built")
        self.assertEqual(reused["index_source"], "prebuilt")


if __name__ == "__main__":
    unittest.main()

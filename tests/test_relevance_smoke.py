import unittest
import tempfile
import contextlib
import io
import json
import subprocess
import sys
from pathlib import Path
from unittest.mock import patch

from relevance_smoke import gate_failures, run_smoke, main


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
    def test_pack_cli_top_one_changes_report_and_exit_status(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "report.json"
            result = subprocess.run(
                [sys.executable, str(root / "scripts/relevance_smoke.py"),
                 "--pack", "family-folder", "--top-k", "1", "--output", str(output)],
                cwd=root, text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 1, result.stderr)
            report = json.loads(output.read_text())
            self.assertEqual(report["top_k"], 1)
            self.assertLess(report["words_recall_at_k"], 0.9)
            self.assertFalse(report["gate"]["passed"])
            self.assertIn("words recall@1", result.stdout)

    def test_pack_cli_keeps_default_five(self):
        with patch("relevance_smoke.run_pack", return_value={"gate": {"passed": True}}) as run:
            with patch("relevance_smoke.print_pack_report"):
                self.assertEqual(main(["--pack", "family-folder"]), 0)
        run.assert_called_once_with("family-folder", top_k=5)

    def test_pack_rejects_unsupported_or_invalid_options_before_running(self):
        for options in (["--mode", "vector"], ["--min-recall=1"],
                        ["--vector-mode", "none"], ["--index", "missing.json"],
                        ["--baseline", "missing.json"], ["--max-regression", "0"],
                        ["--top-k", "0"], ["--top-k", "-1"]):
            with self.subTest(options=options), patch("relevance_smoke.run_pack") as run:
                with contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as raised:
                        main(["--pack", "family-folder", *options])
                self.assertEqual(raised.exception.code, 2)
                run.assert_not_called()

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

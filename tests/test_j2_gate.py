"""S5-T1: the J2 gate's rules on synthetic runs, and the Python reference
against the committed baseline."""

from __future__ import annotations

import copy
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from relevance_smoke import run_j2_pack  # noqa: E402

_spec = importlib.util.spec_from_file_location("j2_gate", REPO / "scripts" / "j2_gate.py")
j2_gate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(j2_gate)

SHA = "0" * 64
SLICE = {"n": 3, "success_at_1": 0.5, "mrr_at_10": 0.5, "ndcg_at_10": 0.5, "recall_at_5": 0.5}
RANKS = {"c1": 1, "m1": 2, "m2": 8, "m3": None}
SLICE_OF = {"c1": "control", "m1": "misspelling", "m2": "misspelling", "m3": "misspelling", "n1": "negatives"}
NEGATIVE = {"returned": 2, "top_hit": {"root_id": "home", "path": "a.md", "start_line": 1, "end_line": 2},
            "top_hit_grade": 0, "top_is_named_distractor": True}


def baseline() -> dict:
    run = {"slices": {"control": dict(SLICE), "misspelling": dict(SLICE)}, "overall": dict(SLICE),
           "first_grade2_rank": dict(RANKS), "slice_of": dict(SLICE_OF), "negatives": {"n1": dict(NEGATIVE)}}
    return {"schema": "j2-baseline-v1", "judgments_sha256": SHA, "engine_commit": "6ef4c3b", "recorded": "2026-11-06",
            "surfaces": {"python-reference": {"runs": {"content": copy.deepcopy(run), "both": copy.deepcopy(run)}}}}


def honest_run() -> dict:
    def variant() -> dict:
        queries = {qid: {"slice": SLICE_OF[qid], "first_grade2_rank": rank} for qid, rank in RANKS.items()}
        queries["n1"] = {"slice": "negatives"}
        return {"slices": {"control": dict(SLICE), "misspelling": dict(SLICE)}, "overall": dict(SLICE),
                "queries": queries, "negatives": {"n1": dict(NEGATIVE)}}
    return {"schema": "j2-results-v1", "surface": "python-reference", "judgments_sha256": SHA,
            "runs": {"content": variant(), "both": variant()}}


class GateRuleTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.dir = Path(self.scratch.name)

    def tearDown(self):
        self.scratch.cleanup()

    def gate(self, run: dict, base: dict | None = None, allow: list[str] | None = None) -> tuple[int, str]:
        (self.dir / "run.json").write_text(json.dumps(run))
        (self.dir / "base.json").write_text(json.dumps(base or baseline()))
        argv = [str(self.dir / "run.json"), "--baseline", str(self.dir / "base.json")]
        if allow is not None:
            (self.dir / "allow.json").write_text(json.dumps(
                {"task": "S5-Tx", "queries": [{"id": q, "why": "moved on purpose"} for q in allow]}))
            argv += ["--allow", str(self.dir / "allow.json")]
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = j2_gate.main(argv)
        return code, out.getvalue() + err.getvalue()

    def with_rank(self, qid: str, rank, variant: str = "content") -> dict:
        run = honest_run()
        run["runs"][variant]["queries"][qid]["first_grade2_rank"] = rank
        return run

    def test_honest_run_passes(self):
        code, out = self.gate(honest_run())
        self.assertEqual(code, 0, out)
        self.assertIn("J2 gate: pass", out)

    def test_mrr_drop_limit(self):
        for drop, expected in ((0.021, 1), (0.019, 0)):
            run = honest_run()
            run["runs"]["both"]["slices"]["misspelling"]["mrr_at_10"] = 0.5 - drop
            code, out = self.gate(run)
            self.assertEqual(code, expected, (drop, out))

    def test_raised_baseline_fails_an_honest_run(self):
        base = baseline()
        base["surfaces"]["python-reference"]["runs"]["content"]["slices"]["misspelling"]["mrr_at_10"] += 0.05
        code, out = self.gate(honest_run(), base)
        self.assertEqual(code, 1, out)
        self.assertIn("(a) slice misspelling", out)

    def test_control_rank_one_loss_fails_even_when_allowed(self):
        code, out = self.gate(self.with_rank("c1", 2), allow=["c1"])
        self.assertEqual(code, 1, out)
        self.assertIn("(b) control c1", out)
        code, _ = self.gate(self.with_rank("c1", None, "both"))
        self.assertEqual(code, 1)

    def test_rank_worsening(self):
        self.assertEqual(self.gate(self.with_rank("m1", 6))[0], 1)
        self.assertEqual(self.gate(self.with_rank("m1", 5))[0], 0)
        self.assertEqual(self.gate(self.with_rank("m1", 6), allow=["m1"])[0], 0)
        self.assertEqual(self.gate(self.with_rank("m1", 6), allow=["m2"])[0], 1)

    def test_not_found_counts_as_eleven(self):
        self.assertEqual(self.gate(self.with_rank("m1", None))[0], 1)
        self.assertEqual(self.gate(self.with_rank("m2", None))[0], 0)
        self.assertEqual(self.gate(self.with_rank("m3", 9))[0], 0)

    def test_negatives_are_information(self):
        run = honest_run()
        run["runs"]["content"]["negatives"]["n1"] = {"returned": 0, "top_hit": None, "top_hit_grade": None,
                                                     "top_is_named_distractor": None}
        code, out = self.gate(run)
        self.assertEqual(code, 0, out)
        self.assertIn("negative n1 (information)", out)

    def test_usage_errors_exit_two(self):
        run = honest_run()
        run["judgments_sha256"] = "1" * 64
        self.assertEqual(self.gate(run)[0], 2)
        run = honest_run()
        run["surface"] = "searchd"
        self.assertEqual(self.gate(run)[0], 2)
        run = honest_run()
        del run["runs"]["both"]
        self.assertEqual(self.gate(run)[0], 2)
        run = honest_run()
        del run["runs"]["content"]["queries"]["m2"]
        self.assertEqual(self.gate(run)[0], 2)
        with redirect_stderr(io.StringIO()):
            self.assertEqual(j2_gate.main([str(self.dir / "missing.json")]), 2)


    def test_annotate_names_each_failure(self):
        """S5-T6 ruling 6: --annotate prints each failure as a workflow annotation."""
        (self.dir / "run.json").write_text(json.dumps(self.with_rank("c1", 2)))
        (self.dir / "base.json").write_text(json.dumps(baseline()))
        out = io.StringIO()
        with redirect_stdout(out), redirect_stderr(io.StringIO()):
            code = j2_gate.main([str(self.dir / "run.json"), "--baseline", str(self.dir / "base.json"), "--annotate"])
        self.assertEqual(code, 1)
        lines = [line for line in out.getvalue().splitlines() if line.startswith("::")]
        self.assertEqual(lines, ["::error title=J2 gate python-reference content::(b) control c1 lost rank 1 (now 2)"])
        code, out = self.gate(self.with_rank("c1", 2))
        self.assertNotIn("::error", out)


_native_spec = importlib.util.spec_from_file_location("ci_j2_native", REPO / "scripts" / "ci_j2_native.py")
ci_j2_native = importlib.util.module_from_spec(_native_spec)
_native_spec.loader.exec_module(ci_j2_native)


class PythonReferenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.results = run_j2_pack()

    def gate_file(self, results: dict) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "j2.json"
            path.write_text(json.dumps(results, ensure_ascii=False))
            out = io.StringIO()
            with redirect_stdout(out):
                code = j2_gate.main([str(path)])
        return code, out.getvalue()

    def test_reference_report_names_its_policies(self):
        """S5-T6 (review R02): the reference's report names its source and policy ids."""
        engine = self.results["engine"]
        self.assertTrue(engine["commit"])
        self.assertEqual(engine["policies"]["fold_policy_id"], "fold-groups-v3")
        self.assertEqual(engine["policies"]["chunkers"], ["line-window-v1", "md-section-v1"])

    def test_planted_regression_fails_the_gate(self):
        """S5-T6 ruling 5, on the reference's run (CI does the same on the native run):
        the unchanged lists scored again reproduce the run, and the planted run fails."""
        planted = ci_j2_native.plant(self.results)
        self.assertNotEqual(planted["runs"], self.results["runs"])
        code, out = self.gate_file(planted)
        self.assertEqual(code, 1, out)
        self.assertIn("(b) control c01 lost rank 1", out)
        self.assertIn("(a) slice control", out)
        tampered = copy.deepcopy(self.results)
        tampered["runs"]["content"]["queries"]["c01"]["first_grade2_rank"] = 5
        with self.assertRaises(ci_j2_native.Usage):
            ci_j2_native.plant(tampered)

    def test_differences_lists_a_moved_row(self):
        # The baseline's searchd cells replaced by this run's own: no row differs, then one.
        base = json.loads((REPO / "fixtures" / "j2" / "baseline.json").read_text(encoding="utf-8"))
        base["surfaces"]["searchd"]["runs"] = {
            variant: {"slices": run["slices"], "negatives": run["negatives"],
                      "first_grade2_rank": {q: r["first_grade2_rank"] for q, r in run["queries"].items()
                                            if "first_grade2_rank" in r}}
            for variant, run in self.results["runs"].items()}
        moved = copy.deepcopy(self.results)
        rows = ci_j2_native.differences(moved, base)
        self.assertEqual(rows, [])
        record = moved["runs"]["both"]["queries"]["m13"]
        record["first_grade2_rank"] = 2
        rows = ci_j2_native.differences(moved, base)
        self.assertEqual([title for title, _ in rows], ["J2 x86_64 vs baseline: both m13"])

    def test_python_reference_passes_the_committed_baseline(self):
        results = self.results
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "j2.json"
            path.write_text(json.dumps(results, ensure_ascii=False))
            out = io.StringIO()
            with redirect_stdout(out):
                code = j2_gate.main([str(path)])
        self.assertEqual(code, 0, out.getvalue())
        base = json.loads((REPO / "fixtures" / "j2" / "baseline.json").read_text(encoding="utf-8"))
        ranks = base["surfaces"]["python-reference"]["runs"]["content"]["first_grade2_rank"]
        self.assertTrue(all(ranks[q] == 1 for q, s in base["surfaces"]["python-reference"]["runs"]["content"]["slice_of"].items()
                            if s == "control"))


if __name__ == "__main__":
    unittest.main()

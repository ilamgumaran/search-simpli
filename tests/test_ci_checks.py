"""S5-T6: the CI checks' own logic, on synthetic input: workflow annotations
(scripts/ci_annotations.py) and the Unicode 13 golden job's judgement
(scripts/ci_unicode_goldens.py). The checks themselves run in CI."""

from __future__ import annotations

import io
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

import ci_annotations  # noqa: E402
import ci_unicode_goldens  # noqa: E402


class AnnotationTests(unittest.TestCase):
    def test_escaping(self):
        line = ci_annotations.line("error", "stale: a,b:c", "50% done\nnext line\r")
        self.assertEqual(line, "::error title=stale%3A a%2Cb%3Ac::50%25 done%0Anext line%0D")

    def test_unknown_level_is_refused(self):
        with self.assertRaises(ValueError):
            ci_annotations.line("debug", "t", "m")

    def test_bound_keeps_limit_lines_and_names_the_rest(self):
        notes = ci_annotations.Annotations(limit=30)
        for i in range(45):
            notes.add("warning" if i < 40 else "error", f"row {i}", "m")
        lines = notes.lines()
        self.assertEqual(len(lines), 30)
        self.assertTrue(lines[28].startswith("::warning title=row 28::"))
        self.assertTrue(lines[29].startswith("::error title=16 more not annotated::"), lines[29])
        out = io.StringIO()
        notes.flush(out)
        self.assertEqual(out.getvalue().count("\n"), 30)
        self.assertEqual(notes.items, [])

    def test_under_the_bound_everything_is_kept(self):
        notes = ci_annotations.Annotations(limit=3)
        for i in range(3):
            notes.add("notice", f"row {i}", "m")
        self.assertEqual(len(notes.lines()), 3)
        self.assertNotIn("more not annotated", "".join(notes.lines()))


class UnicodeGoldenJudgementTests(unittest.TestCase):
    EXPECTED = {
        "tests.m.A.test_one": ("fixtures/one.json", ["scripts/gen_one.py"]),
        "tests.m.A.test_guard": ("src/table.py", None),
    }

    def judge(self, ran, skipped=None, failed=None):
        notes = ci_annotations.Annotations()
        problems = ci_unicode_goldens.judge(ran, skipped or {}, failed or {}, self.EXPECTED, notes,
                                            describe=lambda path, gen: f"{path} differs (fake)")
        return problems, notes.lines()

    def test_all_ran_and_passed(self):
        self.assertEqual(self.judge(["tests.m.A.test_one", "tests.m.A.test_guard", "tests.m.B.other"]), (0, []))

    def test_a_missing_check_fails(self):
        problems, lines = self.judge(["tests.m.A.test_one"])
        self.assertEqual(problems, 1)
        self.assertIn("golden check missing%3A src/table.py", lines[0])

    def test_any_skip_fails_expected_or_not(self):
        ran = ["tests.m.A.test_one", "tests.m.A.test_guard", "tests.m.B.other"]
        problems, lines = self.judge(ran, skipped={"tests.m.A.test_one": "Unicode 14.0.0",
                                                   "tests.m.B.other": "no reason"})
        self.assertEqual(problems, 2)
        self.assertIn("golden check skipped%3A fixtures/one.json", lines[0])
        self.assertIn("golden check skipped%3A other", lines[1])

    def test_a_stale_file_is_named_with_its_difference(self):
        ran = ["tests.m.A.test_one", "tests.m.A.test_guard"]
        problems, lines = self.judge(ran, failed={"tests.m.A.test_one": "Traceback\nAssertionError: x"})
        self.assertEqual(problems, 1)
        self.assertTrue(lines[0].startswith("::error title=stale%3A fixtures/one.json::"), lines[0])
        self.assertIn("fixtures/one.json differs (fake)", lines[0])
        problems, lines = self.judge(ran, failed={"tests.m.A.test_guard": "Traceback\nAssertionError: sets differ"})
        self.assertIn("src/table.py: AssertionError: sets differ", lines[0])

    def test_first_differences(self):
        rows = ci_unicode_goldens.first_differences("a\nb\nc\n", "a\nB\nc\nd\n")
        self.assertEqual(rows, ["line 2: committed b | fresh B", "after line 3: committed (none) | fresh d"])
        self.assertEqual(ci_unicode_goldens.first_differences("a\n", "a"),
                         ["the texts differ only in line endings or the final newline"])

    def test_every_expected_check_exists(self):
        """A renamed test would make the job fail; this keeps the list honest locally too."""
        import unittest as ut
        loaded = set()

        def walk(suite):
            for item in suite:
                if isinstance(item, ut.TestSuite):
                    walk(item)
                else:
                    loaded.add(item.id())
        walk(ut.defaultTestLoader.loadTestsFromNames(ci_unicode_goldens.MODULES))
        self.assertEqual(set(ci_unicode_goldens.EXPECTED) - loaded, set())
        for path, generator in ci_unicode_goldens.EXPECTED.values():
            self.assertTrue((REPO / path).is_file(), path)
            if generator:
                self.assertTrue((REPO / generator[0]).is_file(), generator[0])


if __name__ == "__main__":
    unittest.main()

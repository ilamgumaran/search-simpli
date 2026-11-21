"""S6-T15 rework: each step's total from a real `zig build test --summary all` against the
layer checker's listing (scripts/check_test_counts.py).

The Build Summary shapes below are copied from Zig 0.16.0 runs of this repository
(docs/evidence/s6-t15/), the summary's tree cut to its step lines: Debug, ReleaseSmall
(fastmem compiled ReleaseFast), and a run with a failing test, whose error tree
before the summary repeats a step line."""

from __future__ import annotations

import io
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

import check_test_counts  # noqa: E402

DEBUG = """\
+- run test core w
S5-T3 fuzzy golden: 4848 chunk scores in 120 expanded queries (9 planted cases) within 1e-4
Build Summary: 15/15 steps succeeded; 579/588 tests passed (9 skipped)
test success
+- run test core 253 pass (253 total) 35s MaxRSS:412M
|  +- compile test core Debug native success 4s MaxRSS:826M
+- run test operations 10 pass (10 total) 217ms MaxRSS:7M
|  +- compile test operations Debug native success 2s MaxRSS:600M
+- run test interfaces 26 pass (26 total) 292ms MaxRSS:10M
|  +- compile test interfaces Debug native success 3s MaxRSS:678M
+- run test tests 284 pass, 9 skip (293 total) 1m MaxRSS:644M
|  +- compile test tests Debug native success 5s MaxRSS:1G
+- run test 6 pass (6 total) 962ms MaxRSS:5M
   +- compile test Debug native success 3s MaxRSS:563M
"""

RELEASE_SMALL = """\
Build Summary: 15/15 steps succeeded; 579/588 tests passed (9 skipped)
test success
+- run test core 253 pass (253 total) 18s MaxRSS:35M
|  +- compile test core ReleaseSmall native success 20s MaxRSS:723M
+- run test operations 10 pass (10 total) 182ms MaxRSS:3M
|  +- compile test operations ReleaseSmall native success 7s MaxRSS:496M
+- run test interfaces 26 pass (26 total) 975ms MaxRSS:5M
|  +- compile test interfaces ReleaseSmall native success 13s MaxRSS:574M
+- run test tests 284 pass, 9 skip (293 total) 1m MaxRSS:402M
|  +- compile test tests ReleaseSmall native success 34s MaxRSS:879M
+- run test 6 pass (6 total) 299ms MaxRSS:4M
   +- compile test ReleaseFast native success 2s MaxRSS:232M
"""

FAILED = """\
test
+- run test core 253 pass, 1 fail (254 total)
error: 'plant_module_test.test.plant named: a failing test' failed:
Build Summary: 13/15 steps succeeded (1 failed); 579/589 tests passed (9 skipped, 1 failed)
test transitive failure
+- run test core 253 pass, 1 fail (254 total)
|  +- compile test core Debug native success 4s MaxRSS:816M
+- run test operations 10 pass (10 total) 247ms MaxRSS:7M
+- run test interfaces 26 pass (26 total) 434ms MaxRSS:10M
+- run test tests 284 pass, 9 skip (293 total) 2m MaxRSS:644M
+- run test 6 pass (6 total) 1s MaxRSS:5M
"""

EXPECTED = {"core": ("core", 253), "operations": ("operations", 10), "interfaces": ("interfaces", 26),
            "tests": ("tests", 293), "": ("fastmem", 6)}


class ParseTests(unittest.TestCase):
    def test_debug(self):
        steps, problems = check_test_counts.parse_summary(DEBUG)
        self.assertEqual(problems, [])
        self.assertEqual({k: v["total"] for k, v in steps.items()},
                         {"core": 253, "operations": 10, "interfaces": 26, "tests": 293, "": 6})

    def test_release_small(self):
        steps, problems = check_test_counts.parse_summary(RELEASE_SMALL)
        self.assertEqual(problems, [])
        self.assertEqual(steps["tests"]["total"], 293)
        self.assertEqual(steps[""]["total"], 6)

    def test_the_skipped_count_is_read_and_is_part_of_the_total(self):
        steps, _ = check_test_counts.parse_summary(DEBUG)
        self.assertEqual((steps["tests"]["pass"], steps["tests"]["skip"], steps["tests"]["total"]), (284, 9, 293))
        rows, problems = check_test_counts.compare(EXPECTED, steps)
        self.assertEqual(problems, [])
        self.assertIn(("tests", "run test tests", 293, "293 (284 pass, 9 skip)", "ok"), rows)

    def test_a_failed_test_is_counted_and_the_lines_before_the_summary_are_ignored(self):
        steps, problems = check_test_counts.parse_summary(FAILED)
        self.assertEqual(problems, [])
        self.assertEqual((steps["core"]["pass"], steps["core"]["fail"], steps["core"]["total"]), (253, 1, 254))

    def test_no_summary_fails(self):
        steps, problems = check_test_counts.parse_summary("error: something\n")
        self.assertEqual(steps, {})
        self.assertIn("no `Build Summary:` line", problems[0])

    def test_a_step_with_no_total_is_reported(self):
        text = DEBUG.replace("+- run test core 253 pass (253 total) 35s MaxRSS:412M", "+- run test core transitive failure")
        steps, _ = check_test_counts.parse_summary(text)
        self.assertIsNone(steps["core"]["total"])
        _, problems = check_test_counts.compare(EXPECTED, steps)
        self.assertEqual(problems, ["step 'core' (`run test core`): the run reports no total "
                                    "(+- run test core transitive failure)"])


class CompareTests(unittest.TestCase):
    def steps(self, text=DEBUG):
        return check_test_counts.parse_summary(text)[0]

    def test_equal_totals_pass(self):
        self.assertEqual(check_test_counts.compare(EXPECTED, self.steps())[1], [])
        self.assertEqual(check_test_counts.compare(EXPECTED, self.steps(RELEASE_SMALL))[1], [])

    def test_a_differing_total_fails(self):
        # The Verdict's plant A: the listing counted a test Zig did not run.
        expected = dict(EXPECTED, tests=("tests", 294))
        _, problems = check_test_counts.compare(expected, self.steps())
        self.assertEqual(problems, ["step 'tests' (`run test tests`): the listing has 294 tests, the run 293 "
                                    "(284 pass, 9 skip)"])
        _, problems = check_test_counts.compare(EXPECTED, self.steps(FAILED))
        self.assertEqual(problems, ["step 'core' (`run test core`): the listing has 253 tests, the run 254 "
                                    "(253 pass, 1 fail)"])

    def test_a_missing_step_fails(self):
        # The Verdict's first edit: the core row of test_roots deleted.
        text = "\n".join(line for line in DEBUG.splitlines() if "test core" not in line)
        _, problems = check_test_counts.compare(EXPECTED, self.steps(text))
        self.assertEqual(problems, ["step 'core' (`run test core`): the listing has 253 tests, and the run has no "
                                    "such step"])
        text = "\n".join(line for line in DEBUG.splitlines() if not line.startswith("+- run test 6"))
        _, problems = check_test_counts.compare(EXPECTED, self.steps(text))
        self.assertEqual(problems, ["step 'fastmem' (`run test`): the listing has 6 tests, and the run has no "
                                    "such step"])

    def test_an_extra_step_fails(self):
        text = DEBUG + "+- run test extra 1 pass (1 total) 1ms MaxRSS:1M\n"
        _, problems = check_test_counts.compare(EXPECTED, self.steps(text))
        self.assertEqual(problems, ["the run has the step `run test extra` (+- run test extra 1 pass (1 total) 1ms "
                                    "MaxRSS:1M), which the listing lacks"])

    def test_a_step_shown_twice_is_reported(self):
        text = DEBUG + "+- run test core 253 pass (253 total)\n"
        _, problems = check_test_counts.parse_summary(text)
        self.assertEqual(problems, ["the Build Summary shows `run test core` twice"])


class RepositoryTests(unittest.TestCase):
    def test_the_listing_of_the_repository_has_the_five_steps(self):
        expected, problems = check_test_counts.listing(REPO)
        self.assertEqual(problems, [])
        self.assertEqual(sorted((label, step) for label, (step, _) in expected.items()),
                         [("", "fastmem"), ("core", "core"), ("interfaces", "interfaces"),
                          ("operations", "operations"), ("tests", "tests")])

    def test_the_listing_does_not_follow_the_build_file(self):
        # The Verdict's first edit, the core row deleted: the listing still has the step
        # (BUILD_ROOTS'), so a run without it fails the comparison on its own.
        import shutil
        with tempfile.TemporaryDirectory() as tmp:
            copy = Path(tmp)
            shutil.copytree(REPO / "zig" / "src", copy / "zig" / "src")
            (copy / "docs").mkdir()
            shutil.copy(REPO / "docs" / "layers.md", copy / "docs" / "layers.md")
            row = '        .{ .name = "core", .path = "src/core/core.zig" },\n'
            build = (REPO / "zig" / "build.zig").read_text(encoding="utf-8")
            self.assertEqual(build.count(row), 1)
            (copy / "zig" / "build.zig").write_text(build.replace(row, ""), encoding="utf-8")
            expected, static = check_test_counts.listing(copy)
            self.assertIn("core", expected)
            self.assertTrue(static)  # the static checker fails it too, on its own
            text = "\n".join(line for line in DEBUG.splitlines() if "test core" not in line)
            ran = check_test_counts.parse_summary(text)[0]
            _, problems = check_test_counts.compare(expected, ran)
            self.assertTrue(any("'core'" in p and "the run has no such step" in p for p in problems), problems)

    def test_a_static_problem_fails_the_script_unless_counts_only(self):
        # The second Verdict's finding 2: equal totals while the static checker sees a loss
        # (here a test file named nowhere, so the listing drops it too) must not pass.
        import shutil
        with tempfile.TemporaryDirectory() as tmp:
            copy = Path(tmp)
            shutil.copytree(REPO / "zig", copy / "zig", ignore=shutil.ignore_patterns(".zig-cache", "zig-out"))
            (copy / "docs").mkdir()
            shutil.copy(REPO / "docs" / "layers.md", copy / "docs" / "layers.md")
            (copy / "zig" / "src" / "tests" / "lost_test.zig").write_text('test "lost" {}\n', encoding="utf-8")
            expected, static = check_test_counts.listing(copy)
            self.assertTrue(any("lost_test.zig" in p for p in static), static)
            log = copy / "run.txt"
            log.write_text("\n".join(["Build Summary: ok", "test success"] + [
                f"+- run test {label} {count} pass ({count} total)".replace("test  ", "test ")
                for label, (_, count) in expected.items()]) + "\n", encoding="utf-8")
            outputs = {}
            for extra, want in (([], 1), (["--counts-only"], 0)):
                out = io.StringIO()
                with redirect_stdout(out):
                    code = check_test_counts.main(["--root", str(copy), "--log", str(log), *extra])
                self.assertEqual(code, want, out.getvalue())
                outputs[want] = out.getvalue()
            self.assertIn("check_test_counts: static: zig/src/tests/lost_test.zig:1:", outputs[1])
            self.assertIn("not judged here (--counts-only)", outputs[0])

    def test_main_against_a_log_of_the_listing_passes_and_one_test_more_fails(self):
        expected, _ = check_test_counts.listing(REPO)
        lines = ["Build Summary: ok", "test success"]
        for label, (_, count) in expected.items():
            lines.append(f"+- run test {label} {count} pass ({count} total) 1s".replace("test  ", "test "))
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "run.txt"
            log.write_text("\n".join(lines) + "\n", encoding="utf-8")
            out = io.StringIO()
            with redirect_stdout(out):
                code = check_test_counts.main(["--root", str(REPO), "--log", str(log)])
            self.assertEqual(code, 0, out.getvalue())
            self.assertIn("check_test_counts: OK", out.getvalue())
            count = expected["core"][1]
            log.write_text("\n".join(lines).replace(f"core {count} pass ({count} total)",
                                                    f"core {count + 1} pass ({count + 1} total)") + "\n",
                           encoding="utf-8")
            out = io.StringIO()
            with redirect_stdout(out):
                code = check_test_counts.main(["--root", str(REPO), "--log", str(log)])
            self.assertEqual(code, 1, out.getvalue())


if __name__ == "__main__":
    unittest.main()

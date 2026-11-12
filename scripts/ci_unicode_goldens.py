#!/usr/bin/env python3
"""The Unicode 13.0.0 golden job (S5-T6 ruling 1, review R01).

  ci_unicode_goldens.py --check-version
  ci_unicode_goldens.py

The analyzer's tables are generated from Python's `unicodedata` at Unicode
13.0.0 (`search_platform._fold.UNICODE_VERSION`), and every golden the Python
reference writes reads those tables, so their regeneration checks skip on any
other Unicode version (CI's Python 3.11 has 14.0.0). This job runs them on a
Python whose `unicodedata.unidata_version` is 13.0.0 and does not let them skip.

--check-version fails unless this interpreter's Unicode is the tables'.

Without it, the modules in MODULES run whole. The job fails when an expected
check (EXPECTED, by name) did not run, when any test of those modules skipped,
failed or raised. A failing regeneration check is annotated with the file it
names and the first lines where the committed file and the fresh output differ
(the generator is run again for that), so a reader of the check-runs API sees
what is stale without the log. Nothing here writes a fixture.
"""

from __future__ import annotations

import argparse
import difflib
import subprocess
import sys
import unicodedata
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "scripts"))

from ci_annotations import Annotations  # noqa: E402
from search_platform._fold import UNICODE_VERSION  # noqa: E402

MODULES = ("tests.test_goldens_fresh", "tests.test_analyzer_v3", "tests.test_tokenize")

# Every check this job exists for: test id -> (the generated file, its generator's
# arguments, or None for a guard that reads the table instead of regenerating it).
EXPECTED = {
    "tests.test_analyzer_v3.FoldTableTests.test_table_regenerates_byte_for_byte":
        ("src/search_platform/_fold.py", ["scripts/gen_unicode_tables.py", "--python-fold"]),
    "tests.test_analyzer_v3.FoldTableTests.test_zig_tables_regenerate_byte_for_byte":
        ("zig/src/unicode_tables.zig", ["scripts/gen_unicode_tables.py"]),
    "tests.test_tokenize.TokenizeTests.test_marks_module_regenerates_byte_for_byte":
        ("src/search_platform/_marks.py", ["scripts/gen_unicode_tables.py", "--python-marks"]),
    "tests.test_tokenize.TokenizeTests.test_mark_table_matches_this_pythons_unicodedata":
        ("src/search_platform/_marks.py", None),
    "tests.test_analyzer_v3.GoldenTests.test_golden_regenerates_byte_for_byte":
        ("fixtures/analyzer-v3-golden.json", ["scripts/gen_analyzer_v3_golden.py"]),
    "tests.test_goldens_fresh.GoldensFreshTests.test_title_golden_regenerates_byte_for_byte":
        ("fixtures/title-field-golden.json", ["scripts/gen_title_golden.py"]),
    "tests.test_goldens_fresh.GoldensFreshTests.test_bm25_golden_regenerates_byte_for_byte":
        ("fixtures/bm25-golden.json", ["scripts/gen_bm25_golden.py"]),
    "tests.test_goldens_fresh.GoldensFreshTests.test_fuzzy_golden_regenerates_byte_for_byte":
        ("fixtures/fuzzy-golden.json", ["scripts/gen_fuzzy_golden.py"]),
    "tests.test_goldens_fresh.GoldensFreshTests.test_verb_forms_golden_regenerates_byte_for_byte":
        ("fixtures/verb-forms-golden.json", ["scripts/gen_verb_forms_golden.py"]),
}

DIFF_LINES = 4
CLIP = 160


def check_version(notes: Annotations) -> int:
    have = unicodedata.unidata_version
    print(f"Python {sys.version.split()[0]}: unicodedata {have}; the tables are generated with Unicode {UNICODE_VERSION}")
    if have != UNICODE_VERSION:
        notes.add("error", "Unicode version", f"this Python's unicodedata is {have}; the golden checks need "
                  f"{UNICODE_VERSION} (Python 3.9 or 3.10)")
        return 1
    return 0


def clip(text: str) -> str:
    return text if len(text) <= CLIP else text[:CLIP] + f"... ({len(text)} chars)"


def first_differences(committed: str, fresh: str) -> list[str]:
    """The first DIFF_LINES lines where the two texts differ, 1-based in the committed file."""
    a, b = committed.splitlines(), fresh.splitlines()
    out = []
    matcher = difflib.SequenceMatcher(a=a, b=b, autojunk=False)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        for k in range(max(i2 - i1, j2 - j1)):
            old = a[i1 + k] if i1 + k < i2 else None
            new = b[j1 + k] if j1 + k < j2 else None
            where = f"line {i1 + k + 1}" if old is not None else f"after line {i2}"
            shown_old = "(none)" if old is None else clip(old)
            shown_new = "(none)" if new is None else clip(new)
            out.append(f"{where}: committed {shown_old} | fresh {shown_new}")
            if len(out) >= DIFF_LINES:
                return out
    if not out and committed != fresh:
        out.append("the texts differ only in line endings or the final newline")
    return out


def describe_stale(path: str, generator: list[str]) -> str:
    try:
        fresh = subprocess.run([sys.executable] + [str(ROOT / generator[0])] + generator[1:], cwd=str(ROOT),
                               capture_output=True, text=True, check=True, timeout=300).stdout
    except (OSError, subprocess.SubprocessError) as exc:
        return f"{path}: the generator could not be run again for the difference ({exc})"
    committed = (ROOT / path).read_text(encoding="utf-8")
    if fresh == committed:
        return f"{path}: the regenerated text equals the committed file on the second run (the test failed on another assertion)"
    rows = first_differences(committed, fresh)
    return (f"{path} is stale (regenerate: python3 {' '.join(generator)} > {path}); "
            f"{len(committed.splitlines())} committed lines, {len(fresh.splitlines())} fresh; first differences: "
            + " || ".join(rows))


class Recorder(unittest.TextTestResult):
    """A verbose text result that also keeps every test id it ran."""

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.ran: list[str] = []

    def startTest(self, test) -> None:  # noqa: N802 (unittest's name)
        super().startTest(test)
        self.ran.append(test.id())


def judge(ran: list[str], skipped: dict[str, str], failed: dict[str, str], expected: dict,
          notes: Annotations, describe=describe_stale) -> int:
    """Annotate every problem; return the number of problems."""
    problems = 0
    for test_id in expected:
        if test_id not in ran:
            problems += 1
            notes.add("error", f"golden check missing: {expected[test_id][0]}",
                      f"{test_id} did not run (renamed or removed?): this job counts its checks by name")
    for test_id, reason in skipped.items():
        problems += 1
        what = expected[test_id][0] if test_id in expected else test_id.rsplit(".", 1)[-1]
        notes.add("error", f"golden check skipped: {what}", f"{test_id} skipped ({reason}); a skip fails this job")
    for test_id, trace in failed.items():
        problems += 1
        if test_id in expected:
            path, generator = expected[test_id]
            detail = describe(path, generator) if generator else f"{path}: {trace.strip().splitlines()[-1]}"
            notes.add("error", f"stale: {path}", f"{test_id} failed. {detail}")
        else:
            last = trace.strip().splitlines()[-1] if trace.strip() else "failed"
            notes.add("error", f"failed: {test_id.rsplit('.', 1)[-1]}", f"{test_id}: {clip(last)}")
    return problems


def run_checks(notes: Annotations) -> int:
    if check_version(notes):
        return 1
    suite = unittest.defaultTestLoader.loadTestsFromNames(MODULES)
    runner = unittest.TextTestRunner(stream=sys.stdout, verbosity=2, resultclass=Recorder)
    result = runner.run(suite)
    skipped = {t.id(): reason for t, reason in result.skipped}
    failed = {t.id(): trace for t, trace in result.failures + result.errors}
    failed.update({t.id(): "unexpected success" for t in result.unexpectedSuccesses})
    problems = judge(result.ran, skipped, failed, EXPECTED, notes)
    ran_expected = sum(1 for t in EXPECTED if t in result.ran)
    print(f"Unicode {unicodedata.unidata_version}: {len(result.ran)} tests ran in {', '.join(MODULES)}; "
          f"{ran_expected} of {len(EXPECTED)} expected golden checks ran; {len(skipped)} skipped, {len(failed)} failed")
    if problems:
        print(f"FAIL: {problems} problem(s)")
        return 1
    notes.add("notice", "Unicode 13 goldens", f"all {len(EXPECTED)} golden and table checks ran and passed on "
              f"Python {sys.version.split()[0]} (Unicode {unicodedata.unidata_version}); no test skipped")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check-version", action="store_true", help="only check this Python's Unicode version")
    args = parser.parse_args(argv)
    notes = Annotations()
    try:
        return check_version(notes) if args.check_version else run_checks(notes)
    finally:
        sys.stdout.flush()
        notes.flush()


if __name__ == "__main__":
    raise SystemExit(main())

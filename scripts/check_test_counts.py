#!/usr/bin/env python3
"""Each step of `zig build test` runs the tests the layer checker lists (S6-T15 rework).

The truth is what the build runs, so this compares against it. It reads each test
step's total from the Build Summary of a real `zig build test --summary all` and
fails when:

- a step's total (passed, skipped and failed together) differs from the number of
  tests `scripts/check_layers.py --list-tests` lists for it;
- a step the listing has is absent from the run;
- the run has a test step the listing lacks;
- the output holds no Build Summary, or a step's line carries no total (a step that
  did not compile, for example).

`check_layers.py` is the fast first line, with no toolchain; its reading of Zig is
not exact (docs/layers.md, "What it cannot see"). This comparison is the authority:
a test the reading counts and Zig does not run, or the other way round, changes a
step's total.

Usage (from anywhere; no dependencies but Python and, for --run, Zig 0.16 on PATH):

    python3 scripts/check_test_counts.py --run [-- ZIG BUILD ARGS]
        # runs `zig build test --summary all ARGS` in zig/, prints its output, then compares
    python3 scripts/check_test_counts.py --log FILE
        # compares a saved run's output (stdout and stderr together)

It exits 1 when a comparison fails, and with --run also when the build fails (after
printing the comparison). The steps are matched by the name the Build Summary prints
after `run test`, which zig/build.zig sets (check_layers.build_test_steps).
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_layers  # noqa: E402

# `+- run test core 253 pass (253 total) 35s MaxRSS:412M`,
# `+- run test tests 284 pass, 9 skip (293 total) 1m MaxRSS:644M`,
# `+- run test core 253 pass, 1 fail (254 total)`, `+- run test 6 pass (6 total)` (no name).
_STEP = re.compile(r"^\+- run test(?: (?P<name>[A-Za-z_][A-Za-z0-9_.-]*))?(?: (?P<rest>.*))?$")
_TOTAL = re.compile(r"\((?P<total>\d+) total\)")
_COUNT = re.compile(r"(?P<n>\d+) (?P<what>pass|skip|fail|leak|crash|timeout)")


def parse_summary(text: str):
    """The test steps of a run's Build Summary: (steps, problems). steps maps the name
    after `run test` ("" when there is none) to a dict with `total` (None when the line
    has none), `line` and the counts it prints (`pass`, `skip`, `fail`, ...). Only the
    top level of the summary's tree is read: the `run test` steps `test` depends on."""
    lines = text.splitlines()
    at = max((i for i, line in enumerate(lines) if line.startswith("Build Summary:")), default=None)
    if at is None:
        return {}, ["the output holds no `Build Summary:` line: run `zig build test --summary all`"]
    steps, problems = {}, []
    for line in lines[at + 1:]:
        match = _STEP.match(line)
        if not match:
            continue
        name = match.group("name") or ""
        rest = match.group("rest") or ""
        if name and name[0].isdigit():
            name, rest = "", f"{name} {rest}"
        total = _TOTAL.search(rest)
        entry = {"total": int(total.group("total")) if total else None, "line": line.strip()}
        for count in _COUNT.finditer(rest.split("(")[0]):
            entry[count.group("what")] = int(count.group("n"))
        if name in steps:
            problems.append(f"the Build Summary shows `run test {name}` twice")
        steps[name] = entry
    return steps, problems


def listing(root: Path):
    """The checker's tests per step of `zig build test`: (label -> (step, count), problems).
    label is the name the Build Summary prints for the step (zig/build.zig's `.name`)."""
    report = {}
    problems = check_layers.check(root, report=report)
    counts = {}
    for rel, places in report.get("reached", {}).items():
        for step, _ in places:
            counts[step] = counts.get(step, 0) + report["tests"][rel]
    out = {}
    for rel, step in report.get("steps", {}).items():
        label = report.get("labels", {}).get(rel)
        if label is None:
            problems.append(f"{check_layers.BUILD}: no test step of `zig build test` is rooted at src/{rel} "
                            f"(BUILD_ROOTS gives it the step {step!r})")
            continue
        out[label] = (step, counts.get(step, 0))
    return out, problems


def compare(expected, ran):
    """(table rows, problems) for the listing's steps against a run's (parse_summary)."""
    rows, problems = [], []
    for label, (step, count) in expected.items():
        shown = f"run test {label}".rstrip()
        got = ran.get(label)
        if got is None:
            problems.append(f"step {step!r} (`{shown}`): the listing has {count} tests, and the run has no such step")
            rows.append((step, shown, count, "absent", "FAIL"))
            continue
        if got["total"] is None:
            problems.append(f"step {step!r} (`{shown}`): the run reports no total ({got['line']})")
            rows.append((step, shown, count, "no total", "FAIL"))
            continue
        detail = ", ".join(f"{got[k]} {k}" for k in ("pass", "skip", "fail", "leak", "crash", "timeout") if k in got)
        ok = got["total"] == count
        if not ok:
            problems.append(f"step {step!r} (`{shown}`): the listing has {count} tests, the run {got['total']} "
                            f"({detail})")
        rows.append((step, shown, count, f"{got['total']} ({detail})", "ok" if ok else "FAIL"))
    for label in sorted(set(ran) - set(expected)):
        shown = f"run test {label}".rstrip()
        problems.append(f"the run has the step `{shown}` ({ran[label]['line']}), which the listing lacks")
        rows.append(("(none)", shown, "-", str(ran[label]["total"]), "FAIL"))
    return rows, problems


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Compare zig build test's step totals with check_layers' listing.")
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help="repository root (default: this script's)")
    how = parser.add_mutually_exclusive_group(required=True)
    how.add_argument("--log", type=Path, help="a saved `zig build test --summary all` output")
    how.add_argument("--run", action="store_true", help="run `zig build test --summary all` in zig/ first")
    parser.add_argument("zig_args", nargs="*", help="with --run, more arguments for zig build (after --)")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    build_code = 0
    if args.run:
        command = ["zig", "build", "test", "--summary", "all", *args.zig_args]
        print("$ " + " ".join(command), flush=True)
        proc = subprocess.Popen(command, cwd=root / "zig", stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, errors="replace")
        captured = []
        for line in proc.stdout:
            sys.stdout.write(line)
            captured.append(line)
        build_code = proc.wait()
        text = "".join(captured)
    else:
        text = args.log.read_text(encoding="utf-8", errors="replace")
    expected, problems = listing(root)
    ran, parse_problems = parse_summary(text)
    problems += parse_problems
    rows, compare_problems = compare(expected, ran)
    problems += compare_problems
    print()
    print("| Step | Build Summary line | Listed (check_layers) | Ran (zig build test) | |")
    print("|---|---|---:|---|---|")
    for step, shown, count, got, verdict in rows:
        print(f"| {step} | `{shown}` | {count} | {got} | {verdict} |")
    for problem in problems:
        print(f"check_test_counts: {problem}")
    if build_code:
        print(f"check_test_counts: zig build test exited {build_code}")
    if problems or build_code:
        return 1
    total = sum(count for _, count in expected.values())
    print(f"check_test_counts: OK ({len(expected)} steps, {total} tests: every step ran the tests the listing has)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

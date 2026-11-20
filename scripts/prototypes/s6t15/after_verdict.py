#!/usr/bin/env python3
"""S6-T15 rework: the Verdict's 6 build-file edits and 14 plants (and its baseline and
doc-followed test), each on a fresh `git archive` of COMMIT with its own local and
global Zig cache, run in sequence. For each: the copy's own static checker
(`check_layers.py --list-tests`), then the copy's own count comparison
(`check_test_counts.py --run`), which runs `zig build test --summary all` in Debug.

The plants are the verifier's, read from docs/evidence/s6-t15/verifier/plants.py
(its PLANTS table), applied unchanged.

Usage: python3 -I after_verdict.py WORKTREE COMMIT SCRATCH OUT [NAME ...]
       (no NAME: every plant, in the Verdict's order)."""
import os
import re
import runpy
import subprocess
import sys
import time
from pathlib import Path

WT, COMMIT, SCRATCH, OUT = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3]), Path(sys.argv[4])
NAMES = sys.argv[5:]

ORDER = ["baseline",
         "X-remove-core-row", "X-remove-fastmem-step", "X-copy-paste-ops-row", "X-remove-tests-row",
         "X-change-tests-root", "X-add-test-step",
         "A-nested-unref", "B-generic", "C-fn-named-not-called", "D-method-uncalled", "E-comptime-if-false",
         "F-comptime-not-is-test", "G-pub-const-nontest-fn", "H-path-in-other-module-test", "I-refAllDecls",
         "J-two-modules", "K-usingnamespace", "L-bench-only", "M-field-name", "R-import-in-named-struct",
         "Y-doc-ops"]


def load_plants():
    """The verifier's PLANTS table (its script reads sys.argv at import; give it inert values)."""
    saved = sys.argv
    sys.argv = ["plants.py", str(WT), COMMIT, str(SCRATCH / "unused"), "--no-build"]
    try:
        return runpy.run_path(str(WT / "docs/evidence/s6-t15/verifier/plants.py"), run_name="plants")["PLANTS"]
    finally:
        sys.argv = saved


def run(name, plants):
    d = SCRATCH / name
    if d.exists():
        print(f"{name}: {d} exists, skipped", flush=True)
        return
    src = d / "src"
    src.mkdir(parents=True)
    subprocess.run(f"git -C '{WT}' archive {COMMIT} | tar -x -C '{src}'", shell=True, check=True)
    pristine = d / "pristine"
    pristine.mkdir()
    subprocess.run(f"git -C '{WT}' archive {COMMIT} zig | tar -x -C '{pristine}'", shell=True, check=True)
    plants[name](src)
    diff = subprocess.run(["git", "diff", "--no-index", "--stat=120", str(pristine / "zig"), str(src / "zig")],
                          capture_output=True, text=True).stdout.replace(str(d), "<run>")
    log = [f"# {name} on {COMMIT}", diff.rstrip()]
    env = {k: v for k, v in os.environ.items() if k != "SEARCH_SIMPLI_LIBRARY_PATH"}
    env["ZIG_GLOBAL_CACHE_DIR"] = str(d / "gc")
    ck = subprocess.run([sys.executable, "-I", str(src / "scripts/check_layers.py"), "--root", str(src), "--list-tests"],
                        capture_output=True, text=True, env=env)
    keep = [line for line in ck.stdout.splitlines()
            if not line.startswith("| `") or re.search(r"plant|extra|report_doc", line)]
    log += [f"## static checker (check_layers.py --list-tests) exit {ck.returncode}",
            "\n".join(keep).replace(str(src), "<copy>"), ck.stderr.replace(str(src), "<copy>").rstrip()]
    t0 = time.time()
    cc = subprocess.run([sys.executable, "-I", str(src / "scripts/check_test_counts.py"), "--root", str(src), "--run",
                         "--", "--cache-dir", str(d / "lc"), "--global-cache-dir", str(d / "gc")],
                        capture_output=True, text=True, env=env)
    full = (cc.stdout + cc.stderr).replace(str(d), "<run>")
    (d / "count-full.txt").write_text(full, encoding="utf-8")
    lines = full.splitlines()
    at = max((i for i, line in enumerate(lines) if line.startswith("Build Summary:")), default=None)
    summary = [] if at is None else [line for line in lines[at:at + 2]] + \
        [line for line in lines[at:] if line.startswith("+- run test")]
    errors = [line for line in lines if line.startswith("error:") or "error:" in line[:80]][:6]
    table = [line for line in lines if line.startswith("| ") or line.startswith("|---")
             or line.startswith("check_test_counts:")]
    log += [f"## count comparison (check_test_counts.py --run, zig build test --summary all, Debug) exit "
            f"{cc.returncode} ({time.time() - t0:.0f} s)",
            "\n".join(summary) if summary else "(no Build Summary)",
            *(["first errors:", *errors] if errors and at is None else []),
            "", "\n".join(table)]
    text = "\n".join(log) + "\n"
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"{name}.txt").write_text(text, encoding="utf-8")
    print(text, flush=True)


if __name__ == "__main__":
    plants = load_plants()
    for name in NAMES or ORDER:
        run(name, plants)

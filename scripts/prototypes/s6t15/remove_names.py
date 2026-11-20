#!/usr/bin/env python3
"""S6-T15 ruling 1: removing any one name from a root fails the checker.

Takes a pristine copy of the repository (ARCHIVE, e.g. a `git archive` of the head)
and, for every name of a root, makes a fresh copy in SCRATCH/<case>/ (hard links to
ARCHIVE, the changed file written anew, so ARCHIVE is never modified), removes the
name and runs that copy's own scripts/check_layers.py on it:

- the three module roots (core/core.zig, ops/operations.zig,
  interfaces/interfaces.zig), every name of the test-build `comptime` block:
  (a) its `_ = name;` line only; (b) the whole name, that line and its `pub const`;
- tests/root.zig, every name whose `pub const` imports a `.zig` path: (a) its
  `_ = name;` line in the test block; (b) the whole name, its `pub const` and that line;
- tests/root.zig, every name imported through a module (`@import("core").x`):
  (a) only. These files run in their own folder's step, not in `tests`, so the
  checker is expected to pass: their removal changes no test that runs.

Prints one line per case and the totals; exit 1 if a case's result is not the
expected one.

Usage: python3 -I scripts/prototypes/s6t15/remove_names.py ARCHIVE SCRATCH
"""
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

MODULE_ROOTS = ("core/core.zig", "ops/operations.zig", "interfaces/interfaces.zig")
TESTS_ROOT = "tests/root.zig"
PUB = re.compile(r'^pub const (\w+) = @import\("([^"]+)"\)(\.\w+)?;$')


def copy(archive: Path, dest: Path, rel: str, text: str) -> None:
    shutil.copytree(archive, dest, copy_function=os.link)
    target = dest / "zig" / "src" / rel
    target.unlink()
    target.write_text(text, encoding="utf-8")


def run(dest: Path):
    out = subprocess.run([sys.executable, "-I", str(dest / "scripts" / "check_layers.py"), "--root", str(dest)],
                         capture_output=True, text=True)
    lines = out.stdout.strip().split("\n")
    return out.returncode, lines


def cases(archive: Path):
    for rel in MODULE_ROOTS:
        text = (archive / "zig" / "src" / rel).read_text(encoding="utf-8")
        lines = text.split("\n")
        block = text[text.index("comptime {"):]
        names = re.findall(r"^\s+_ = (\w+);$", block, re.M)
        for name in names:
            ref = f"        _ = {name};"
            pub = next(line for line in lines if PUB.match(line) and PUB.match(line).group(1) == name)
            yield rel, name, "a", [line for line in lines if line != ref], 1
            yield rel, name, "b", [line for line in lines if line not in (ref, pub)], 1
    text = (archive / "zig" / "src" / TESTS_ROOT).read_text(encoding="utf-8")
    lines = text.split("\n")
    test_at = next(i for i, line in enumerate(lines) if line.startswith("test "))
    for line in lines:
        match = PUB.match(line)
        if not match:
            continue
        name, target, _ = match.groups()
        ref = f"    _ = {name};"
        if ref not in lines[test_at:]:
            continue
        without_ref = lines[:test_at] + [x for x in lines[test_at:] if x != ref]
        if target.endswith(".zig"):
            yield TESTS_ROOT, name, "a", without_ref, 1
            yield TESTS_ROOT, name, "b", [x for x in without_ref if x != line], 1
        else:
            yield TESTS_ROOT, name, "a (module)", without_ref, 0


def main(archive: Path, scratch: Path) -> int:
    scratch.mkdir(parents=True, exist_ok=False)
    totals, wrong = {}, 0
    for n, (rel, name, variant, lines, expected) in enumerate(cases(archive), 1):
        dest = scratch / f"case-{n:03d}"
        copy(archive, dest, rel, "\n".join(lines))
        code, out = run(dest)
        ok = code == expected
        wrong += not ok
        key = (rel, variant)
        seen = totals.setdefault(key, [0, 0])
        seen[0] += 1
        seen[1] += code == 1
        first = out[0] if code else out[-1]
        print(f"{'ok ' if ok else 'BAD'} case {n:03d} {rel} {name} ({variant}): exit {code}; {first}")
    print()
    print("| Root | Removed | Cases | Checker failed | Expected |")
    print("|---|---|---:|---:|---|")
    for (rel, variant), (count, failed) in totals.items():
        want = "pass" if "module" in variant else "fail"
        print(f"| `{rel}` | {variant} | {count} | {failed} | {want} |")
    print(f"{sum(c for c, _ in totals.values())} cases; {wrong} not as expected")
    return 1 if wrong else 0


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()))

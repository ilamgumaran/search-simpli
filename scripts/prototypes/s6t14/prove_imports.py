#!/usr/bin/env python3
"""S6-T14 ruling 1: every moved Zig file differs from its old content in import lines only.

    python3 -I scripts/prototypes/s6t14/prove_imports.py BASE HEAD

BASE and HEAD are commits of this repository (87c4ddb and the move commit). Every
`.zig` file under zig/src/ at BASE is paired with the one file of the same name under
zig/src/ at HEAD (the names are unique on both sides; the move keeps them). For each
pair it checks, and prints one line per file:

- the two have the same number of lines, and every line that differs contains
  `@import` on both sides;
- a differing line is the old line with each `@import("X.zig")` written as
  `@import("<module>").<name>`, and nothing else changed: both lines are equal once
  every import expression is replaced by one placeholder;
- every `.zig` import at HEAD names the file the same import named at BASE: a path
  import resolves, from the file's new folder, to the moved target, and a module
  import `@import("core").name` (`operations`, `interfaces`) names a `pub const` of
  that module's root whose file is the moved target.

The module roots that HEAD adds (core/core.zig, ops/operations.zig,
interfaces/interfaces.zig) are checked to hold nothing but comments, blank lines,
`pub const NAME = @import("NAME.zig");` for files of their own folder, and one
`comptime { if (@import("builtin").is_test) { _ = NAME; ... } }` naming the same
NAMEs. Exit 1 on any failure. Not part of any library.
"""
from __future__ import annotations

import posixpath
import re
import subprocess
import sys

MODULE_FOLDER = {"core": "core", "operations": "ops", "interfaces": "interfaces"}
ROOTS = {"core/core.zig": "core", "ops/operations.zig": "operations", "interfaces/interfaces.zig": "interfaces"}
PATH_IMPORT = re.compile(r'@import\("([^"\\]*\.zig)"\)')
MODULE_IMPORT = re.compile(r'@import\("(core|operations|interfaces)"\)\.([A-Za-z_][A-Za-z0-9_]*)')
ANY_IMPORT = re.compile(r'@import\("[^"\\]*"\)(?:\.[A-Za-z_][A-Za-z0-9_]*)?')
ROOT_LINE = re.compile(r'pub const ([A-Za-z_][A-Za-z0-9_]*) = @import\("([A-Za-z0-9_]+\.zig)"\);$')


def git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def zig_files(commit: str) -> list[str]:
    out = git("ls-tree", "-r", "--name-only", commit, "--", "zig/src")
    return sorted(p[len("zig/src/"):] for p in out.splitlines() if p.endswith(".zig"))


def show(commit: str, rel: str) -> str:
    return git("show", f"{commit}:zig/src/{rel}")


def normalise(line: str, module_form: bool) -> str:
    """The line with every import expression replaced by one placeholder. At HEAD an
    import of a module is `@import("core").name`: the `.name` belongs to it."""
    if module_form:
        line = MODULE_IMPORT.sub("@import(?)", line)
    return PATH_IMPORT.sub("@import(?)", line)


def root_exports(text: str, folder: str, problems: list, rel: str) -> dict[str, str]:
    exports, refs, state = {}, [], "head"
    for number, line in enumerate(text.split("\n"), 1):
        stripped = line.strip()
        where = f"{rel}:{number}"
        if state == "head":
            if stripped == "" or stripped.startswith("//"):
                continue
            match = ROOT_LINE.match(line)
            if match:
                name, file = match.groups()
                if file != name + ".zig":
                    problems.append(f"{where}: pub const {name} names {file}")
                exports[name] = f"{folder}/{file}"
                continue
            if line == "comptime {":
                state = "comptime"
                continue
            problems.append(f"{where}: not a comment, a blank line or one pub const import: {line!r}")
        elif state == "comptime":
            if line == '    if (@import("builtin").is_test) {':
                state = "refs"
                continue
            problems.append(f"{where}: expected the is_test condition: {line!r}")
        elif state == "refs":
            match = re.match(r"        _ = ([A-Za-z_][A-Za-z0-9_]*);$", line)
            if match:
                refs.append(match.group(1))
                continue
            if line == "    }":
                state = "close"
                continue
            problems.append(f"{where}: expected `_ = NAME;`: {line!r}")
        elif state == "close":
            if line == "}":
                state = "end"
                continue
            problems.append(f"{where}: expected the closing brace: {line!r}")
        elif state == "end":
            if line != "":
                problems.append(f"{where}: text after the comptime block: {line!r}")
    if state != "end":
        problems.append(f"{rel}: the comptime block is missing or unclosed")
    if refs != list(exports):
        problems.append(f"{rel}: the comptime block names {refs}, the pub consts are {list(exports)}")
    return exports


def main(argv: list[str]) -> int:
    base, head = argv[1], argv[2]
    old_files, new_files = zig_files(base), zig_files(head)
    problems: list[str] = []
    by_name: dict[str, str] = {}
    for rel in new_files:
        if rel in ROOTS:
            continue
        name = posixpath.basename(rel)
        if name in by_name:
            problems.append(f"zig/src/{rel}: a second file named {name} at {head}")
        by_name[name] = rel
    moved = {}
    for rel in old_files:
        name = posixpath.basename(rel)
        if name not in by_name:
            problems.append(f"zig/src/{rel}: no file of that name at {head}")
            continue
        moved[rel] = by_name[name]
    extra = sorted(set(by_name.values()) - set(moved.values()))
    if extra:
        problems.append(f"files at {head} with no file of the same name at {base}: {extra}")

    exports = {}
    for rel, module in ROOTS.items():
        if rel not in new_files:
            problems.append(f"zig/src/{rel}: missing at {head}")
            continue
        exports[module] = root_exports(show(head, rel), MODULE_FOLDER[module], problems, f"zig/src/{rel}")
        for name, target in exports[module].items():
            if target not in set(moved.values()):
                problems.append(f"zig/src/{rel}: {name} names zig/src/{target}, not a moved file")

    rows = []
    totals = {"files": 0, "lines": 0, "changed": 0, "imports_old": 0, "imports_new": 0, "unchanged_files": 0}
    for old_rel, new_rel in sorted(moved.items(), key=lambda kv: kv[1]):
        old, new = show(base, old_rel), show(head, new_rel)
        old_lines, new_lines = old.split("\n"), new.split("\n")
        file_problems = []
        if len(old_lines) != len(new_lines):
            file_problems.append(f"{len(old_lines)} lines at {base}, {len(new_lines)} at {head}")
        changed = 0
        old_targets, new_targets = [], []
        for number, (a, b) in enumerate(zip(old_lines, new_lines), 1):
            for m in PATH_IMPORT.finditer(a):
                old_targets.append((number, posixpath.normpath(posixpath.join(posixpath.dirname(old_rel), m.group(1)))))
            for m in ANY_IMPORT.finditer(b):
                text = m.group(0)
                mm = MODULE_IMPORT.fullmatch(text)
                pm = PATH_IMPORT.match(text)
                if mm:
                    module, name = mm.groups()
                    target = exports.get(module, {}).get(name)
                    if target is None:
                        file_problems.append(f"line {number}: @import(\"{module}\").{name} is not exported by its module root")
                    new_targets.append((number, target))
                elif pm:
                    new_targets.append((number, posixpath.normpath(posixpath.join(posixpath.dirname(new_rel), pm.group(1)))))
            if a == b:
                continue
            changed += 1
            if "@import" not in a or "@import" not in b:
                file_problems.append(f"line {number} differs and is not an import line on both sides")
            elif normalise(a, False) != normalise(b, True):
                file_problems.append(f"line {number} differs outside its import expressions")
        if len(old_targets) != len(new_targets):
            file_problems.append(f"{len(old_targets)} .zig imports at {base}, {len(new_targets)} at {head}")
        for (n1, t_old), (n2, t_new) in zip(old_targets, new_targets):
            want = moved.get(t_old)
            if n1 != n2 or want is None or t_new != want:
                file_problems.append(f"line {n1}: imported zig/src/{t_old}, now {t_new} (expected {want})")
        totals["files"] += 1
        totals["lines"] += len(new_lines) - 1
        totals["changed"] += changed
        totals["imports_old"] += len(old_targets)
        totals["imports_new"] += sum(1 for _, t in new_targets if t is not None)
        totals["unchanged_files"] += changed == 0
        verdict = "ok" if not file_problems else "FAIL: " + "; ".join(file_problems)
        rows.append(f"{old_rel:30} -> {new_rel:42} {len(new_lines) - 1:6} lines {changed:4} import lines changed "
                    f"{len(old_targets):4} imports, same files  {verdict}")
        problems += [f"zig/src/{new_rel}: {p}" for p in file_problems]

    print(f"# S6-T14 ruling 1: scripts/prototypes/s6t14/prove_imports.py {base} {head}")
    print("# old path (zig/src/)            -> new path (zig/src/)                     lines, changed lines, .zig imports, verdict")
    for row in rows:
        print(row)
    print()
    for rel, module in ROOTS.items():
        names = exports.get(module, {})
        print(f"module root zig/src/{rel} (`{module}`): {len(names)} pub const imports of files of its folder, "
              f"the same {len(names)} named in its is_test comptime block, nothing else")
    print()
    print(f"files moved: {totals['files']} (of {len(old_files)} at {base}); unchanged: {totals['unchanged_files']}; "
          f"with import lines changed: {totals['files'] - totals['unchanged_files']}")
    print(f"lines: {totals['lines']}; lines changed: {totals['changed']}, every one an import line on both sides, "
          f"equal outside its import expressions")
    print(f".zig imports: {totals['imports_old']} at {base}, {totals['imports_new']} at {head}, each naming the same moved file")
    if problems:
        print()
        for p in problems:
            print("PROBLEM", p)
        print(f"prove_imports: {len(problems)} problem(s)")
        return 1
    print("prove_imports: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

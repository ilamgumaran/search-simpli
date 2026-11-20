#!/usr/bin/env python3
"""S6-T14: the move of zig/src/ into core/, ops/, interfaces/ and tests/ (plan step B2).

    python3 -I scripts/prototypes/s6t14/move.py plan     # print where every file goes, and why
    python3 -I scripts/prototypes/s6t14/move.py apply    # git mv, rewrite import operands, write the module roots

Run from the repository root on `main`'s tree (87c4ddb), once. The destination of a
file the checker assigns (scripts/check_layers.py FILES, as at 87c4ddb) is its layer's
folder. A test, benchmark or tool goes beside its subject when every file it imports,
directly or through another test, benchmark or tool, is of one layer; otherwise it
goes to tests/ (with root.zig, the root of the cross-layer test build).

The only edit to a moved file: an `@import("X.zig")` whose target now sits in another
folder becomes `@import("<module>").<target's file name without .zig>`, where the
module is `core`, `operations` or `interfaces` (the folder's module, zig/build.zig).
An import within one folder keeps its operand (the names do not change). Each module
root (core/core.zig, ops/operations.zig, interfaces/interfaces.zig) is written with one
`pub const` per file the module serves and a test-build-only reference to them.
Not part of any library.
"""
from __future__ import annotations

import posixpath
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path.cwd()
SRC = ROOT / "zig" / "src"
sys.path.insert(0, str(ROOT / "scripts"))
import check_layers as layers  # noqa: E402  (main's checker: the assignment moved by)

FOLDER = {"core": "core", "operations": "ops", "interfaces": "interfaces"}
MODULE = {"core": "core", "ops": "operations", "interfaces": "interfaces"}
ROOTS = {"core": "core.zig", "ops": "operations.zig", "interfaces": "interfaces.zig"}
IMPORT = re.compile(r'@import\("([^"\\]*)"\)')
# Files a module root leaves out: fastmem.zig is its own object (zig/build.zig) and no
# Zig file imports it; main.zig is the searchd executable's root, has no test and is
# not compiled by `zig build test` today.
LEFT_OUT = {"core/fastmem.zig", "interfaces/main.zig"}


def zig_imports(rel: str) -> list[str]:
    return [t for _, t, _ in layers.imports_of((SRC / rel).read_text(encoding="utf-8")) if t and t.endswith(".zig")]


def destinations() -> dict[str, tuple[str, str]]:
    """old path -> (new path, why)."""
    files = layers.zig_files(SRC)
    out = {}
    for rel in files:
        if rel in layers.FILES:
            layer = layers.FILES[rel][0]
            out[rel] = (f"{FOLDER[layer]}/{rel}", f"assigned to {layer}")
    for rel in files:
        if rel in out:
            continue
        if rel == "root.zig":
            out[rel] = ("tests/root.zig", "the root of the cross-layer test build")
            continue
        seen, todo, found = set(), [rel], set()
        while todo:
            f = todo.pop()
            if f in seen:
                continue
            seen.add(f)
            for target in zig_imports(f):
                dep = layers.resolve(SRC, f, target)
                if dep in layers.FILES:
                    found.add(layers.FILES[dep][0])
                else:
                    todo.append(dep)
        if len(found) == 1:
            layer = found.pop()
            out[rel] = (f"{FOLDER[layer]}/{rel}", f"imports {layer} files only")
        else:
            out[rel] = (f"tests/{rel}", "imports " + ", ".join(sorted(found)))
    return out


def rewrite(old_rel: str, dest: dict) -> tuple[str, set[tuple[str, str]]]:
    """The moved file's new text, and the (folder, file name) its imports now reach through a module."""
    text = (SRC / old_rel).read_text(encoding="utf-8")
    new_folder = dest[old_rel][0].split("/")[0]
    needed = set()

    def one(match):
        target = match.group(1)
        if not target.endswith(".zig"):
            return match.group(0)
        dep_new = dest[layers.resolve(SRC, old_rel, target)][0]
        folder, name = dep_new.split("/", 1)
        if folder == new_folder:
            assert posixpath.basename(target) == name, (old_rel, target)
            return match.group(0)
        needed.add((folder, name))
        return f'@import("{MODULE[folder]}").{name[:-4]}'

    new = IMPORT.sub(one, text)
    count = sum(1 for t in zig_imports(old_rel))
    assert count == sum(1 for m in IMPORT.finditer(text) if m.group(1).endswith(".zig")), old_rel
    return new, needed


ROOT_HEAD = {
    "core": (
        "//! The core layer as one module, `core` (S6-T14; docs/layers.md). zig/build.zig\n"
        "//! builds zig/src/core/ as this module. Operations, interfaces and the tests in\n"
        "//! zig/src/tests/ reach a core file as `@import(\"core\").<file name>`, never by a\n"
        "//! path into core/. Every core file but fastmem.zig (an object of its own in\n"
        "//! zig/build.zig) and the core tests that another folder names.\n"),
    "ops": (
        "//! The operations layer as one module, `operations` (S6-T14; docs/layers.md).\n"
        "//! zig/build.zig builds zig/src/ops/ as this module; it imports `core`. The\n"
        "//! interfaces and the tests in zig/src/tests/ reach an operations file as\n"
        "//! `@import(\"operations\").<file name>`, never by a path into ops/.\n"),
    "interfaces": (
        "//! The interfaces as one module, `interfaces` (S6-T14; docs/layers.md), for the\n"
        "//! tests in zig/src/tests/ only: they reach an interface file as\n"
        "//! `@import(\"interfaces\").<file name>`. The searchd executable and the C ABI\n"
        "//! libraries are built from main.zig and abi.zig themselves (zig/build.zig);\n"
        "//! main.zig is left out (it has no test and no test build compiles it).\n"),
}
ROOT_TAIL = (
    "\n"
    "// `zig build test` runs this module's tests in a step of their own (zig/build.zig):\n"
    "// a test build only collects the tests of its root module's files. The reference\n"
    "// below is made in a test build only, and adds no test of its own.\n"
    "comptime {\n"
    "    if (@import(\"builtin\").is_test) {\n"
    "{refs}"
    "    }\n"
    "}\n")


def module_root(folder: str, names: list[str]) -> str:
    lines = [ROOT_HEAD[folder], "\n"]
    lines += [f'pub const {n[:-4]} = @import("{n}");\n' for n in names]
    refs = "".join(f"        _ = {n[:-4]};\n" for n in names)
    lines.append(ROOT_TAIL.replace("{refs}", refs))
    return "".join(lines)


def main(argv) -> int:
    dest = destinations()
    if argv[1:] == ["plan"]:
        for old, (new, why) in sorted(dest.items(), key=lambda kv: kv[1][0]):
            print(f"{old:32} -> {new:42} {why}")
        return 0
    assert argv[1:] == ["apply"], __doc__
    texts, needed = {}, set()
    for old in dest:
        texts[old], n = rewrite(old, dest)
        needed |= n
    for old, (new, _) in sorted(dest.items()):
        (SRC / new).parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "mv", f"zig/src/{old}", f"zig/src/{new}"], check=True)
        (SRC / new).write_text(texts[old], encoding="utf-8")
    for folder in ("core", "ops", "interfaces"):
        served = sorted(new.split("/", 1)[1] for new, _ in dest.values()
                        if new.startswith(folder + "/") and new not in LEFT_OUT
                        and (new.split("/", 1)[1] in {n for f, n in needed if f == folder}
                             or layers.FILES.get(new.split("/", 1)[1], ("",))[0] != ""))
        missing = {n for f, n in needed if f == folder} - set(served)
        assert not missing, (folder, missing)
        (SRC / folder / ROOTS[folder]).write_text(module_root(folder, served), encoding="utf-8")
        subprocess.run(["git", "add", f"zig/src/{folder}/{ROOTS[folder]}"], check=True)
    print(f"moved {len(dest)} files; module roots written")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

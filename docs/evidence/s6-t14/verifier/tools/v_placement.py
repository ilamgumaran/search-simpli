#!/usr/bin/env python3
"""Independent placement check for S6-T14 (rulings 1 and 2, task item 1).

1. Every layer file sits in the folder of the layer that main's checker (87c4ddb)
   assigns it: main's FILES table read from `git show 87c4ddb:scripts/check_layers.py`.
2. Every other file (test, benchmark, tool) sits beside its subject when the files
   it reaches (following imports through other tests and tools, at main) are of one
   layer only, and in tests/ otherwise.
Usage: v_placement.py REPO"""
import ast
import posixpath
import re
import subprocess
import sys

repo = sys.argv[1]


def git(*a):
    return subprocess.run(["git", "-C", repo, *a], check=True, capture_output=True, text=True).stdout


src = git("show", "87c4ddb:scripts/check_layers.py")
tree = ast.parse(src)
files_main = None
for node in tree.body:
    if isinstance(node, ast.Assign) and any(getattr(t, "id", None) == "FILES" for t in node.targets):
        files_main = {k.value: v.elts[0].value for k, v in zip(node.value.keys, node.value.values)}
assert files_main, "FILES not found"
folder = {"core": "core", "operations": "ops", "interfaces": "interfaces"}
old = [p[len("zig/src/"):] for p in git("ls-tree", "-r", "--name-only", "87c4ddb", "zig/src").split()]
new = [p[len("zig/src/"):] for p in git("ls-tree", "-r", "--name-only", "HEAD", "zig/src").split()]
where = {posixpath.basename(p): p for p in new}
IMP = re.compile(r'@import\("([^"]+\.zig)"\)')
imports = {p: set(IMP.findall(git("show", f"87c4ddb:zig/src/{p}"))) for p in old}
bad = 0
for name, layer in sorted(files_main.items()):
    expect = f"{folder[layer]}/{posixpath.basename(name)}"
    if where.get(posixpath.basename(name)) != expect:
        print("LAYER FILE MISPLACED", name, "->", where.get(posixpath.basename(name)), "expected", expect)
        bad += 1


def reached(p, seen):
    out = set()
    for t in imports.get(p, ()):
        if t in files_main:
            out.add(files_main[t])
        elif t not in seen and t in imports:
            seen.add(t)
            out |= reached(t, seen)
    return out


counts = {}
for p in sorted(old):
    if p in files_main:
        continue
    layers = reached(p, {p})
    if p == "root.zig":
        expect = "tests"
    elif len(layers) == 1:
        expect = folder[next(iter(layers))]
    else:
        expect = "tests"
    got = posixpath.dirname(where[p])
    counts[got] = counts.get(got, 0) + 1
    if got != expect:
        print("TEST/TOOL MISPLACED", p, "reaches", sorted(layers), "in", got, "expected", expect)
        bad += 1
print(f"layer files {len(files_main)} checked; tests/benches/tools by folder {counts}; problems {bad}")
sys.exit(1 if bad else 0)

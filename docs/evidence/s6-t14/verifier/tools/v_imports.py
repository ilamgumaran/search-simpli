#!/usr/bin/env python3
"""Verifier's own ruling-1 check for S6-T14.

For every .zig file under zig/src at OLD, pair it by basename with the one file of
that name at NEW. Report every line that differs. Each differing line must hold an
@import on both sides, be equal once each @import(...) expression (with a trailing
.member) is replaced by a placeholder, and every import must name the same file
(path import resolved from the file's folder, or module import resolved through the
module root's `pub const NAME = @import("NAME.zig");`).
Also lists files that exist only at NEW and prints them in full for reading.
Usage: v_imports.py REPO OLD NEW
"""
import difflib
import posixpath
import re
import subprocess
import sys

repo, old, new = sys.argv[1:4]


def git(*args):
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True).stdout


def tree(rev):
    out = git("ls-tree", "-r", "--name-only", rev, "zig/src").decode().split("\n")
    return [p for p in out if p]


def show(rev, path):
    return git("show", f"{rev}:{path}").decode("utf-8")


IMP_RAW = re.compile(r'@import\(\s*"([^"]+)"\s*\)(?:\.([A-Za-z_][A-Za-z0-9_]*))?')
LAYER_MODS = ("core", "operations", "interfaces")


class _Imp:
    """An @import expression: a layer module's import includes its `.member`; a file's or
    another module's does not (its `.member` belongs to the surrounding code)."""
    def __init__(self, m):
        self.target = m.group(1)
        self.member = m.group(2) if self.target in LAYER_MODS else None
        self.end = m.end() if self.member is not None else m.start() + len(m.group(0)) - (len(m.group(2)) + 1 if m.group(2) else 0)
        self.start = m.start()
    def group(self, k):
        return self.target if k == 1 else self.member


class IMP:
    @staticmethod
    def finditer(x):
        return [_Imp(m) for m in IMP_RAW.finditer(x)]
    @staticmethod
    def findall(x):
        return IMP_RAW.findall(x)
    @staticmethod
    def sub(rep, x):
        out, last = [], 0
        for i in IMP.finditer(x):
            out.append(x[last:i.start]); out.append(rep); last = i.end
        out.append(x[last:])
        return "".join(out)
ROOT_EXPORT = re.compile(r'^pub const ([A-Za-z_][A-Za-z0-9_]*) = @import\("([^"]+)"\);$')

old_files = tree(old)
new_files = tree(new)
bad = 0
by_base_new = {}
for p in new_files:
    by_base_new.setdefault(posixpath.basename(p), []).append(p)

# Module roots at NEW.
module_roots = {"core": "zig/src/core/core.zig", "operations": "zig/src/ops/operations.zig",
                "interfaces": "zig/src/interfaces/interfaces.zig"}
exports = {}
for name, path in module_roots.items():
    exp = {}
    for line in show(new, path).split("\n"):
        m = ROOT_EXPORT.match(line)
        if m:
            exp[m.group(1)] = posixpath.normpath(posixpath.join(posixpath.dirname(path), m.group(2)))
    exports[name] = exp

pairs = {}
for p in old_files:
    cands = by_base_new.get(posixpath.basename(p), [])
    if len(cands) != 1:
        print(f"PAIR? {p}: {cands}")
        bad += 1
        continue
    pairs[p] = cands[0]
moved_to = dict(pairs)
new_only = sorted(set(new_files) - set(pairs.values()))


def resolve_old(path, target, member):
    if not target.endswith(".zig"):
        return ("mod", target, member)
    return ("file", moved_to.get(posixpath.normpath(posixpath.join(posixpath.dirname(path), target)), "?missing"), member)


def resolve_new(path, target, member):
    if not target.endswith(".zig"):
        if target in exports:
            if member is None or member not in exports[target]:
                return ("?bad-module-member", target, member)
            return ("file", exports[target][member], None)
        return ("mod", target, member)
    return ("file", posixpath.normpath(posixpath.join(posixpath.dirname(path), target)), member)


stats = dict(same=0, differ=0, lines=0, difflines=0, imports_old=0, imports_new=0)
for o, n in sorted(pairs.items()):
    a = show(old, o).split("\n")
    b = show(new, n).split("\n")
    stats["lines"] += len(a)
    stats["imports_old"] += sum(len(IMP.findall(x)) for x in a)
    stats["imports_new"] += sum(len(IMP.findall(x)) for x in b)
    if a == b:
        stats["same"] += 1
        # Even unchanged, every path import must still resolve to the same file.
        for i, x in enumerate(a):
            for m in IMP.finditer(x):
                ro = resolve_old(o, m.group(1), m.group(2))
                rn = resolve_new(n, m.group(1), m.group(2))
                if ro != rn:
                    print(f"UNCHANGED LINE, DIFFERENT TARGET {n}:{i+1}: {ro} vs {rn}")
                    bad += 1
        continue
    stats["differ"] += 1
    if len(a) != len(b):
        print(f"LINECOUNT {o} {len(a)} -> {n} {len(b)}")
        bad += 1
        for line in difflib.unified_diff(a, b, o, n, lineterm="", n=0):
            print("   ", line)
        continue
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            stats["difflines"] += 1
            if "@import" not in x or "@import" not in y:
                print(f"NON-IMPORT {n}:{i+1}\n  - {x}\n  + {y}")
                bad += 1
                continue
            if IMP.sub("@IMP", x) != IMP.sub("@IMP", y):
                print(f"REST DIFFERS {n}:{i+1}\n  - {x}\n  + {y}")
                bad += 1
                continue
        # resolve imports on every line (changed or not)
        mo = list(IMP.finditer(x))
        mn = list(IMP.finditer(y))
        if len(mo) != len(mn):
            print(f"IMPORT COUNT {n}:{i+1}")
            bad += 1
            continue
        for p_, q_ in zip(mo, mn):
            ro = resolve_old(o, p_.group(1), p_.group(2))
            rn = resolve_new(n, q_.group(1), q_.group(2))
            if ro != rn:
                print(f"TARGET {n}:{i+1}: old {ro} new {rn}\n  - {x}\n  + {y}")
                bad += 1

print(f"pairs {len(pairs)}; unchanged {stats['same']}; changed {stats['differ']}; lines {stats['lines']}; "
      f"differing lines {stats['difflines']}; @import (regex) old {stats['imports_old']} new {stats['imports_new']}")
print("files only at NEW:", new_only)
print("problems:", bad)
sys.exit(1 if bad else 0)

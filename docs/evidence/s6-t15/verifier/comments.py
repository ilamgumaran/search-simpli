#!/usr/bin/env python3
"""S6-T15 verifier, check 4: for every .zig file changed between BASE and HEAD, the file
with comments removed (an independent stripper: strings, chars and `\\\\` lines kept
whole, `//` to end of line dropped) and whitespace runs collapsed must be equal.
python3 -I comments.py REPO BASE HEAD"""
import subprocess, sys

repo, base, head = sys.argv[1:4]


def git(*a):
    return subprocess.run(["git", "-C", repo, *a], capture_output=True, check=True).stdout


def strip(src: str):
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("\\\\", i):  # multiline string line: keep to end of line
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(src[i:j]); out.append("\n"); i = j
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif c in "\"'":
            j = i + 1
            while j < n and src[j] != c and src[j] != "\n":
                j += 2 if src[j] == "\\" else 1
            out.append(src[i:j + 1]); i = j + 1
        else:
            out.append(c); i += 1
    return " ".join("".join(out).split())


files = [f for f in git("diff", "--name-only", base, head).decode().split("\n") if f.endswith(".zig")]
bad = 0
for f in files:
    a = git("show", f"{base}:{f}").decode("utf-8")
    b = git("show", f"{head}:{f}").decode("utf-8")
    same = strip(a) == strip(b)
    al, bl = a.split("\n"), b.split("\n")
    changed = [(x, y) for x, y in zip(al, bl) if x != y]
    allc = len(al) == len(bl) and all(x.lstrip().startswith("//") and y.lstrip().startswith("//") for x, y in changed)
    print(f"{f}: code without comments {'equal' if same else 'DIFFERS'}; lines {len(al)}->{len(bl)}; "
          f"{len(changed)} changed line(s), all comment lines: {allc}")
    bad += (not same) or (not allc)
print(f"{len(files)} Zig files changed; files differing beyond comments: {bad}")
sys.exit(1 if bad else 0)

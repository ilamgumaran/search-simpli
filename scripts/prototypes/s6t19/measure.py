#!/usr/bin/env python3
"""S6-T19, What point 1: every `core.api` name used in zig/src/ops/ and zig/src/interfaces/,
split by whether a non-test declaration uses it or only `test` blocks do.

    python3 -I scripts/prototypes/s6t19/measure.py [--root DIR] [--commit REV]

Read with scripts/check_layers.py's own reading (`core_api` for the names `api` holds,
`core_uses` for every reference to the module `core`, inline or through an alias in the
block it is bound in, and `container_items` for the top-level `test` blocks), so it counts
what the guard reads. A use is `api.NAMESPACE.NAME` (a deeper chain is counted under its
first three names); a binding (`const A = @import("core").api.NAMESPACE;`) is not a use. A
use is "test" when it sits inside a top-level `test` block of its file, or anywhere in a
`*_test.zig` file; every other use is "code", and the declaration it sits in is named.
Prints Markdown. Not part of any library.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "scripts"))
import check_layers  # noqa: E402


def read_tree(root: Path, commit: str | None):
    if commit is None:
        src = root / "zig" / "src"
        return {p.relative_to(src).as_posix(): p.read_text(encoding="utf-8") for p in sorted(src.rglob("*.zig"))}
    names = subprocess.run(["git", "-C", str(root), "ls-tree", "-r", "--name-only", commit, "--", "zig/src"],
                           check=True, capture_output=True, text=True).stdout.split()
    out = {}
    for name in names:
        if name.endswith(".zig"):
            out[name[len("zig/src/"):]] = subprocess.run(["git", "-C", str(root), "show", f"{commit}:{name}"],
                                                         check=True, capture_output=True, text=True).stdout
    return out


def items_by_line(text: str):
    """(first line, last line, kind, label) of every top-level item; a test's label is its name."""
    toks = list(check_layers.tokens(text))
    line_of = lambda k: text.count("\n", 0, toks[min(k, len(toks) - 1)][2]) + 1  # noqa: E731
    out = []
    for kind, name, start, end in check_layers.container_items(text, toks):
        label = name
        if kind == "test":
            nxt = toks[start + 1] if start + 1 < len(toks) else None
            label = nxt[1] if nxt and nxt[0] in ("string", "word") else "(unnamed)"
        out.append((line_of(start), line_of(end - 1), kind, label))
    return out


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=REPO)
    parser.add_argument("--commit", default=None, help="read the tree of this commit instead of the working tree")
    args = parser.parse_args(argv)
    tree = read_tree(args.root, args.commit)
    api, problems = check_layers.core_api(tree["core/core.zig"])
    if problems:
        for line, message in problems:
            print(f"core/core.zig:{line}: {message}")
        return 1
    api_names = sorted(f"{ns}.{n}" for ns, (_, names) in api.items() for n in names)

    uses = []  # (file, line, name, deeper, where: "code"/"test", label)
    odd = []
    for rel, text in sorted(tree.items()):
        if rel.split("/", 1)[0] not in check_layers.API_FOLDERS:
            continue
        test_file = rel.endswith("_test.zig")
        items = items_by_line(text)
        for line, chain, bound in check_layers.core_uses(text):
            if bound is not None:
                continue
            if len(chain) < 3 or chain[0] != check_layers.API:
                odd.append((rel, line, ".".join(chain)))
                continue
            name = f"{chain[1]}.{chain[2]}"
            item = next((it for it in items if it[0] <= line <= it[1]), None)
            if test_file or (item is not None and item[2] == "test"):
                where, label = "test", (item[3] if item else "(file)")
            else:
                where, label = "code", (item[3] if item else "(top level)")
            uses.append((rel, line, name, ".".join(chain[3:]) or None, where, label))

    code_names = {u[2] for u in uses if u[4] == "code"}
    test_names = {u[2] for u in uses if u[4] == "test"}
    candidates = sorted(test_names - code_names)
    unused = sorted(set(api_names) - code_names - test_names)

    print("# S6-T19: the `core.api` names used in operations and interfaces, code against tests\n")
    print(f"Tree: {'commit ' + args.commit if args.commit else 'working tree'}. Read by "
          "`scripts/prototypes/s6t19/measure.py` with `scripts/check_layers.py`'s own reading.\n")
    print("## Summary\n")
    print(f"- `api` holds {len(api_names)} names in {len(api)} namespaces.")
    print(f"- Used by a non-test declaration of `ops/` or `interfaces/`: {len(code_names)}.")
    print(f"- Used only inside `test` blocks there (the candidates): {len(candidates)}"
          + (": " + ", ".join(f"`{c}`" for c in candidates) if candidates else "") + ".")
    print(f"- Used by neither: {len(unused)}" + (": " + ", ".join(f"`{c}`" for c in unused) if unused else "") + ".")
    print(f"- Uses read: {len(uses)} ({sum(1 for u in uses if u[4] == 'code')} code, "
          f"{sum(1 for u in uses if u[4] == 'test')} test).\n")

    print("## Every `api` name\n")
    print("`code` counts uses outside `test` blocks (with the declarations they sit in), `test` uses inside "
          "them (with the files). Class: `code` (kept by shipped code), `test only` (a candidate), `unused`.\n")
    print("| Name | Class | code | Code uses in (file: declarations) | test | Test uses in (file: count) |")
    print("|---|---|---:|---|---:|---|")
    for name in api_names:
        cu = [u for u in uses if u[2] == name and u[4] == "code"]
        tu = [u for u in uses if u[2] == name and u[4] == "test"]
        by_file = defaultdict(set)
        for u in cu:
            by_file[u[0]].add(u[5])
        code_where = "; ".join(f"`{f}`: " + ", ".join(f"`{d}`" for d in sorted(ds)) for f, ds in sorted(by_file.items()))
        tcount = defaultdict(int)
        for u in tu:
            tcount[u[0]] += 1
        test_where = ", ".join(f"`{f}` {c}" for f, c in sorted(tcount.items()))
        cls = "code" if cu else ("test only" if tu else "unused")
        print(f"| `{name}` | {cls} | {len(cu)} | {code_where} | {len(tu)} | {test_where} |")
    print()

    print("## The tests that use a candidate name\n")
    print("| File | Test | Candidate names it uses (line: name) |")
    print("|---|---|---|")
    per_test = defaultdict(list)
    for u in uses:
        if u[2] in candidates:
            per_test[(u[0], u[5])].append((u[1], u[2] + (("." + u[3]) if u[3] else "")))
    for (rel, label), lst in sorted(per_test.items()):
        print(f"| `{rel}` | {label} | " + ", ".join(f"{ln}: `{n}`" for ln, n in sorted(lst)) + " |")
    print()

    print("## Every test-block use of an `api` name, by file and test\n")
    print("| File | Test | Names (line: name) |")
    print("|---|---|---|")
    all_tests = defaultdict(list)
    for u in uses:
        if u[4] == "test":
            all_tests[(u[0], u[5])].append((u[1], u[2]))
    for (rel, label), lst in sorted(all_tests.items()):
        print(f"| `{rel}` | {label} | " + ", ".join(f"{ln}: `{n}`" for ln, n in sorted(lst)) + " |")
    print()
    print("## References that are not `api.NAMESPACE.NAME` (a namespace used whole, or a reading error)\n")
    if not odd:
        print("None.")
    for rel, line, chain in odd:
        print(f"- `{rel}:{line}`: `core.{chain}`")
    return 0


if __name__ == "__main__":
    sys.exit(main())

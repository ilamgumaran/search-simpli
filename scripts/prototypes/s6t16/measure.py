#!/usr/bin/env python3
"""S6-T16, What point 1: every `core` name the files outside the core use, by file and count.

    python3 -I scripts/prototypes/s6t16/measure.py [--root DIR] [--commit REV]

Read from Zig tokens (scripts/check_layers.py's tokenizer), so comments and strings
never count. In every `.zig` file of zig/src/ops/, zig/src/interfaces/ and
zig/src/tests/, a core name is reached in one of two ways:

- `@import("core").FILE.NAME` written inline;
- through an alias, `const A = @import("core").FILE;` (at the top level, or inside a
  block, where it is in scope from the binding to the end of that block), and then
  `A.NAME` with `A` not preceded by `.`.

`FILE.NAME` is one name. Where the alias is used without a member (passed whole),
the name is `FILE` alone. Each name is checked against the `pub` declarations of
zig/src/core/FILE.zig (`pub const`, `pub var`, `pub fn`, top level); a name that is
not one is listed apart (a reading error, which Zig would refuse). Each use is also
classed as in a `test` block or not, since the guard may treat tests apart.

The deeper chain `FILE.NAME.MEMBER` (`indexer.AnalyzerId.parse`) is counted under
`FILE.NAME` and listed separately. Prints Markdown tables. Not part of any library.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "scripts"))
import check_layers  # noqa: E402

FOLDERS = ("ops", "interfaces", "tests")


def pub_decls(text: str) -> dict[str, str]:
    """The top-level `pub const|var|fn NAME` of a Zig file: NAME -> const, var or fn."""
    toks = list(check_layers.tokens(text))
    out, depth = {}, 0
    for k, (kind, value, _) in enumerate(toks):
        if kind == "punct" and value in "([{":
            depth += 1
        elif kind == "punct" and value in ")]}":
            depth -= 1
        elif depth == 0 and kind == "word" and value == "pub" and k + 2 < len(toks):
            nxt = toks[k + 1]
            if nxt[0] == "word" and nxt[1] in ("const", "var", "fn") and toks[k + 2][0] == "word":
                out[toks[k + 2][1]] = nxt[1]
            elif nxt[0] == "word" and nxt[1] in ("inline", "extern", "export") and k + 3 < len(toks):
                if toks[k + 2][1] == "fn" and toks[k + 3][0] == "word":
                    out[toks[k + 3][1]] = "fn"
    return out


def block_end(toks, k):
    """For a token at index k, the index of the bracket closing its innermost enclosing
    one (len(toks) at the top level)."""
    depth = 0
    for j in range(k - 1, -1, -1):
        kind, value, _ = toks[j]
        if kind == "punct" and value in ")]}":
            depth += 1
        elif kind == "punct" and value in "([{":
            if depth == 0:
                return check_layers._match(toks, j) - 1
            depth -= 1
    return len(toks)


def test_ranges(text, toks):
    return [(start, end) for kind, _, start, end in check_layers.container_items(text, toks) if kind == "test"]


def uses(text: str):
    """(line, file, name, deeper, in_test) for every core name the file reaches."""
    toks = list(check_layers.tokens(text))
    tests = test_ranges(text, toks)
    in_test = lambda k: any(a <= k < b for a, b in tests)  # noqa: E731
    line_of = lambda k: text.count("\n", 0, toks[k][2]) + 1  # noqa: E731
    out = []
    aliases = []  # (alias, file, start, end, binding token range)
    binding_tokens = set()
    for line, target, problem, member, k in check_layers._import_calls(text, toks):
        if problem is not None or target != "core":
            continue
        # The tokens of `@import ( "core" ) . member`.
        close = check_layers._match(toks, k + 1)
        after = close + 2  # past `.` and member
        if member is None:
            raise SystemExit(f"line {line}: @import(\"core\") without a member; extend the script")
        binding = (k >= 3 and check_layers._seq(toks, k - 3, [("word", "const"), ("word", None), ("punct", "=")])
                   and after < len(toks) and toks[after][:2] == ("punct", ";"))
        if binding:
            alias = toks[k - 2][1]
            aliases.append((alias, member, k, block_end(toks, k)))
            binding_tokens.update(range(k - 3, after + 1))
            continue
        # Inline: @import("core").FILE.NAME[.MORE]
        if after + 1 < len(toks) and toks[after][:2] == ("punct", ".") and toks[after + 1][0] == "word":
            name = toks[after + 1][1]
            deeper = None
            if after + 3 < len(toks) and toks[after + 2][:2] == ("punct", ".") and toks[after + 3][0] == "word":
                deeper = toks[after + 3][1]
            out.append((line, member, name, deeper, in_test(k)))
        else:
            out.append((line, member, None, None, in_test(k)))
    for alias, file, start, end in aliases:
        for j in range(start, min(end, len(toks))):
            kind, value, offset = toks[j]
            if j in binding_tokens or kind != "word" or value != alias or text.startswith("@", offset):
                continue
            if j > 0 and toks[j - 1][:2] == ("punct", "."):
                continue  # a member or field named like the alias
            if j + 1 < len(toks) and toks[j + 1][:2] == ("punct", ":") and not (
                    j > 0 and toks[j - 1][:2] == ("punct", "=")):
                continue  # a field declaration or label
            if j + 2 < len(toks) and toks[j + 1][:2] == ("punct", ".") and toks[j + 2][0] == "word":
                name = toks[j + 2][1]
                deeper = None
                if j + 4 < len(toks) and toks[j + 3][:2] == ("punct", ".") and toks[j + 4][0] == "word":
                    deeper = toks[j + 4][1]
                out.append((line_of(j), file, name, deeper, in_test(j)))
            else:
                out.append((line_of(j), file, None, None, in_test(j)))
    return sorted(out, key=lambda r: (r[0], r[1], r[2] or "", r[3] or ""))


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


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=REPO)
    parser.add_argument("--commit", default=None, help="read the tree of this commit instead of the working tree")
    args = parser.parse_args(argv)
    tree = read_tree(args.root, args.commit)
    pubs = {rel[len("core/"):-len(".zig")]: pub_decls(text) for rel, text in tree.items()
            if rel.startswith("core/") and "/" not in rel[len("core/"):]}
    rows = []  # (group, file rel, line, name, deeper, in_test)
    bad = []
    for rel, text in tree.items():
        folder = rel.split("/", 1)[0]
        if folder not in FOLDERS:
            continue
        is_test_file = folder == "tests" or rel.endswith("_test.zig") or rel.endswith("_bench.zig")
        group = "cross-layer tests" if folder == "tests" else (
            f"{folder} (test file)" if is_test_file else folder)
        for line, file, name, deeper, in_test in uses(text):
            full = file if name is None else f"{file}.{name}"
            if file not in pubs:
                bad.append((rel, line, full, "no such core file"))
                continue
            if name is not None and name not in pubs[file]:
                bad.append((rel, line, full, f"not a pub declaration of core/{file}.zig"))
                continue
            rows.append((group, rel, line, full, deeper, in_test))

    def layer_rows(pred):
        return [r for r in rows if pred(r)]

    layer = lambda r: r[0] in ("ops", "interfaces")  # noqa: E731
    print("# S6-T16: the core names used outside the core\n")
    print(f"Tree: {'commit ' + args.commit if args.commit else 'working tree'}. "
          "Read by `scripts/prototypes/s6t16/measure.py`.\n")
    layer_files = [rel for rel in tree if rel.startswith("core/") and rel[len("core/"):].count("/") == 0
                   and not rel.endswith(("_test.zig", "_bench.zig"))
                   and rel not in ("core/core.zig", "core/nfc_dump.zig", "core/fastmem.zig")]
    print(f"For scale: the {len(layer_files)} core layer files reachable through `core.zig` (all but "
          f"`fastmem.zig`, the tests, benchmarks and the tool) hold "
          f"{sum(len(pubs[r[len('core/'):-len('.zig')]]) for r in layer_files)} top-level `pub` declarations.\n")
    print("## Summary\n")
    print("| Who | Files | Uses | Distinct names | Distinct core files |")
    print("|---|---:|---:|---:|---:|")
    groups = [
        ("operations and interfaces, all code", lambda r: layer(r)),
        ("operations and interfaces, outside `test` blocks", lambda r: layer(r) and not r[5]),
        ("operations and interfaces, inside `test` blocks only", None),
        ("`ops/`", lambda r: r[0] == "ops"),
        ("`interfaces/`", lambda r: r[0] == "interfaces"),
        ("`interfaces/` test file (`field_warnings_test.zig`)", lambda r: r[0] == "interfaces (test file)"),
        ("cross-layer tests (`tests/`)", lambda r: r[0] == "cross-layer tests"),
        ("everyone outside the core", lambda r: True),
    ]
    code_names = {r[3] for r in rows if layer(r) and not r[5]}
    test_only = {r[3] for r in rows if layer(r) and r[5]} - code_names
    for title, pred in groups:
        if pred is None:
            sel = [r for r in rows if layer(r) and r[5] and r[3] in test_only]
        else:
            sel = layer_rows(pred)
        names = {r[3] for r in sel}
        print(f"| {title} | {len({r[1] for r in sel})} | {len(sel)} | {len(names)} | "
              f"{len({n.split('.')[0] for n in names})} |")
    print()

    by_name = defaultdict(Counter)
    for r in rows:
        by_name[r[3]][r[1]] += 1
    lay_names = sorted({r[3] for r in rows if layer(r)})
    print("## Names used by operations and interfaces, by file and count\n")
    print("`code` counts uses outside `test` blocks, `tests` uses inside them; the files are the layer "
          "files of `ops/` and `interfaces/`. The last column counts the uses in `tests/` and in "
          "`interfaces/field_warnings_test.zig`.\n")
    print("| Name | Kind | code | tests | Files (uses) | Cross-layer tests (uses) |")
    print("|---|---|---:|---:|---|---:|")
    for name in lay_names:
        code = sum(1 for r in rows if layer(r) and r[3] == name and not r[5])
        tst = sum(1 for r in rows if layer(r) and r[3] == name and r[5])
        files = ", ".join(f"`{f}` {c}" for f, c in sorted(by_name[name].items()) if f.split("/")[0] in ("ops", "interfaces")
                          and not f.endswith("_test.zig"))
        other = sum(c for f, c in by_name[name].items() if f.split("/")[0] == "tests" or f.endswith("_test.zig"))
        file, _, decl = name.partition(".")
        kind = pubs[file].get(decl, "file") if decl else "file"
        print(f"| `{name}` | {kind} | {code} | {tst} | {files} | {other} |")
    print()
    test_names = sorted({r[3] for r in rows if not layer(r)} - set(lay_names))
    print("## Names used only by tests (`tests/` and `interfaces/field_warnings_test.zig`)\n")
    print("| Name | Uses | Files (uses) |")
    print("|---|---:|---|")
    for name in test_names:
        files = ", ".join(f"`{f}` {c}" for f, c in sorted(by_name[name].items()))
        print(f"| `{name}` | {sum(by_name[name].values())} | {files} |")
    print()
    print("## By file\n")
    print("| File | Uses | Distinct names |")
    print("|---|---:|---:|")
    by_file = defaultdict(list)
    for r in rows:
        by_file[r[1]].append(r[3])
    for rel in sorted(by_file):
        print(f"| `{rel}` | {len(by_file[rel])} | {len(set(by_file[rel]))} |")
    print()
    deeper = Counter((r[3], r[4]) for r in rows if layer(r) and r[4])
    print("## Deeper chains in operations and interfaces (`FILE.NAME.MEMBER`, counted under `FILE.NAME`)\n")
    print("| Chain | Uses |")
    print("|---|---:|")
    for (name, member), count in sorted(deeper.items()):
        print(f"| `{name}.{member}` | {count} |")
    print()
    print("## Reading errors (a use that is not a pub declaration)\n")
    if not bad:
        print("None.")
    for rel, line, full, why in bad:
        print(f"- `{rel}:{line}`: `{full}`: {why}")
    print()
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

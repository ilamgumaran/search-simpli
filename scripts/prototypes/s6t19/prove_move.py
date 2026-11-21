#!/usr/bin/env python3
"""S6-T19 rulings 1 and 2: only test blocks moved, with their names and bodies, and `core.api` only lost aliases.

    python3 -I scripts/prototypes/s6t19/prove_move.py MAIN HEAD

Reads both trees from git. Checks, and prints, that:
1. each moved test's block (found by its name with scripts/check_layers.py's `container_items`) is, in HEAD's new
   file, the same text as in MAIN's file, except for the import expressions listed in EDITS;
2. MAIN's file with that block (and the blank line after it) removed is HEAD's file, byte for byte;
3. `core/core.zig` at HEAD is MAIN's with exactly the lines in DROPPED removed, and nothing else;
4. `tests/root.zig` at HEAD is MAIN's with lines added only, the ones in ROOT_ADDED;
5. no other `.zig` file under zig/src/ differs, and the only new ones are the two test files.
Exit 0 when all hold.
"""
from __future__ import annotations

import difflib
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "scripts"))
import check_layers  # noqa: E402

MOVES = [
    ("ops/filename_response.zig", "tests/filename_response_test.zig",
     "filename results expose source-based match sections and readable citations"),
    ("interfaces/abi.zig", "tests/abi_index_folder_test.zig",
     "ss_index_folder lists every max trace and resets the list between calls"),
]
EDITS = {"tests/filename_response_test.zig": [('@import("core").api.analyzer_v2.analyzer_id',
                                               '@import("core").analyzer_v2.analyzer_id')]}
DROPPED = [
    "        /// Decode and check an encoded manifest. The value borrows `encoded`.",
    "        /// Errors (`ManifestError`): the core's format errors.",
    "        pub const decode = internal.manifest.decode;",
    "    /// The Unicode analyzer (`analyzer_v2.zig`).",
    "    pub const analyzer_v2 = struct {",
    "        /// Its id, as a manifest and a report name it: \"analyzer-v2\".",
    "        pub const analyzer_id = internal.analyzer_v2.analyzer_id;",
    "    };",
    "",
]
ROOT_ADDED = [
    "// S6-T19: tests moved here from beside ops/filename_response.zig and interfaces/abi.zig.",
    'pub const filename_response_test = @import("filename_response_test.zig");',
    'pub const abi_index_folder_test = @import("abi_index_folder_test.zig");',
    "    _ = filename_response_test;",
    "    _ = abi_index_folder_test;",
]


def show(rev, rel):
    out = subprocess.run(["git", "-C", str(REPO), "show", f"{rev}:zig/src/{rel}"], capture_output=True, text=True)
    return out.stdout if out.returncode == 0 else None


def files(rev):
    out = subprocess.run(["git", "-C", str(REPO), "ls-tree", "-r", "--name-only", rev, "--", "zig/src"],
                         check=True, capture_output=True, text=True).stdout.split()
    return {n[len("zig/src/"):] for n in out if n.endswith(".zig")}


def test_block(text, name):
    toks = list(check_layers.tokens(text))
    for kind, _, start, end in check_layers.container_items(text, toks):
        if kind == "test" and toks[start + 1][:2] == ("string", name):
            return toks[start][2], toks[end - 1][2] + 1
    raise SystemExit(f"no test {name!r}")


def removed_added(a, b):
    sm = difflib.SequenceMatcher(a=a, b=b, autojunk=False)
    rem, add = [], []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag in ("delete", "replace"):
            rem += a[i1:i2]
        if tag in ("insert", "replace"):
            add += b[j1:j2]
    return rem, add


def main(argv) -> int:
    main_rev, head_rev = argv[1], argv[2]
    ok = True

    def say(cond, msg):
        nonlocal ok
        ok = ok and cond
        print(f"{'ok  ' if cond else 'FAIL'} {msg}")

    for src, dst, name in MOVES:
        before, after_src, after_dst = show(main_rev, src), show(head_rev, src), show(head_rev, dst)
        a0, a1 = test_block(before, name)
        b0, b1 = test_block(after_dst, name)
        block, moved = before[a0:a1], after_dst[b0:b1]
        expected = block
        for old, new in EDITS.get(dst, []):
            say(expected.count(old) == 1, f"{src}: the test holds `{old}` once (an import expression)")
            expected = expected.replace(old, new)
        say(moved == expected, f"{dst}: test {name!r} is {src}'s block ({block.count(chr(10)) + 1} lines), "
                               f"text equal{' apart from ' + str(len(EDITS[dst])) + ' import expression' if dst in EDITS else ''}")
        say(before[a1:a1 + 2] == "\n\n", f"{src}: a blank line follows the block at {main_rev}")
        say(before[:a0] + before[a1 + 2:] == after_src,
            f"{src}: {main_rev}'s file less that block and its blank line is {head_rev}'s, byte for byte")
        header = after_dst[:b0]
        print(f"     {dst}, before the test (doc comment and imports):")
        for line in header.rstrip("\n").split("\n"):
            print(f"       {line}")
        say(after_dst[b1:] == "\n", f"{dst}: nothing follows the test")

    rem, add = removed_added(show(main_rev, "core/core.zig").split("\n"), show(head_rev, "core/core.zig").split("\n"))
    say(sorted(rem) == sorted(DROPPED) and add == [], f"core/core.zig: {len(rem)} lines removed (the two aliases, their "
                                                      f"doc comments, the namespace analyzer_v2), {len(add)} added")
    rem, add = removed_added(show(main_rev, "tests/root.zig").split("\n"), show(head_rev, "tests/root.zig").split("\n"))
    say(rem == [] and add == ROOT_ADDED, f"tests/root.zig: {len(add)} lines added (two names, their test-block lines, "
                                         f"a comment), {len(rem)} removed")

    fm, fh = files(main_rev), files(head_rev)
    say(fh - fm == {dst for _, dst, _ in MOVES} and fm - fh == set(),
        f"new .zig files: {sorted(fh - fm)}; removed: {sorted(fm - fh)}")
    touched = {src for src, _, _ in MOVES} | {"core/core.zig", "tests/root.zig"}
    other = sorted(rel for rel in fm & fh if rel not in touched and show(main_rev, rel) != show(head_rev, rel))
    say(other == [], f"every other .zig file under zig/src/ ({len(fm & fh) - len(touched)}) is byte-identical"
                     + (f"; differ: {other}" if other else ""))
    print("all hold:", "yes" if ok else "NO")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))

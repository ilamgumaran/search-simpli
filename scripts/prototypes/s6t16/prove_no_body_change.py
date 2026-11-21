#!/usr/bin/env python3
"""S6-T16, ruling 1: a mechanical proof that no function body changed.

    python3 -I scripts/prototypes/s6t16/prove_no_body_change.py [--base REV] [--head REV]

Compares every `.zig` file under zig/ at --base (default 10f3d40, the task's `main`)
with --head (a commit, or the working tree when omitted), as Zig tokens
(scripts/check_layers.py's tokenizer: comments, doc comments and whitespace give no
token, so they are free to change). After exactly these edits, written out below and
nothing else, the two token streams must be equal, file by file:

1. In zig/src/ops/ and zig/src/interfaces/, `@import("core").api.` is read back as
   `@import("core").` (the import lines now name the public part).
2. In those folders, whole declarations `const NAME = @import("core").FILE;` that the
   change removed are listed by name (REMOVED); each must be absent from --head,
   present at --base, and not mentioned anywhere else in its file at --base.
3. In zig/src/core/core.zig, the added top-level declarations `pub const api = struct
   { ... };` and `const internal = @This();` are removed before comparing; every
   declaration inside `api` must be an alias `pub const N = internal.F.N;`.

Every other `.zig` file must have the same tokens. A function body is a token run of
its file, so equal streams mean no body changed. Prints a report; exits 1 on any
difference. Not part of any library.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "scripts"))
import check_layers  # noqa: E402

LAYER_FOLDERS = ("zig/src/ops/", "zig/src/interfaces/")
CORE_ROOT = "zig/src/core/core.zig"
REMOVED = {
    "zig/src/interfaces/abi.zig": ["publication"],
    "zig/src/interfaces/main.zig": ["publication"],
}


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(REPO), *args], check=True, capture_output=True, text=True).stdout


def tree(rev: str | None) -> dict[str, str]:
    if rev is None:
        return {p.relative_to(REPO).as_posix(): p.read_text(encoding="utf-8")
                for p in sorted((REPO / "zig").rglob("*.zig")) if ".zig-cache" not in p.parts
                and "zig-out" not in p.parts}
    names = [n for n in git("ls-tree", "-r", "--name-only", rev, "--", "zig").split() if n.endswith(".zig")]
    return {n: git("show", f"{rev}:{n}") for n in names}


def toks(text: str):
    return [(kind, value) for kind, value, _ in check_layers.tokens(text)]


def strip_api(stream):
    """Read `@import ( "core" ) . api .` back as `@import ( "core" ) .`; and count them."""
    out, i, n = [], 0, 0
    head = [("builtin", "@import"), ("punct", "("), ("string", "core"), ("punct", ")"), ("punct", ".")]
    while i < len(stream):
        if stream[i:i + 5] == head and stream[i + 5:i + 7] == [("word", "api"), ("punct", ".")]:
            out += head
            i += 7
            n += 1
        else:
            out.append(stream[i])
            i += 1
    return out, n


def remove_decl(text: str, name: str):
    """The tokens of text without the top-level `const name = @import("core").X;`, and X."""
    stream = list(check_layers.tokens(text))
    for kind, decl, start, end in check_layers.container_items(text, stream):
        if kind == "decl" and decl == name:
            body = [(k, v) for k, v, _ in stream[start:end]]
            if body[:3] != [("word", "const"), ("word", name), ("punct", "=")] or \
                    body[3:8] != [("builtin", "@import"), ("punct", "("), ("string", "core"), ("punct", ")"),
                                  ("punct", ".")] or len(body) != 10 or body[-1] != ("punct", ";"):
                raise SystemExit(f"{name}: not a `const {name} = @import(\"core\").X;` declaration")
            rest = [(k, v) for k, v, _ in stream[:start] + stream[end:]]
            if ("word", name) in rest:
                raise SystemExit(f"{name}: mentioned elsewhere in its file, so it was used")
            return rest, body[8][1]
    raise SystemExit(f"{name}: no such top-level declaration")


def core_root_without_api(text: str):
    stream = list(check_layers.tokens(text))
    items = check_layers.container_items(text, stream)
    drop, aliases = [], 0
    for kind, name, start, end in items:
        if kind == "decl" and name == "api":
            drop.append((start - 1, end))  # `pub` precedes the `const` the item starts at
            api, problems = check_layers.core_api(text)
            if problems:
                raise SystemExit(f"api: {problems}")
            aliases = sum(len(names) for _, names in api.values())
        elif kind == "decl" and name == "internal":
            if [(k, v) for k, v, _ in stream[start:end]] != [
                    ("word", "const"), ("word", "internal"), ("punct", "="), ("builtin", "@This"), ("punct", "("),
                    ("punct", ")"), ("punct", ";")]:
                raise SystemExit("internal: not `const internal = @This();`")
            drop.append((start, end))
    keep = [(k, v) for idx, (k, v, _) in enumerate(stream) if not any(a <= idx < b for a, b in drop)]
    return keep, aliases, len(drop)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="10f3d40")
    parser.add_argument("--head", default=None, help="a commit; the working tree when omitted")
    args = parser.parse_args(argv)
    base, head = tree(args.base), tree(args.head)
    print(f"# S6-T16: no function body changed\n\nBase `{args.base}`, head "
          f"`{args.head or 'working tree'}`; read by `scripts/prototypes/s6t16/prove_no_body_change.py`.\n")
    bad = []
    if set(base) != set(head):
        bad.append(f"the .zig files differ: only base {sorted(set(base) - set(head))}, "
                   f"only head {sorted(set(head) - set(base))}")
    rows = []
    for rel in sorted(set(base) & set(head)):
        old_text, new_text = base[rel], head[rel]
        text_changed = old_text != new_text
        old, new = toks(old_text), toks(new_text)
        note, rewritten = "", 0
        if rel.startswith(LAYER_FOLDERS):
            new, rewritten = strip_api(new)
            for name in REMOVED.get(rel, []):
                old, member = remove_decl(old_text, name)
                note += f"removed unused `const {name} = @import(\"core\").{member};`; "
        elif rel == CORE_ROOT:
            new, aliases, dropped = core_root_without_api(new_text)
            note = f"`api` ({aliases} aliases) and `internal` removed before comparing ({dropped} declarations); "
        same = old == new
        if text_changed or not same:
            rows.append((rel, rewritten, note.rstrip("; ") or "-", "equal" if same else "DIFFERENT"))
        if not same:
            bad.append(rel)
    print("Files whose text changed (every other .zig file is byte-identical):\n")
    print("| File | `@import(\"core\").api.` read back | Other edits undone | Tokens after the edits |")
    print("|---|---:|---|---|")
    for rel, n, note, verdict in rows:
        print(f"| `{rel}` | {n} | {note} | {verdict} |")
    print(f"\n{len(base)} .zig files at base, {len(head)} at head; {len(rows)} changed text; "
          f"{sum(r[1] for r in rows)} import references rewritten.\n")
    if bad:
        print("**FAIL**: " + "; ".join(bad))
        return 1
    print("**OK**: after the listed edits every file's tokens are equal, so no function body, test or "
          "declaration other than those listed changed; only comments, doc comments and whitespace did.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""S6-T15 ruling 3: the changed Zig files differ from BASE in comments only.

For every `.zig` file that differs between BASE and the working tree (git diff):
- its code tokens (scripts/check_layers.py's tokenizer, which drops `//`, `///`
  and `//!` comments and keeps every string, character and multiline-string
  literal) are equal, token by token, kind, value and position in the line count;
- it has the same number of lines, and every line that differs is a comment line
  on both sides (nothing but whitespace before its `//`);
- for the Python generator, its tokens (Python's tokenize) differ in exactly one
  STRING token, the regenerate line it emits.

Usage: python3 -I scripts/prototypes/s6t15/prove_comments.py BASE   (from the repository root)
Exit 1 on any difference beyond comments."""
import io
import subprocess
import sys
import tokenize
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))
import check_layers  # noqa: E402


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True).stdout


def code_tokens(text):
    return [(kind, value, text.count("\n", 0, offset)) for kind, value, offset in check_layers.tokens(text)]


def main(base):
    changed = git("diff", "--name-only", base, "--").decode().split()
    bad = 0
    zig = [f for f in changed if f.endswith(".zig")]
    for rel in zig:
        old = git("show", f"{base}:{rel}").decode("utf-8")
        new = (ROOT / rel).read_text(encoding="utf-8")
        old_lines, new_lines = old.split("\n"), new.split("\n")
        same_tokens = code_tokens(old) == code_tokens(new)
        differing = [(i + 1, a, b) for i, (a, b) in enumerate(zip(old_lines, new_lines)) if a != b]
        comment_only = all(a.lstrip().startswith("//") and b.lstrip().startswith("//") for _, a, b in differing)
        ok = same_tokens and len(old_lines) == len(new_lines) and comment_only
        bad += not ok
        print(f"{'ok ' if ok else 'BAD'} {rel}: {len(code_tokens(new))} code tokens, equal: {same_tokens}; "
              f"{len(new_lines)} lines on both sides: {len(old_lines) == len(new_lines)}; "
              f"{len(differing)} line(s) differ, all comment lines: {comment_only}")
        for number, a, b in differing:
            print(f"    line {number}\n      - {a}\n      + {b}")
    for rel in [f for f in changed if f == "scripts/gen_unicode_tables.py"]:
        def toks(text):
            return [(t.type, t.string, t.start[0]) for t in tokenize.generate_tokens(io.StringIO(text).readline)]
        old = toks(git("show", f"{base}:{rel}").decode("utf-8"))
        new = toks((ROOT / rel).read_text(encoding="utf-8"))
        diff = [(a, b) for a, b in zip(old, new) if a != b]
        ok = len(old) == len(new) and len(diff) == 1 and diff[0][0][0] == diff[0][1][0] == tokenize.STRING
        bad += not ok
        print(f"{'ok ' if ok else 'BAD'} {rel}: {len(new)} Python tokens on both sides: {len(old) == len(new)}; "
              f"{len(diff)} differ, a STRING token: {ok}")
        for a, b in diff:
            print(f"    line {a[2]}\n      - {a[1]}\n      + {b[1]}")
    print(f"{len(zig)} Zig file(s) compared; {bad} with a change beyond comments")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "main"))

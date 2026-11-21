"""Verifier's own token comparison of every .zig file, base vs head (S6-T16).

Independent of the builder's prove_no_body_change.py and of check_layers.tokens.
Tokens: identifiers/numbers, string literals (raw), char literals, multiline string
lines, builtins, single punctuation chars. Comments (incl. doc comments) skipped.

Allowed differences, each matched exactly:
  A. in ops/ and interfaces/: the two tokens `api .` inserted right after
     `@import ( "core" ) .`
  B. in interfaces/abi.zig and interfaces/main.zig: deletion of exactly
     `const publication = @import ( "core" ) . publication ;` and the name
     `publication` appearing nowhere else in the file (base or head)
  C. in core/core.zig: insertion of `pub const api = struct { ... } ;` (whole
     balanced block) and of `const internal = @This ( ) ;`
Anything else is printed as UNEXPLAINED.
"""
import difflib
import re
import subprocess
import sys

REPO = sys.argv[1]
BASE, HEAD = sys.argv[2], sys.argv[3]

WORD = re.compile(r"[A-Za-z0-9_]+")


def toks(text):
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1
        elif text.startswith("//", i):
            e = text.find("\n", i)
            i = n if e < 0 else e
        elif text.startswith("\\\\", i):
            e = text.find("\n", i)
            e = n if e < 0 else e
            out.append(("ms", text[i:e]))
            i = e
        elif c in "\"'" or text.startswith('@"', i):
            q = i + 1 if c == "@" else i
            j = q + 1
            while j < n and text[j] != text[q]:
                j += 2 if text[j] == "\\" else 1
            out.append(("s", text[i:j + 1]))
            i = j + 1
        elif c == "@":
            m = WORD.match(text, i + 1)
            out.append(("b", "@" + m.group(0)))
            i = m.end()
        else:
            m = WORD.match(text, i)
            if m:
                out.append(("w", m.group(0)))
                i = m.end()
            else:
                out.append(("p", c))
                i += 1
    return out


def show(seq):
    return " ".join(v for _, v in seq)


def git(*a):
    return subprocess.run(["git", "-C", REPO, *a], capture_output=True, text=True, check=True).stdout


def files(rev):
    return [f for f in git("ls-tree", "-r", "--name-only", rev).splitlines() if f.endswith(".zig")]


IMPORT_CORE = [("b", "@import"), ("p", "("), ("s", '"core"'), ("p", ")"), ("p", ".")]
PUBLICATION = [("w", "const"), ("w", "publication"), ("p", "="), *IMPORT_CORE, ("w", "publication"), ("p", ";")]


def strip_api_block(t):
    """Remove `pub const api = struct {...};` and `const internal = @This();` from core.zig."""
    out, i, removed = [], 0, []
    while i < len(t):
        if t[i:i + 5] == [("w", "pub"), ("w", "const"), ("w", "api"), ("p", "="), ("w", "struct")] and t[i + 5] == ("p", "{"):
            d, j = 0, i + 5
            while True:
                if t[j] == ("p", "{"):
                    d += 1
                elif t[j] == ("p", "}"):
                    d -= 1
                    if d == 0:
                        break
                j += 1
            assert t[j + 1] == ("p", ";")
            removed.append(("api block", j + 2 - i))
            i = j + 2
            continue
        if t[i:i + 7] == [("w", "const"), ("w", "internal"), ("p", "="), ("b", "@This"), ("p", "("), ("p", ")"), ("p", ";")]:
            removed.append(("internal", 7))
            i += 7
            continue
        out.append(t[i])
        i += 1
    return out, removed


def strip_api_refs(t):
    out, i, n = [], 0, 0
    while i < len(t):
        if t[i:i + 5] == IMPORT_CORE and t[i + 5:i + 7] == [("w", "api"), ("p", ".")]:
            out += t[i:i + 5]
            i += 7
            n += 1
            continue
        out.append(t[i])
        i += 1
    return out, n


def strip_publication(t):
    out, i, n = [], 0, 0
    while i < len(t):
        if t[i:i + len(PUBLICATION)] == PUBLICATION:
            i += len(PUBLICATION)
            n += 1
            continue
        out.append(t[i])
        i += 1
    return out, n


bf, hf = files(BASE), files(HEAD)
print(f"base {BASE}: {len(bf)} .zig files; head {HEAD}: {len(hf)} .zig files")
if set(bf) != set(hf):
    print("FILE SET DIFFERS", sorted(set(bf) ^ set(hf)))
total_refs = 0
bad = 0
changed = 0
for f in sorted(set(bf) & set(hf)):
    b = toks(git("show", f"{BASE}:{f}"))
    h = toks(git("show", f"{HEAD}:{f}"))
    if b == h:
        continue
    changed += 1
    notes = []
    if f == "zig/src/core/core.zig":
        h, removed = strip_api_block(h)
        notes.append(f"removed from head: {removed}")
    if "/ops/" in f or "/interfaces/" in f:
        h, n = strip_api_refs(h)
        total_refs += n
        notes.append(f"{n} api. refs undone")
        bn = sum(1 for k in range(len(b)) if b[k:k + 5] == IMPORT_CORE)
        notes.append(f"{bn} @import(\"core\"). in base")
    if f in ("zig/src/interfaces/abi.zig", "zig/src/interfaces/main.zig"):
        b2, n = strip_publication(b)
        uses_b = sum(1 for x in b2 if x == ("w", "publication"))
        uses_h = sum(1 for x in h if x == ("w", "publication"))
        notes.append(f"publication import removed from base copy: {n}; other 'publication' words base={uses_b} head={uses_h}")
        b = b2
    ok = b == h
    print(f"{f}: {'EQUAL after allowed edits' if ok else 'UNEXPLAINED DIFF'}; " + "; ".join(notes))
    if not ok:
        bad += 1
        sm = difflib.SequenceMatcher(a=b, b=h, autojunk=False)
        for op, i1, i2, j1, j2 in sm.get_opcodes():
            if op != "equal":
                print(f"   {op}: base[{show(b[i1:i2])[:200]}] head[{show(h[j1:j2])[:200]}]")
print(f"changed files {changed}; api refs undone {total_refs}; unexplained {bad}")

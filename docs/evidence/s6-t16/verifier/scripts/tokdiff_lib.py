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

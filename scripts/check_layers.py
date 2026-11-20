#!/usr/bin/env python3
"""The layer boundary of `zig/src/` (S6-T1, S6-T14; docs/layers.md).

Each layer has a folder and is one Zig module (zig/build.zig): `core/` is the module
`core` (root `core/core.zig`), `ops/` is `operations` (root `ops/operations.zig`), and
`interfaces/` holds the ways in (its root `interfaces/interfaces.zig` serves the
tests). `tests/` holds the tests, benchmarks and tools that cross layers, and the
root of their test build. Every Zig file under `zig/src/` is one of:

- a layer's file, assigned in FILES (core, operations or interfaces), in its
  layer's folder;
- a module root, in MODULE_ROOTS, in its layer's folder;
- a test, a benchmark or a tool (EXEMPT_PATTERNS, EXEMPT_FILES): beside its subject
  in a layer's folder when it imports that layer's files only, in `tests/` when it
  crosses layers.

The rules, read from each file's `@import(...)` operands:

- a `.zig` import never leaves the importing file's folder: another layer is
  reached through its module, `@import("core").engine`, never by path;
- a named module (not a file) is one listed in MODULES, imported only by the
  folders it allows: `core` by operations, interfaces and tests; `operations` by
  interfaces and tests; `interfaces` by tests only; a test, benchmark or tool in a
  layer's folder is held to that layer;
- `@import("core").name` (and the other two) names a `pub const` of the module's
  root, and no layer's file imports a test, benchmark or tool through it;
- an interface file imports another interface file only where ALLOWED lists the pair;
- no layer's file imports a test, benchmark or tool file.

Imports are read from the whole file as Zig tokens, so comments and string
contents are never read as code, and an `@import` may span lines, carry spaces and
a trailing comma. Each `.zig` target is resolved against the importing file's
real directory; a target outside `zig/src/`, or naming no file there, fails, as
does an operand Zig would not accept (anything but one string literal).

The checker also fails when a file sits outside its layer's folder, or outside
the four folders, when a file of `zig/src/` is neither assigned, a module root nor
exempt, when an assigned or exempt name no longer exists, when an ALLOWED pair no
longer occurs, and when the generated block of docs/layers.md differs from these
tables (`--write-doc` rewrites that block from them, so the document and the
checker cannot disagree silently).

Every test runs (S6-T15). A Zig test build runs the tests of its root module's
files only, so the checker fails, naming the file, when a file holding a `test`
declaration is reached from no step of `zig build test`: from a step's root
(BUILD_ROOTS, which must list exactly the `"src/....zig"` roots zig/build.zig names)
it follows the `.zig` path imports a test build compiles (test_build_reads),
never an import through a module. It also fails when a module root leaves out a
layer file or a test of its folder, as a `pub const` or in its test-build
`comptime` block, and when the steps zig/build.zig's structure gives
(build_test_steps) are not the ones BUILD_ROOTS lists. The reading of Zig is not
exact; scripts/check_test_counts.py, which compares each step's total with a real
`zig build test --summary all`, is the authority (docs/layers.md, "What it cannot
see").

Usage (from anywhere; no dependencies):

    python3 scripts/check_layers.py              # check; exit 1 on any problem
    python3 scripts/check_layers.py --write-doc  # regenerate docs/layers.md's block
    python3 scripts/check_layers.py --root DIR   # check another copy of the repository
    python3 scripts/check_layers.py --list-tests # also print which step runs each file's tests

Every problem is printed on its own line as `path:line: message`.
"""

from __future__ import annotations

import argparse
import fnmatch
import posixpath
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SRC = "zig/src"
DOC = "docs/layers.md"

LAYER_ORDER = ("core", "operations", "interfaces")
# Each layer's folder under zig/src/ (S6-T14), and the folder of the tests, benchmarks
# and tools that cross layers. A file in a layer's folder is compiled in that layer's
# module, so it is held to that layer's rule whether it is assigned or exempt.
FOLDERS = {"core": "core", "operations": "ops", "interfaces": "interfaces"}
TESTS = "tests"
# Who may import whom, lowest first: a file ranks as its folder's layer; tests/ above all.
RANKS = LAYER_ORDER + (TESTS,)
MAY_IMPORT = {
    "core": "core only",
    "operations": "core and operations",
    "interfaces": "core and operations; another interface only as an allowed pair",
}

# Path relative to zig/src -> (layer, what the file holds).
FILES = {
    # core: formats, analysis, indexing, ranking, the loaded generation
    "core/analysis.zig": ("core", "`analyzer-v1`, the ASCII tokenizer"),
    "core/analyzer_v2.zig": ("core", "`analyzer-v2`, Unicode tokenization (NFC, case folding, letters and digits)"),
    "core/apply.zig": ("core", "`apply_changes`: host-fed changes published as the next generation"),
    "core/benchmark.zig": ("core", "the synthetic ranking benchmark behind `searchd benchmark`"),
    "core/checksum.zig": ("core", "section integrity checksums"),
    "core/chunker.zig": ("core", "`line-window-v1` and the chunker chosen by path"),
    "core/chunker_md.zig": ("core", "`md-section-v1`, the Markdown chunker"),
    "core/engine.zig": ("core", "the opened generation: search, evidence and reads"),
    "core/fastmem.zig": ("core", "the library's own `memcpy`, `memmove` and `memset`"),
    "core/filename_field.zig": ("core", "the file-name channel: catalog, lexical section, search"),
    "core/find.zig": ("core", "`find`: exact words and phrases over one generation"),
    "core/fold.zig": ("core", "word-form groups: the fold key and the key map"),
    "core/fuzzy.zig": ("core", "`fuzzy-v1`, misspelling tolerance at query time"),
    "core/generation_alloc.zig": ("core", "the next free generation number of a directory"),
    "core/hybrid.zig": ("core", "documents, search options, scope masks, lexical and vector fusion"),
    "core/importer.zig": ("core", "imports an interchange snapshot written by the Python reference"),
    "core/incremental_state.zig": ("core", "`INDEX-STATE.json`, the per-file state of updates"),
    "core/indexer.zig": ("core", "native folder indexing: walk, read, chunk, publish"),
    "core/lexical_build.zig": ("core", "a postings index from tokenized documents, for any analyzer"),
    "core/lexical_segment.zig": ("core", "the lexical section format (`HYBLEX`)"),
    "core/lifecycle.zig": ("core", "the writer lock, generation retention and pruning"),
    "core/manifest.zig": ("core", "the generation manifest"),
    "core/nfc.zig": ("core", "Unicode normalization form C"),
    "core/postings.zig": ("core", "the inverted index, positions and sparse BM25 scoring"),
    "core/publication.zig": ("core", "atomic publication and recovery"),
    "core/scope.zig": ("core", "roots, request scope and visible-scope statistics"),
    "core/scoring.zig": ("core", "BM25, cosine similarity and reciprocal-rank fusion"),
    "core/segment.zig": ("core", "the documents section format (`HYBSEG`)"),
    "core/segment_v5.zig": ("core", "documents record v5: the file table and compact records (`HYBSEG01` version 5)"),
    "core/snapshot_open.zig": ("core", "opens a published generation for querying"),
    "core/source.zig": ("core", "the source section (`HYBSRC`): file bytes and line maps"),
    "core/source_v2.zig": ("core", "the source section v2 (`HYBSRC02`): files rebuilt from chunks and residual bytes"),
    "core/state_section.zig": ("core", "the recovery-state section (`HYBSTATE`)"),
    "core/title_field.zig": ("core", "`title-field-v1`: folder and file names as a title"),
    "core/unicode_tables.zig": ("core", "generated Unicode 13.0.0 tables (`scripts/gen_unicode_tables.py`)"),
    "core/verb_forms.zig": ("core", "the verb-form rule of the fold groups"),
    # operations: the seam every interface calls
    "ops/filename_response.zig": ("operations", "the result object of `filename` and `both` searches, for JSON-RPC, the CLI and the C ABI"),
    "ops/ops.zig": ("operations", "the folder-knowledge operations as canonical JSON (`find`, `outline`, `read_span`, `list_files`, `index_status`, `evidence`, `apply_changes`)"),
    "ops/report.zig": ("operations", "the tail of a query report: `warnings`, `request`, `profile`"),
    "ops/service.zig": ("operations", "the scoped service over an opened generation: search, status, listings, reads"),
    # interfaces: the ways in
    "interfaces/abi.zig": ("interfaces", "the C ABI (`ss_*`; `zig/include/search_simpli.h`), under the Dart binding"),
    "interfaces/cli.zig": ("interfaces", "`searchd` commands and their arguments"),
    "interfaces/main.zig": ("interfaces", "the `searchd` entry: runs a CLI command, `serve` (stdio or loopback HTTP) or `mcp`"),
    "interfaces/mcp.zig": ("interfaces", "`searchd mcp`: the Model Context Protocol server over stdio"),
    "interfaces/rpc.zig": ("interfaces", "JSON-RPC 2.0 dispatch for `searchd serve`"),
}

# A module's root (zig/build.zig) -> (layer, module name, what it is). It holds only
# `pub const NAME = @import("NAME.zig");` for files of its own folder and a reference
# to them made in a test build; it is the one layer file that may name a test.
MODULE_ROOTS = {
    "core/core.zig": ("core", "core", "the module `core`: every core file but `fastmem.zig`, and every core test"),
    "ops/operations.zig": ("operations", "operations", "the module `operations` (it imports `core`): every operations file"),
    "interfaces/interfaces.zig": ("interfaces", "interfaces", "the module `interfaces`, for the tests in `tests/`: every interface file but `main.zig`, and `field_warnings_test.zig`"),
}

# Tests, benchmarks and tools: accounted for by pattern or by path, and placed by the
# rule above (beside their subject when they import one layer's files, else tests/).
EXEMPT_PATTERNS = (
    ("*_test.zig", "a test: named in its folder's module root, or reached from the test block of `tests/root.zig`, so that its folder's step of `zig build test` runs it (or run alone with `zig test`)"),
    ("*_bench.zig", "a benchmark, run by hand with `zig run` (zig/README.md)"),
)
EXEMPT_FILES = {
    "tests/root.zig": "the root of the cross-layer tests' step of `zig build test`: names every module and every test in `tests/`",
    "core/nfc_dump.zig": "a test tool for `scripts/nfc_compare.py`, in no build",
}

# (importer, imported), both paths relative to zig/src -> (kind, why).
# kind "entry": by design; kind "debt": to remove (docs/journey/03-next.md).
ALLOWED = {
    ("interfaces/main.zig", "interfaces/cli.zig"): ("entry", "the executable parses its command line with the CLI's parser"),
    ("interfaces/main.zig", "interfaces/rpc.zig"): ("entry", "the executable runs `serve`, the JSON-RPC server"),
    ("interfaces/main.zig", "interfaces/mcp.zig"): ("entry", "the executable runs `mcp`, the MCP server"),
    ("interfaces/mcp.zig", "interfaces/cli.zig"): ("debt", "`cli.McpArgs`, the parsed `searchd mcp` arguments"),
    ("interfaces/mcp.zig", "interfaces/rpc.zig"): ("debt", "`rpc.Generation` (open and reload) and `rpc.errorCodeOf`"),
    ("interfaces/abi.zig", "interfaces/rpc.zig"): ("debt", "`rpc.parseMode` and `rpc.writeSearchResultValueWith`, the `ss_query` result writer"),
}

# Imports that are not files: `std`, `builtin`, the layers' modules and the options
# zig/build.zig supplies (`addOptions`). Name -> (the lowest of RANKS that may import
# it, or None for any; what it is). Any other name is reported, so a new
# build-supplied module is placed here on purpose.
MODULES = {
    "std": (None, "the Zig standard library"),
    "builtin": (None, "the compilation's target and options"),
    "core": ("operations", "the core layer, `core/core.zig` (S6-T14)"),
    "operations": ("interfaces", "the operations layer, `ops/operations.zig` (S6-T14)"),
    "interfaces": ("tests", "the interfaces, `interfaces/interfaces.zig`, for the cross-layer tests (S6-T14)"),
    "build_options": ("interfaces", "`contracts_version`, read from `contracts/CONTRACTS_VERSION` by `zig/build.zig`"),
    "tool_schemas": ("interfaces", "the MCP tools' JSON schemas from `contracts/tools/`, read by `zig/build.zig`"),
}
LAYER_MODULES = {name: rel for rel, (_, name, _) in MODULE_ROOTS.items()}

# Every Zig file zig/build.zig names as the root of a compilation (`b.path("src/...")`),
# relative to zig/src -> (the step of `zig build test` it is the root of, or None, what it
# roots). The checker fails when zig/build.zig names a file this table lacks, or the
# table a file zig/build.zig does not name (S6-T15).
BUILD_ROOTS = {
    "core/core.zig": ("core", "the module `core`, and the test step `core`"),
    "ops/operations.zig": ("operations", "the module `operations`, and the test step `operations`"),
    "interfaces/interfaces.zig": ("interfaces", "the module `interfaces` (for `tests/`), and the test step `interfaces`"),
    "tests/root.zig": ("tests", "the test step `tests`: the cross-layer tests"),
    "core/fastmem.zig": ("fastmem", "the `fastmem` object, and its own test step (`run test` in the Build Summary)"),
    "interfaces/main.zig": (None, "the `searchd` executable"),
    "interfaces/abi.zig": (None, "the C ABI libraries, and the library of `zig build test-abi`"),
}
# The name the Build Summary of `zig build test --summary all` prints after `run test`
# for a step, where it is not the step's own name: zig/build.zig compiles fastmem's
# tests with no `.name` (S6-T15 rework; scripts/check_test_counts.py matches by it).
STEP_LABELS = {"fastmem": ""}


def step_label(step: str) -> str:
    """What the Build Summary prints after `run test` for a step of BUILD_ROOTS."""
    return STEP_LABELS.get(step, step)


# Files of a layer's folder that its module root leaves out: each is the root of a
# compilation of its own (BUILD_ROOTS) and is never compiled as part of the module.
OUTSIDE_MODULE = {
    "core/fastmem.zig": "compiled as an object of its own, with its own test step",
    "interfaces/main.zig": "the `searchd` executable's root; it holds no test",
}
BUILD = "zig/build.zig"
BEGIN = "<!-- BEGIN generated by scripts/check_layers.py --write-doc: edit the script, not this block -->"
END = "<!-- END generated by scripts/check_layers.py -->"

_WORD = re.compile(r"[A-Za-z0-9_]+")
_ESCAPE = re.compile(r"\\(?:x([0-9A-Fa-f]{2})|u\{([0-9A-Fa-f]+)\}|(.))", re.S)
_SIMPLE_ESCAPES = {"n": "\n", "r": "\r", "t": "\t", "\\": "\\", "'": "'", '"': '"'}


def _decode(raw: str):
    """The value of a Zig string literal's body, or None when an escape is invalid."""
    bad = []

    def one(match):
        hex2, uni, ch = match.groups()
        if hex2 is not None:
            return chr(int(hex2, 16))
        if uni is not None:
            return chr(int(uni, 16)) if int(uni, 16) <= 0x10FFFF else bad.append(uni) or ""
        if ch in _SIMPLE_ESCAPES:
            return _SIMPLE_ESCAPES[ch]
        bad.append(ch)
        return ""

    value = _ESCAPE.sub(one, raw)
    return None if bad else value


def tokens(text: str):
    """Zig tokens as (kind, value, offset): `builtin` (`@name`), `string` (a
    one-line string literal's raw body), `mstring` (one `\\\\` line of a multiline
    string literal), `char`, `word`, `punct`. Comments (`//`, `///`, `//!`) and
    whitespace give no token, so text inside them is never read as code."""
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch.isspace():
            i += 1
        elif text.startswith("//", i):
            end = text.find("\n", i)
            i = n if end < 0 else end
        elif text.startswith("\\\\", i):
            end = text.find("\n", i)
            end = n if end < 0 else end
            yield "mstring", text[i + 2 : end], i
            i = end
        elif ch in "\"'" or (ch == "@" and text.startswith('@"', i)):
            start = i
            quote_at = i + 1 if ch == "@" else i
            quote = text[quote_at]
            j = quote_at + 1
            while j < n and text[j] != quote and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            body = text[quote_at + 1 : j]
            kind = "word" if ch == "@" else ("string" if quote == '"' else "char")
            yield kind, body, start
            i = j + 1
        elif ch == "@":
            match = _WORD.match(text, i + 1)
            name = match.group(0) if match else ""
            yield "builtin", "@" + name, i
            i += 1 + len(name)
        else:
            match = _WORD.match(text, i)
            if match:
                yield "word", match.group(0), i
                i = match.end()
            else:
                yield "punct", ch, i
                i += 1


def imports_of(text: str):
    """(line, target, problem) for every `@import` in code, in order (import_calls without the member)."""
    for line, target, problem, _ in import_calls(text):
        yield line, target, problem


def import_calls(text: str):
    """(line, target, problem, member) for every `@import` in code, in order; member is
    the name after the call (`engine` in `@import("core").engine`), or None.

    The call may span lines and carry spaces anywhere and a trailing comma:
    `@import ( "x.zig" , )`. Zig accepts only one string literal as the operand;
    anything else (a `++` expression, a name, a multiline string) gives target
    None and a problem, as does an invalid escape."""
    for line, target, problem, member, _ in _import_calls(text, list(tokens(text))):
        yield line, target, problem, member


def _import_calls(text: str, toks):
    """import_calls over tokens already made, each with the index of its `@import` token."""
    for k, (kind, value, offset) in enumerate(toks):
        if kind != "builtin" or value != "@import":
            continue
        line = text.count("\n", 0, offset) + 1
        if k + 1 >= len(toks) or toks[k + 1][:2] != ("punct", "("):
            yield line, None, "@import without an argument list", None, k
            continue
        depth, args, j = 1, [], k + 2
        while j < len(toks):
            tk = toks[j]
            if tk[0] == "punct" and tk[1] in "([{":
                depth += 1
            elif tk[0] == "punct" and tk[1] in ")]}":
                depth -= 1
                if depth == 0:
                    break
            args.append(tk)
            j += 1
        if args and args[-1][:2] == ("punct", ","):
            args = args[:-1]
        if len(args) != 1 or args[0][0] != "string":
            shown = " ".join(str(a[1]) for a in args)[:60]
            yield line, None, f"@import's operand is not one string literal ({shown}); the checker cannot resolve it", None, k
            continue
        target = _decode(args[0][1])
        if target is None:
            yield line, None, f"@import's string has an invalid escape ({args[0][1]})", None, k
            continue
        member = None
        if j + 2 < len(toks) and toks[j + 1][:2] == ("punct", ".") and toks[j + 2][0] == "word":
            member = toks[j + 2][1]
        yield line, target, None, member, k


_OPEN, _CLOSE = "([{", ")]}"
_TYPE_BRACES = {"error", "struct", "enum", "union", "opaque"}


def _match(toks, i):
    """The index just past the bracket that closes the one at toks[i]."""
    depth, n = 0, len(toks)
    while i < n:
        kind, value, _ = toks[i]
        if kind == "punct" and value in _OPEN:
            depth += 1
        elif kind == "punct" and value in _CLOSE:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def _until(toks, i, stop):
    """The index just past the first `stop` punctuation at depth 0 from toks[i] on."""
    depth, n = 0, len(toks)
    while i < n:
        kind, value, _ = toks[i]
        if kind == "punct" and value in _OPEN:
            depth += 1
        elif kind == "punct" and value in _CLOSE:
            depth -= 1
        elif kind == "punct" and value == stop and depth == 0:
            return i + 1
        i += 1
    return n


def container_items(text: str, toks=None):
    """The top-level items of a Zig file, as (kind, name, start, end) over its tokens:
    kind `test` (a test declaration, its block included), `comptime` (a container-level
    `comptime` block), or `decl` (a `const`, `var` or `fn` declaration, named). Items
    inside a nested container are part of the declaration that holds it. `test` is
    read as a keyword only where Zig reads one: `@"test"` is a name, and a `test` in a
    comment or string gives no token at all."""
    toks = list(tokens(text)) if toks is None else toks
    items, i, n = [], 0, len(toks)
    while i < n:
        kind, value, offset = toks[i]
        word = kind == "word" and not text.startswith("@", offset)
        if word and value == "test" and i + 1 < n and (toks[i + 1][0] in ("string", "word")
                                                       or toks[i + 1][:2] == ("punct", "{")):
            body = i + 1 if toks[i + 1][:2] == ("punct", "{") else i + 2
            end = _match(toks, body) if body < n and toks[body][:2] == ("punct", "{") else body
            items.append(("test", None, i, end))
            i = end
        elif word and value == "comptime" and i + 1 < n and toks[i + 1][:2] == ("punct", "{"):
            end = _match(toks, i + 1)
            items.append(("comptime", None, i, end))
            i = end
        elif word and value in ("const", "var") and i + 1 < n and toks[i + 1][0] == "word":
            end = _until(toks, i, ";")
            items.append(("decl", toks[i + 1][1], i, end))
            i = end
        elif word and value == "fn" and i + 1 < n and toks[i + 1][0] == "word":
            j, depth = i + 2, 0
            while j < n:
                k2, v2, _ = toks[j]
                if k2 == "punct" and v2 == ";" and depth == 0:
                    j += 1
                    break
                if k2 == "punct" and v2 == "{" and depth == 0 and toks[j - 1][1] not in _TYPE_BRACES:
                    j = _match(toks, j)
                    break
                if k2 == "punct" and v2 in _OPEN:
                    depth += 1
                elif k2 == "punct" and v2 in _CLOSE:
                    depth -= 1
                j += 1
            items.append(("decl", toks[i + 1][1], i, j))
            i = j
        elif kind == "punct" and value in _OPEN:
            i = _match(toks, i)
        else:
            i += 1
    return items


_CONTAINERS = {"struct", "enum", "union", "opaque"}
# A guard that is false in every test build: `if (false)`, `if (!@import("builtin").is_test)`,
# `if (!builtin.is_test)`. Zig never analyses the branch it guards.
_FALSE_GUARDS = (
    (("word", "false"),),
    (("punct", "!"), ("builtin", "@import"), ("punct", "("), ("string", "builtin"), ("punct", ")"),
     ("punct", "."), ("word", "is_test")),
    (("punct", "!"), ("word", "builtin"), ("punct", "."), ("word", "is_test")),
)


def _fn_body(toks, i, end):
    """For `fn NAME` at toks[i]: (start, end) of its body, or None for a prototype."""
    j, depth = i + 2, 0
    while j < end:
        kind, value, _ = toks[j]
        if kind == "punct" and value == ";" and depth == 0:
            return None
        if kind == "punct" and value == "{" and depth == 0 and toks[j - 1][1] not in _TYPE_BRACES:
            return j, _match(toks, j)
        if kind == "punct" and value in _OPEN:
            depth += 1
        elif kind == "punct" and value in _CLOSE:
            depth -= 1
        j += 1
    return None


def _skipped(toks, start, end):
    """The token ranges inside toks[start:end] that a test build does not follow from
    there, as (what, start, end): `fn`, every function body (compiled only when the
    function is called, which the checker does not trace), and `guard`, every branch
    under a guard that is false in a test build (_FALSE_GUARDS)."""
    out, i = [], start
    while i < end:
        kind, value, _ = toks[i]
        if kind == "word" and value == "fn" and i + 1 < end and toks[i + 1][0] == "word":
            body = _fn_body(toks, i, end)
            if body is not None:
                out.append(("fn",) + body)
                i = body[1]
                continue
        if kind == "word" and value == "if" and i + 1 < end and toks[i + 1][:2] == ("punct", "("):
            close = _match(toks, i + 1)
            cond = tuple(t[:2] for t in toks[i + 2:close - 1])
            if cond in _FALSE_GUARDS and close < end:
                branch_end = _match(toks, close) if toks[close][:2] == ("punct", "{") else _until(toks, close, ";")
                out.append(("guard", close, branch_end))
                i = branch_end
                continue
        i += 1
    return out


def _nested_containers(toks, start, end):
    """The token ranges of every `struct`/`enum`/`union`/`opaque` body inside toks[start:end]."""
    out = []
    for j in range(start, end):
        if toks[j][:2] != ("punct", "{") or j == 0:
            continue
        prev = toks[j - 1]
        if prev[0] == "word" and prev[1] in _CONTAINERS:
            out.append((j, _match(toks, j)))
        elif prev[:2] == ("punct", ")"):
            # `union(enum) {`, `enum(u8) {`: the word before the matching `(`.
            depth, k = 0, j - 1
            while k > start:
                if toks[k][:2] == ("punct", ")"):
                    depth += 1
                elif toks[k][:2] == ("punct", "("):
                    depth -= 1
                    if depth == 0:
                        break
                k -= 1
            if k > 0 and toks[k - 1][0] == "word" and toks[k - 1][1] in ("union", "enum"):
                out.append((j, _match(toks, j)))
    return out


def test_build_reads(text: str):
    """What a test build of a file evaluates, read from its tokens: (tests, imports,
    test lines, unrun lines). tests is the number of test declarations a test build of
    the file runs, imports lists (line, target, member) for every `@import` it
    follows, test lines the line of each test it runs, and unrun lines the line of
    each test declaration it does not run.

    A test build compiles every test of a file it collects and every container-level
    `comptime` block; a container-level declaration only when something compiled
    names it (Zig analyses lazily). So the checker starts from the file's tests and
    `comptime` blocks and adds each declaration of the file they name, directly or
    through other declarations (`_ = engine;` compiles
    `const engine = @import("engine.zig");`). Where that reading is not exact, it errs
    on the side of saying a test does not run:

    - a name inside a function body is not followed (the body is compiled only if the
      function is called, which is not traced), nor a name under a guard that is false
      in a test build (`if (false)`, `if (!@import("builtin").is_test)`);
    - a name after `.` is a member, and a name before `:` a field or a label, never one
      of the file's declarations;
    - an `@import` counts only outside function bodies, false guards and nested
      `struct`/`enum`/`union`/`opaque` bodies (a nested container's declarations are
      compiled only when named through it, which is not traced).

    A test counts when it is a top-level test of the file, or sits inside a declaration
    that the build compiles (a nested container, or a generic function's returned type),
    and not under a false guard. A followed declaration is taken whole, so a
    declaration named in it counts though only an unused member of it names it: that
    is the reading's lenient side, which the count comparison
    (scripts/check_test_counts.py) catches against a real run."""
    toks = list(tokens(text))
    items = container_items(text, toks)
    live_spans, words = [], set()
    skipped = []

    def inside(k, ranges):
        return any(a <= k < b for a, b in ranges)

    def take(start, end):
        live_spans.append((start, end))
        found = _skipped(toks, start, end)
        skipped.extend(found)
        skip = [(a, b) for _, a, b in found]
        n = len(toks)
        words.update(v for j, (k, v, off) in enumerate(toks[start:end], start)
                     if k == "word" and not text.startswith("@", off) and not inside(j, skip)
                     and not (j > 0 and toks[j - 1][:2] == ("punct", "."))
                     and not (j + 1 < n and toks[j + 1][:2] == ("punct", ":")))

    for kind, _, start, end in items:
        if kind in ("test", "comptime"):
            take(start, end)
    decls = [(name, start, end) for kind, name, start, end in items if kind == "decl"]
    done = set()
    while True:
        more = [(name, start, end) for name, start, end in decls if name in words and (start, end) not in done]
        if not more:
            break
        for name, start, end in more:
            done.add((start, end))
            take(start, end)

    top_tests = {start for kind, _, start, _ in items if kind == "test"}
    false_guards = [(a, b) for what, a, b in skipped if what == "guard"]
    skipped = [(a, b) for _, a, b in skipped]
    run, unrun = [], []
    for j, (kind, value, offset) in enumerate(toks):
        if not (kind == "word" and value == "test" and not text.startswith("@", offset) and j + 1 < len(toks)
                and (toks[j + 1][0] in ("string", "word") or toks[j + 1][:2] == ("punct", "{"))):
            continue
        line = text.count("\n", 0, offset) + 1
        if j in top_tests or (inside(j, [(s, e) for s, e in live_spans if s not in top_tests])
                              and not inside(j, false_guards)):
            run.append(line)
        else:
            unrun.append(line)
    containers = [r for start, end in live_spans for r in _nested_containers(toks, start, end)]
    imports = []
    for line, target, problem, member, k in _import_calls(text, toks):
        if problem is None and inside(k, live_spans) and not inside(k, skipped) and not inside(k, containers):
            imports.append((line, target, member))
    return len(run), imports, run, unrun


def test_build_imports(text: str):
    """(tests, imports, test lines) of test_build_reads, without the unrun lines."""
    tests, imports, lines, _ = test_build_reads(text)
    return tests, imports, lines


def _seq(toks, i, pattern):
    """True when toks[i:] starts with pattern, a list of (kind, value) where value None matches any."""
    if i + len(pattern) > len(toks):
        return False
    return all(toks[i + k][0] == kind and (value is None or toks[i + k][1] == value)
               for k, (kind, value) in enumerate(pattern))


def _fields(toks, start, end):
    """`.field = value` pairs at depth 1 of the `.{ ... }` at toks[start:end]: field -> (kind, value tokens)."""
    out, depth, j = {}, 0, start
    while j < end:
        kind, value, _ = toks[j]
        if kind == "punct" and value in _OPEN:
            depth += 1
        elif kind == "punct" and value in _CLOSE:
            depth -= 1
        elif depth == 1 and _seq(toks, j, [("punct", "."), ("word", None), ("punct", "=")]):
            stop = j + 3
            d2 = 0
            while stop < end:
                k2, v2, _ = toks[stop]
                if k2 == "punct" and v2 in _OPEN:
                    d2 += 1
                elif k2 == "punct" and v2 in _CLOSE:
                    if d2 == 0:
                        break
                    d2 -= 1
                elif k2 == "punct" and v2 == "," and d2 == 0:
                    break
                stop += 1
            out[toks[j + 1][1]] = toks[j + 3:stop]
            j = stop
            continue
        j += 1
    return out


def build_test_steps(text: str):
    """The steps of `zig build test`, read from zig/build.zig's structure (S6-T15 rework):
    (steps, problems). steps lists (label, root, line, row): label is the name the
    Build Summary prints after `run test` ("" for a test compiled with no `.name`),
    root the root file relative to zig/src, row whether it is a row of test_roots. problems lists (line, message) for what the reader
    cannot follow, or a test compiled and never run.

    What it reads:
    - `const T = b.step("test", ...)`, the step;
    - every `const N = b.addTest(.{ ... })` and every `T.dependOn(&b.addRunArtifact(N).step)`:
      a test that the step does not run is a problem;
    - an `addTest` inside `for (test_roots) |r| { ... }` makes one step per row of
      `const test_roots = ...{ .{ .name = "...", .path = "src/....zig" }, ... }`, labelled
      by the row's name (its `.name` must be `r.name`, its module's root `b.path(r.path)`);
    - any other `addTest` makes one step: its `.name` string ("" without one), and the
      root of its `.root_module`, a module made in the same function
      (`const M = b.createModule(.{ .root_source_file = b.path("src/...") })`) or by a
      function of the file holding exactly one `b.path("src/....zig")`."""
    toks = list(tokens(text))
    n = len(toks)
    line_of = lambda k: text.count("\n", 0, toks[k][2]) + 1  # noqa: E731
    problems, steps = [], []
    step_var = None
    for k in range(n):
        if _seq(toks, k, [("word", "const"), ("word", None), ("punct", "="), ("word", "b"), ("punct", "."),
                          ("word", "step"), ("punct", "("), ("string", "test")]):
            step_var = toks[k + 1][1]
    if step_var is None:
        return [], [(1, 'no `const ... = b.step("test", ...)`: the checker cannot read the steps of `zig build test`')]
    run = set()
    for k in range(n):
        if _seq(toks, k, [("word", step_var), ("punct", "."), ("word", "dependOn"), ("punct", "("), ("punct", "&"),
                          ("word", "b"), ("punct", "."), ("word", "addRunArtifact"), ("punct", "("), ("word", None),
                          ("punct", ")"), ("punct", "."), ("word", "step"), ("punct", ")")]):
            run.add(toks[k + 9][1])
    # The rows of test_roots.
    rows = []
    for k in range(n):
        if _seq(toks, k, [("word", "const"), ("word", "test_roots"), ("punct", "=")]):
            end = _until(toks, k, ";")
            j = k + 3
            # Skip the type `[_]struct { ... }` to the initializer's `{`.
            while j < end and not (toks[j][:2] == ("punct", "{") and toks[j - 1][0] != "word"):
                j = _match(toks, j) if toks[j][:2] == ("punct", "{") else j + 1
            body_end = _match(toks, j) if j < end else j
            m = j + 1
            while m < body_end - 1:
                if _seq(toks, m, [("punct", "."), ("punct", "{")]):
                    close = _match(toks, m + 1)
                    fields = _fields(toks, m + 1, close)
                    name, path = fields.get("name", []), fields.get("path", [])
                    if len(name) == 1 and name[0][0] == "string" and len(path) == 1 and path[0][0] == "string" \
                            and path[0][1].startswith("src/"):
                        rows.append((name[0][1], path[0][1][len("src/"):], line_of(m)))
                    else:
                        problems.append((line_of(m), "a row of test_roots that is not "
                                                     '`.{ .name = "...", .path = "src/....zig" }`'))
                    m = close
                else:
                    m += 1
    # The loops over test_roots.
    loops = []
    for k in range(n):
        if _seq(toks, k, [("word", "for"), ("punct", "("), ("word", "test_roots"), ("punct", ")"), ("punct", "|"),
                          ("word", None), ("punct", "|"), ("punct", "{")]):
            loops.append((toks[k + 5][1], k + 7, _match(toks, k + 7)))
    # Functions of the file: name -> the "src/....zig" strings of b.path(...) in their bodies.
    fn_paths = {}
    for k in range(n):
        if toks[k][:2] == ("word", "fn") and k + 1 < n and toks[k + 1][0] == "word":
            body = _fn_body(toks, k, n)
            if body:
                fn_paths[toks[k + 1][1]] = [toks[j + 4][1] for j in range(*body)
                                            if _seq(toks, j, [("word", "b"), ("punct", "."), ("word", "path"),
                                                              ("punct", "("), ("string", None)])
                                            and toks[j + 4][1].startswith("src/")]
    for k in range(n):
        if not _seq(toks, k, [("word", "b"), ("punct", "."), ("word", "addTest"), ("punct", "("), ("punct", "."),
                              ("punct", "{")]):
            continue
        line = line_of(k)
        bound = toks[k - 2][1] if k >= 3 and _seq(toks, k - 3, [("word", "const"), ("word", None), ("punct", "=")]) \
            else None
        if bound is None or bound not in run:
            problems.append((line, f"b.addTest{' (' + bound + ')' if bound else ''} is compiled but the `test` "
                                   f"step does not run it: add `{step_var}.dependOn(&b.addRunArtifact("
                                   f"{bound or 'NAME'}).step);`, or remove the test"))
            continue
        fields = _fields(toks, k + 5, _match(toks, k + 5))
        loop = next((lp for lp in loops if lp[1] <= k < lp[2]), None)
        if loop is not None:
            var, start, end = loop
            name = [t[:2] for t in fields.get("name", [])]
            # The name may be `r.name` or a local bound to it (`const name = r.name;`).
            aliases = {var + ".name"}
            for j in range(start, end):
                if _seq(toks, j, [("word", "const"), ("word", None), ("punct", "="), ("word", var), ("punct", "."),
                                  ("word", "name"), ("punct", ";")]):
                    aliases.add(toks[j + 1][1])
            shown = "".join(v for _, v in name)
            has_path = any(_seq(toks, j, [("word", "b"), ("punct", "."), ("word", "path"), ("punct", "("),
                                          ("word", var), ("punct", "."), ("word", "path"), ("punct", ")")])
                           for j in range(start, end))
            if shown not in aliases or not has_path:
                problems.append((line, f"the test compiled in the loop over test_roots is not named `{var}.name` "
                                       f"with its module rooted at `b.path({var}.path)`: the checker cannot tell "
                                       "which root each step runs"))
                continue
            steps += [(name_, root, row_line, True) for name_, root, row_line in rows]
            continue
        name = fields.get("name", [])
        label = name[0][1] if len(name) == 1 and name[0][0] == "string" else ("" if not name else None)
        module = fields.get("root_module", [])
        root = None
        if module and module[0][0] == "word":
            ident = module[0][1]
            if len(module) > 1 and module[1][:2] == ("punct", "("):
                paths = fn_paths.get(ident, [])
                root = paths[0][len("src/"):] if len(paths) == 1 else None
            else:
                for j in range(n):
                    if _seq(toks, j, [("word", "const"), ("word", ident), ("punct", "="), ("word", "b"), ("punct", "."),
                                      ("word", "createModule"), ("punct", "("), ("punct", "."), ("punct", "{")]):
                        mfields = _fields(toks, j + 8, _match(toks, j + 8))
                        src_ = mfields.get("root_source_file", [])
                        if _seq(src_, 0, [("word", "b"), ("punct", "."), ("word", "path"), ("punct", "("),
                                          ("string", None)]):
                            root = src_[4][1][len("src/"):]
        if label is None or root is None:
            problems.append((line, "b.addTest whose `.name` (a string, or none) or whose root module's root file the "
                                   "checker cannot read"))
            continue
        steps.append((label, root, line, False))
    return steps, problems


def build_root_paths(text: str):
    """(line, path relative to zig/src) for every `"src/....zig"` string zig/build.zig holds."""
    for kind, value, offset in tokens(text):
        if kind == "string" and value.startswith("src/") and value.endswith(".zig"):
            yield text.count("\n", 0, offset) + 1, value[len("src/"):]




def zig_files(src: Path):
    """Every `.zig` file under src, relative and with `/`, dot folders included."""
    return sorted(path.relative_to(src).as_posix() for path in src.rglob("*.zig"))


def resolve(src: Path, rel: str, target: str):
    """The `.zig` target of an import in src/rel, relative to src, or None if outside."""
    base = src.resolve()
    path = ((src / rel).resolve().parent / target).resolve()
    try:
        return path.relative_to(base).as_posix()
    except ValueError:
        return None


def folder_of(rel: str):
    """The first folder of a path relative to zig/src, or "" for a file directly in it."""
    return rel.split("/", 1)[0] if "/" in rel else ""


def rank_of(folder: str):
    """The layer a folder's files are held to (tests/ above all), or None for no known folder."""
    for layer, name in FOLDERS.items():
        if name == folder:
            return layer
    return TESTS if folder == TESTS else None


def exempt_reason(rel: str, exempt_files, exempt_patterns):
    if rel in exempt_files:
        return exempt_files[rel]
    name = posixpath.basename(rel)
    for pattern, reason in exempt_patterns:
        if fnmatch.fnmatchcase(name, pattern):
            return reason
    return None


def root_exports(text: str):
    """NAME -> (line, operand) for every `pub const NAME = @import("...");` of a module root."""
    toks = list(tokens(text))
    out = {}
    for k in range(len(toks) - 8):
        window = toks[k:k + 9]
        if [w[:2] for w in window[:2]] == [("word", "pub"), ("word", "const")] and window[2][0] == "word" \
                and window[3][:2] == ("punct", "=") and window[4][:2] == ("builtin", "@import") \
                and window[5][:2] == ("punct", "(") and window[6][0] == "string" \
                and window[7][:2] == ("punct", ")") and window[8][:2] == ("punct", ";"):
            out[window[2][1]] = (text.count("\n", 0, window[0][2]) + 1, _decode(window[6][1]))
    return out


def _script_line(*names: str, table: str = "") -> str:
    """`scripts/check_layers.py:N` for the line of this script naming all of names
    (in the table that starts with `table = {`, when one is given)."""
    try:
        lines = Path(__file__).read_text(encoding="utf-8").splitlines()
    except OSError:
        lines = []
    quoted = [f'"{name}"' for name in names]
    start = next((i for i, line in enumerate(lines) if table and line.startswith(f"{table} = {{")), 0)
    for number, line in enumerate(lines[start:], start + 1):
        if all(q in line for q in quoted):
            return f"scripts/check_layers.py:{number}"
    return "scripts/check_layers.py"


def _who(rank: str) -> str:
    """The folders a module's lowest rank admits, for a message or the document."""
    names = list(RANKS[RANKS.index(rank):])
    return names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]


def render_doc(files=None, allowed=None, exempt_files=None, exempt_patterns=None, module_roots=None,
               build_roots=None) -> str:
    """The generated block of docs/layers.md, markers included."""
    build_roots = BUILD_ROOTS if build_roots is None else build_roots
    files = FILES if files is None else files
    allowed = ALLOWED if allowed is None else allowed
    exempt_files = EXEMPT_FILES if exempt_files is None else exempt_files
    exempt_patterns = EXEMPT_PATTERNS if exempt_patterns is None else exempt_patterns
    module_roots = MODULE_ROOTS if module_roots is None else module_roots
    out = [BEGIN, ""]
    counts = {layer: sum(1 for v in files.values() if v[0] == layer) for layer in LAYER_ORDER}
    roots = {v[0]: (rel, v[1]) for rel, v in module_roots.items()}
    out.append("| Layer | Folder (`zig/src/`) | Module | Files | May import |")
    out.append("|---|---|---|---:|---|")
    for layer in LAYER_ORDER:
        rel, name = roots.get(layer, ("", ""))
        module = f"`{name}` (`{rel}`)" if name else "none"
        out.append(f"| {layer} | `{FOLDERS[layer]}/` | {module} | {counts[layer]} | {MAY_IMPORT[layer]} |")
    out += ["", "| File (`zig/src/`) | Layer | What it holds |", "|---|---|---|"]
    for rel, (layer, role) in sorted(files.items(), key=lambda kv: (LAYER_ORDER.index(kv[1][0]), kv[0])):
        out.append(f"| `{rel}` | {layer} | {role} |")
    out += ["", "Module roots (only `pub const` imports of their folder's files):", ""]
    out += ["| File (`zig/src/`) | Module | What it is |", "|---|---|---|"]
    for rel, (layer, name, what) in sorted(module_roots.items(), key=lambda kv: LAYER_ORDER.index(kv[1][0])):
        out.append(f"| `{rel}` | `{name}` | {what} |")
    out += ["", "The roots `zig/build.zig` compiles (a test step runs the tests of the files its root reaches by path):", ""]
    out += ["| File (`zig/src/`) | Step of `zig build test` | What it is the root of |", "|---|---|---|"]
    for rel, (step, what) in build_roots.items():
        out.append(f"| `{rel}` | {f'`{step}`' if step else 'none'} | {what} |")
    out += ["", "Imports between interfaces that are allowed (any other fails the check):", ""]
    out += ["| File | Imports | Kind | What it uses |", "|---|---|---|---|"]
    for (importer, imported), (kind, why) in sorted(allowed.items(), key=lambda kv: (kv[1][0] != "entry", kv[0])):
        out.append(f"| `{importer}` | `{imported}` | {kind} | {why} |")
    out += ["", "Imports that are not files (any other name fails the check):", ""]
    out += ["| Module | Who may import it | What it is |", "|---|---|---|"]
    for name, (lowest, what) in MODULES.items():
        who = "any file" if lowest is None else "files of " + _who(lowest)
        out.append(f"| `{name}` | {who} | {what} |")
    out += ["", "Tests, benchmarks and tools (in their subject's layer folder, or `tests/` when they cross layers):", ""]
    out += ["| File or pattern | Why |", "|---|---|"]
    for pattern, reason in exempt_patterns:
        out.append(f"| `{pattern}` | {reason} |")
    for rel, reason in sorted(exempt_files.items()):
        out.append(f"| `{rel}` | {reason} |")
    out += ["", END]
    return "\n".join(out)


def doc_block(text: str):
    """(first line number, block text) of the generated block, or None."""
    lines = text.split("\n")
    try:
        start = lines.index(BEGIN)
        end = lines.index(END, start)
    except ValueError:
        return None
    return start + 1, "\n".join(lines[start : end + 1])


def test_reach(src: Path, present, build_roots, exports, layer_modules):
    """Which step of `zig build test` runs the tests of each file (S6-T15).

    A test build collects the tests of its root module's files only: the step's
    root file and the files it reaches by a `.zig` path import that the build
    evaluates (test_build_imports), followed from file to file. A file reached
    through a named module (`@import("core").fold_test`) belongs to that module,
    not to the step's root module, so its tests do not run there; it is recorded
    in `via_module` for the message only.

    Returns (tests, lines, reached, via_module, unrun): the count and the lines of
    the tests a test build of every file runs, file -> [(step, the file that reaches
    it)], file -> [(importer, module)], and the lines of every file's test
    declarations that a test build does not run (test_build_reads)."""
    tests, lines, live, unrun = {}, {}, {}, {}
    for rel in present:
        count, imports, at, dead = test_build_reads((src / rel).read_text(encoding="utf-8", errors="replace"))
        tests[rel], lines[rel], live[rel], unrun[rel] = count, at, imports, dead
    reached, via_module = {}, {}
    for root_rel, (step, _) in sorted(build_roots.items()):
        if step is None or root_rel not in tests:
            continue
        seen, queue = {root_rel: None}, [root_rel]
        while queue:
            rel = queue.pop(0)
            for _, target, member in live[rel]:
                if target.endswith(".zig"):
                    dep = resolve(src, rel, target)
                    if dep is not None and dep in tests and dep not in seen:
                        seen[dep] = rel
                        queue.append(dep)
                elif target in layer_modules and member is not None:
                    dep = exports.get(target, {}).get(member)
                    if dep is not None:
                        via_module.setdefault(dep, []).append((rel, target))
        for rel, parent in seen.items():
            reached.setdefault(rel, []).append((step, parent))
    return tests, lines, reached, via_module, unrun


def check(root: Path, files=None, allowed=None, exempt_files=None, exempt_patterns=None, doc=True, module_roots=None,
          build_roots=None, outside_module=None, report=None):
    """Every problem found, as `path:line: message` strings (empty when clean).

    `report`, a dict, receives the test reach (test_reach) for --list-tests."""
    files = FILES if files is None else files
    allowed = ALLOWED if allowed is None else allowed
    exempt_files = EXEMPT_FILES if exempt_files is None else exempt_files
    exempt_patterns = EXEMPT_PATTERNS if exempt_patterns is None else exempt_patterns
    module_roots = MODULE_ROOTS if module_roots is None else module_roots
    build_roots = BUILD_ROOTS if build_roots is None else build_roots
    outside_module = OUTSIDE_MODULE if outside_module is None else outside_module
    problems = []
    src = root / SRC
    present = zig_files(src)
    present_set = set(present)
    layer_modules = {name: rel for rel, (_, name, _) in module_roots.items()}

    # The tables themselves.
    for rel in sorted((set(files) & set(exempt_files)) | (set(files) & set(module_roots)) |
                      (set(module_roots) & set(exempt_files))):
        problems.append(f"{_script_line(rel)}: {rel} is listed twice (FILES, MODULE_ROOTS, EXEMPT_FILES)")
    for rel, (layer, _) in sorted(files.items()):
        if folder_of(rel) != FOLDERS[layer]:
            problems.append(f"{_script_line(rel)}: FILES assigns {rel} to {layer}, whose folder is "
                            f"{SRC}/{FOLDERS[layer]}/")
    for rel, (layer, _, _) in sorted(module_roots.items()):
        if folder_of(rel) != FOLDERS[layer]:
            problems.append(f"{_script_line(rel)}: MODULE_ROOTS puts {rel}, the {layer} module's root, outside "
                            f"{SRC}/{FOLDERS[layer]}/")
    for rel in sorted(exempt_files):
        if rank_of(folder_of(rel)) is None:
            problems.append(f"{_script_line(rel)}: EXEMPT_FILES names {rel}, outside the layer folders and tests/")
    for (importer, imported) in sorted(allowed):
        if files.get(importer, ("",))[0] != "interfaces" or files.get(imported, ("",))[0] != "interfaces":
            problems.append(f"{_script_line(importer, imported)}: allowed pair {importer} -> {imported} "
                            "is not between two interface files")

    for rel in sorted(files):
        if rel not in present_set:
            problems.append(f"{_script_line(rel)}: FILES names {SRC}/{rel}, which does not exist")
    for rel in sorted(module_roots):
        if rel not in present_set:
            problems.append(f"{_script_line(rel)}: MODULE_ROOTS names {SRC}/{rel}, which does not exist")
    for rel in sorted(exempt_files):
        if rel not in present_set:
            problems.append(f"{_script_line(rel)}: EXEMPT_FILES names {SRC}/{rel}, which does not exist")

    exports = {}
    for name, rel in layer_modules.items():
        if rel in present_set:
            exports[name] = {n: resolve(src, rel, op) if op else None
                             for n, (_, op) in root_exports((src / rel).read_text(encoding="utf-8")).items()}

    by_name = {}
    for rel, (layer, _) in files.items():
        by_name.setdefault(posixpath.basename(rel), []).append((rel, layer))

    used = set()
    crossing = {}  # a file of tests/ -> (the layers it reaches, the tests/ files it imports)
    for rel in present:
        folder = folder_of(rel)
        rank = rank_of(folder)
        assigned = rel in files
        is_root = rel in module_roots
        exempt = not assigned and not is_root and exempt_reason(rel, exempt_files, exempt_patterns) is not None
        if rank is None:
            where = "directly in zig/src/" if folder == "" else f"in {SRC}/{folder}/"
            problems.append(f"{SRC}/{rel}:1: sits {where}, outside the layer folders (core/, ops/, interfaces/) "
                            "and tests/: move it to its layer's folder")
            continue
        if not (assigned or is_root or exempt):
            home = [(r, layer) for r, layer in by_name.get(posixpath.basename(rel), []) if r != rel]
            if home:
                r, layer = home[0]
                problems.append(f"{SRC}/{rel}:1: sits in {SRC}/{folder}/, outside its layer's folder: FILES "
                                f"assigns {posixpath.basename(rel)} to {layer} as {r} ({SRC}/{FOLDERS[layer]}/)")
            elif rank == TESTS:
                problems.append(f"{SRC}/{rel}:1: {SRC}/tests/ holds tests, benchmarks and tools only "
                                "(*_test.zig, *_bench.zig, EXEMPT_FILES); a layer's file belongs in its layer's folder")
            else:
                problems.append(f"{SRC}/{rel}:1: not assigned to a layer: add it to FILES in "
                                "scripts/check_layers.py (core, operations or interfaces), "
                                "then run scripts/check_layers.py --write-doc")
        layer = files[rel][0] if assigned else (module_roots[rel][0] if is_root else None)
        who = rank if rank != TESTS else "tests"
        reached, local = set(), set()
        text = (src / rel).read_text(encoding="utf-8", errors="replace")
        for number, target, problem, member in import_calls(text):
            where = f"{SRC}/{rel}:{number}"
            if problem is not None:
                problems.append(f"{where}: {problem}")
                continue
            if not target.endswith(".zig"):
                if target not in MODULES:
                    problems.append(f"{where}: imports {target!r}, which is neither a .zig file nor a "
                                    "module listed in MODULES (scripts/check_layers.py)")
                    continue
                lowest = MODULES[target][0]
                if lowest is not None and RANKS.index(rank) < RANKS.index(lowest):
                    problems.append(f"{where}: {who} file imports the module {target}, "
                                    f"which only files of {_who(lowest)} may import")
                    continue
                if target in layer_modules:
                    reached.add(module_roots[layer_modules[target]][0])
                    if member is not None and target in exports:
                        dep = exports[target].get(member)
                        if member not in exports[target]:
                            problems.append(f"{where}: imports {target}.{member}, which {SRC}/{layer_modules[target]} "
                                            f"does not export (no pub const {member})")
                        elif (assigned or is_root) and dep is not None and \
                                exempt_reason(dep, exempt_files, exempt_patterns) is not None and dep not in files:
                            problems.append(f"{where}: {layer} file imports {target}.{member} ({SRC}/{dep}), "
                                            "a test, benchmark or tool file")
                continue
            dep = resolve(src, rel, target)
            if dep is None:
                problems.append(f"{where}: imports {target}, which is outside {SRC}/")
                continue
            if dep not in present_set:
                problems.append(f"{where}: imports {target}, which resolves to {SRC}/{dep}: no such file")
                continue
            dep_folder = folder_of(dep)
            if dep_folder != folder:
                dep_rank = rank_of(dep_folder)
                if dep_rank in FOLDERS:
                    module = next((n for n, r in layer_modules.items() if module_roots[r][0] == dep_rank), None)
                    how = f'through its module, @import("{module}")' if module else "through its module"
                    problems.append(f"{where}: imports {target} ({SRC}/{dep}), a file of another folder: "
                                    f"{dep_rank} is reached {how}, never by path")
                else:
                    problems.append(f"{where}: imports {target} ({SRC}/{dep}), a file of another folder: "
                                    f"{SRC}/{dep_folder or '.'}/ is no module, and nothing outside it imports its files")
                continue
            if dep in files:
                dep_layer = files[dep][0]
                reached.add(dep_layer)
            elif dep in module_roots:
                problems.append(f"{where}: imports {target}, a module root, by path: import the module by name")
                continue
            elif exempt_reason(dep, exempt_files, exempt_patterns) is not None:
                local.add(dep)
                if assigned:
                    problems.append(f"{where}: {layer} file imports {target}, a test, benchmark or tool file")
                continue
            else:
                problems.append(f"{where}: imports {target} ({SRC}/{dep}), which is not assigned to a layer")
                continue
            if not assigned or layer is None:
                continue
            if LAYER_ORDER.index(dep_layer) > LAYER_ORDER.index(layer):
                problems.append(f"{where}: {layer} file imports {target} ({dep_layer}); "
                                f"{layer} may import {MAY_IMPORT[layer]}")
            elif layer == dep_layer == "interfaces" and dep != rel:
                if (rel, dep) in allowed:
                    used.add((rel, dep))
                else:
                    problems.append(f"{where}: interface file imports {target}, another interface, "
                                    "and the pair is not in ALLOWED (scripts/check_layers.py)")
        if rank == TESTS and exempt:
            crossing[rel] = (reached, local)

    # A test, benchmark or tool in tests/ crosses layers, itself or through the
    # tests/ files it imports; one that reaches one layer only sits beside its subject.
    def layers_reached(rel, seen):
        reached, local = crossing.get(rel, (set(), set()))
        out = set(reached)
        for dep in local:
            if dep not in seen:
                seen.add(dep)
                out |= layers_reached(dep, seen)
        return out
    for rel in sorted(crossing):
        if rel in exempt_files:
            continue
        reached = layers_reached(rel, {rel})
        if len(reached) == 1:
            layer = next(iter(reached))
            problems.append(f"{SRC}/{rel}:1: imports {layer} files only: a test, benchmark or tool of one layer "
                            f"sits beside its subject, in {SRC}/{FOLDERS[layer]}/")

    for pair in sorted(set(allowed) - used):
        importer, imported = pair
        if importer in present_set and imported in present_set:
            problems.append(f"{_script_line(importer, imported)}: allowed pair {importer} -> {imported} "
                            "no longer occurs: remove it from ALLOWED")

    # S6-T15: the roots zig/build.zig compiles, and the tests each step of `zig build test` runs.
    build_path = root / BUILD
    named = {}
    if not build_path.is_file():
        problems.append(f"{BUILD}:1: missing; the checker reads the roots of `zig build test` from it")
    else:
        for number, rel in build_root_paths(build_path.read_text(encoding="utf-8")):
            named.setdefault(rel, number)
        for rel, number in sorted(named.items()):
            if rel not in build_roots:
                problems.append(f"{BUILD}:{number}: names src/{rel}, which BUILD_ROOTS (scripts/check_layers.py) "
                                "does not list: add it, with the step of `zig build test` it is the root of, or None")
        for rel in sorted(set(build_roots) - set(named)):
            problems.append(f"{_script_line(rel, table='BUILD_ROOTS')}: BUILD_ROOTS names {rel}, which {BUILD} "
                            "does not name")
        # The steps themselves, read from the build's structure: each step BUILD_ROOTS
        # names is a test the `test` step runs, rooted at that file, once.
        steps, unread = build_test_steps(build_path.read_text(encoding="utf-8"))
        for number, message in unread:
            problems.append(f"{BUILD}:{number}: {message}")
        by_root = {}
        for label, rel, number, row in steps:
            by_root.setdefault(rel, []).append((label, number, row))
        for rel, places in sorted(by_root.items()):
            want = build_roots.get(rel, (None, ""))[0]
            if len(places) > 1:
                problems.append(f"{BUILD}:{places[1][1]}: src/{rel} is the root of {len(places)} test steps "
                                f"({', '.join(repr(label) for label, _, _ in places)}); BUILD_ROOTS gives it one")
            for label, number, row in places:
                if want is None:
                    problems.append(f"{BUILD}:{number}: a test step is rooted at src/{rel}, which BUILD_ROOTS "
                                    "(scripts/check_layers.py) gives no step: add the step there")
                elif row and label != want:
                    problems.append(f"{BUILD}:{number}: the test_roots row {label!r} is rooted at src/{rel}, "
                                    f"the root of the step {want!r} in BUILD_ROOTS: a row's name and path go together")
                elif not row and label != step_label(want):
                    shown, expected = f"run test {label}".rstrip(), f"run test {step_label(want)}".rstrip()
                    problems.append(f"{BUILD}:{number}: the test rooted at src/{rel} is named {label!r}, so the "
                                    f"Build Summary shows `{shown}`; the step {want!r} is expected as "
                                    f"`{expected}` (STEP_LABELS in scripts/check_layers.py)")
        for rel, (step, _) in sorted(build_roots.items()):
            if step is not None and rel not in by_root:
                problems.append(f"{_script_line(rel, table='BUILD_ROOTS')}: BUILD_ROOTS makes {rel} the root of the "
                                f"step {step!r}, but no test the `test` step of {BUILD} runs is rooted there")
    for rel in sorted(build_roots):
        # A missing file listed in another table is reported there.
        if rel not in present_set and rel not in files and rel not in module_roots and rel not in exempt_files:
            problems.append(f"{_script_line(rel, table='BUILD_ROOTS')}: BUILD_ROOTS names {SRC}/{rel}, "
                            "which does not exist")
    for rel in sorted(outside_module):
        if rel not in build_roots:
            problems.append(f"{_script_line(rel, table='OUTSIDE_MODULE')}: OUTSIDE_MODULE names {rel}, "
                            "which is not in BUILD_ROOTS")
    # The listing is what BUILD_ROOTS says should run, whatever zig/build.zig now does:
    # the build is checked against it above, and a real run by scripts/check_test_counts.py.
    live_roots = {rel: v for rel, v in build_roots.items() if rel in present_set}
    tests, test_lines, reached, via_module, unrun = test_reach(src, present, live_roots, exports, layer_modules)
    roots_of = {FOLDERS[layer]: rel for rel, (layer, _, _) in module_roots.items()}
    tests_root = next((rel for rel, (step, _) in build_roots.items() if step == TESTS), "tests/root.zig")
    for rel in present:
        if rel in reached and unrun[rel]:
            count = len(unrun[rel])
            problems.append(f"{SRC}/{rel}:{unrun[rel][0]}: holds {count} test{'s' if count != 1 else ''} that no "
                            "step of `zig build test` runs, though a step reaches the file: each sits inside a "
                            "declaration nothing compiled names (a struct no test or comptime block uses), or under "
                            "a guard that is false in a test build; lines " + ", ".join(map(str, unrun[rel])))
        if tests[rel] + len(unrun[rel]) == 0 or rel in reached:
            continue
        folder = folder_of(rel)
        if folder in roots_of:
            how = f"name it in {SRC}/{roots_of[folder]}: a pub const and a line in its test-build comptime block"
        else:
            how = f"name it in {SRC}/{tests_root}'s test block, or from a test that {SRC}/{tests_root} reaches"
        why = ""
        if rel in via_module:
            importer, module = via_module[rel][0]
            why = (f"; {SRC}/{importer} reaches it only through the module {module}, and a test build runs "
                   "the tests of its root module's files only")
        count = tests[rel] + len(unrun[rel])
        first = min(test_lines[rel] + unrun[rel])
        problems.append(f"{SRC}/{rel}:{first}: holds {count} test{'s' if count != 1 else ''} "
                        f"that no step of `zig build test` runs: no test step's root reaches it ({how}){why}")

    # A module root names every file its module holds, and compiles each in a test build,
    # so the module's step runs every test of its folder.
    for root_rel, (layer, _, _) in sorted(module_roots.items()):
        if root_rel not in present_set or folder_of(root_rel) != FOLDERS[layer]:
            continue  # reported above
        text = (src / root_rel).read_text(encoding="utf-8")
        declared = {resolve(src, root_rel, op): (number, name)
                    for name, (number, op) in root_exports(text).items() if op}
        compiled = {resolve(src, root_rel, target) for _, target, _ in test_build_imports(text)[1]
                    if target.endswith(".zig")}
        folder = FOLDERS[layer]
        for rel in present:
            if folder_of(rel) != folder or rel == root_rel or rel in outside_module:
                continue
            # The module holds its folder's layer files and tests; benchmarks and tools are run alone.
            if files.get(rel, ("",))[0] != layer and not (rel not in files and
                                                         fnmatch.fnmatchcase(posixpath.basename(rel), "*_test.zig")):
                continue
            if rel not in declared:
                problems.append(f"{SRC}/{root_rel}:1: does not name {rel}: a module root names every file of its "
                                "folder (a pub const, and a line in its test-build comptime block), so the module's "
                                "step of `zig build test` compiles it and runs its tests")
            elif rel not in compiled:
                number, name = declared[rel]
                problems.append(f"{SRC}/{root_rel}:{number}: names {rel} (pub const {name}) but no test build "
                                f"compiles it: add `_ = {name};` to its test-build comptime block")
    if report is not None:
        report.update(tests=tests, lines=test_lines, reached=reached, via_module=via_module,
                      steps={rel: step for rel, (step, _) in live_roots.items() if step is not None},
                      labels={rel: step_label(step) for rel, (step, _) in live_roots.items() if step is not None})

    if doc:
        doc_path = root / DOC
        expected = render_doc(files, allowed, exempt_files, exempt_patterns, module_roots, build_roots)
        if not doc_path.exists():
            problems.append(f"{DOC}:1: missing; run scripts/check_layers.py --write-doc")
        else:
            found = doc_block(doc_path.read_text(encoding="utf-8"))
            if found is None:
                problems.append(f"{DOC}:1: no generated block (the BEGIN and END markers); "
                                "run scripts/check_layers.py --write-doc")
            elif found[1] != expected:
                start, block = found
                have, want = block.split("\n"), expected.split("\n")
                offset = next((i for i, (a, b) in enumerate(zip(have, want)) if a != b), min(len(have), len(want)))
                problems.append(f"{DOC}:{start + offset}: the generated block differs from "
                                "scripts/check_layers.py; run scripts/check_layers.py --write-doc")
    return problems


def write_doc(root: Path) -> None:
    doc_path = root / DOC
    text = doc_path.read_text(encoding="utf-8")
    found = doc_block(text)
    if found is None:
        raise SystemExit(f"{DOC}: no BEGIN/END markers to replace")
    start, block = found
    doc_path.write_text(text.replace(block, render_doc(), 1), encoding="utf-8")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Check the layer boundary of zig/src (docs/layers.md).")
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help="repository root (default: this script's)")
    parser.add_argument("--write-doc", action="store_true", help="regenerate the block of docs/layers.md")
    parser.add_argument("--list-tests", action="store_true",
                        help="also print each step of `zig build test`, the files whose tests it runs, and their counts")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    if args.write_doc:
        write_doc(root)
    reach = {}
    problems = check(root, report=reach)
    if args.list_tests:
        print_tests(reach)
    for problem in problems:
        print(problem)
    if problems:
        print(f"check_layers: {len(problems)} problem(s)")
        return 1
    with_tests = [rel for rel, count in reach["tests"].items() if count]
    print(f"check_layers: OK ({len(FILES)} files in layers, {len(MODULE_ROOTS)} module roots, "
          f"{len(ALLOWED)} allowed interface imports; {len(with_tests)} files hold "
          f"{sum(reach['tests'].values())} tests, each run by a step of `zig build test`)")
    return 0


def print_tests(reach) -> None:
    """The --list-tests table: by step, then by file, with the file that reaches each."""
    tests, reached = reach["tests"], reach["reached"]
    by_step = {}
    for rel, places in reached.items():
        for step, parent in places:
            by_step.setdefault(step, []).append((rel, parent))
    print("| Step of `zig build test` | Root | Files with tests | Tests |")
    print("|---|---|---:|---:|")
    total_files = total_tests = 0
    for root_rel, step in reach["steps"].items():
        rows = [(rel, parent) for rel, parent in by_step.get(step, []) if tests[rel]]
        count = sum(tests[rel] for rel, _ in rows)
        total_files += len(rows)
        total_tests += count
        print(f"| {step} | `{root_rel}` | {len(rows)} | {count} |")
    print(f"| all | | {total_files} | {total_tests} |")
    print()
    print("| File (`zig/src/`) | Tests | Step | Reached from |")
    print("|---|---:|---|---|")
    for rel in sorted(tests):
        if not tests[rel]:
            continue
        places = reached.get(rel, [])
        steps = ", ".join(step for step, _ in places) or "none"
        parents = ", ".join(f"`{parent}`" if parent else "(the root)" for _, parent in places) or "nothing"
        print(f"| `{rel}` | {tests[rel]} | {steps} | {parents} |")
    print()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

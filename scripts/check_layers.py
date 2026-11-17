#!/usr/bin/env python3
"""The layer boundary of `zig/src/` (S6-T1; docs/layers.md).

Every Zig file under `zig/src/` is either assigned to one layer in FILES below
(core, operations or interfaces) or exempt as a test, a benchmark or a tool
(EXEMPT_PATTERNS, EXEMPT_FILES). The direction rule, read from each file's
`@import("...zig")` lines:

- a core file imports core files only;
- an operations file imports core and operations files only;
- an interface file imports core and operations files, and another interface
  file only where ALLOWED lists the pair;
- no assigned file imports an exempt file;
- a named module (not a file) is one listed in MODULES, imported by a layer it allows.

Imports are read from the whole file as Zig tokens, so comments and string
contents are never read as code, and an `@import` may span lines, carry spaces and
a trailing comma. Each `.zig` target is resolved against the importing file's
real directory; a target outside `zig/src/`, or naming no file there, fails, as
does an operand Zig would not accept (anything but one string literal).

The checker also fails when a file of `zig/src/` is neither assigned nor exempt,
when an assigned or exempt name no longer exists, when an ALLOWED pair no longer
occurs, and when the generated block of docs/layers.md differs from these
tables (`--write-doc` rewrites that block from them, so the document and the
checker cannot disagree silently).

Usage (from anywhere; no dependencies):

    python3 scripts/check_layers.py              # check; exit 1 on any problem
    python3 scripts/check_layers.py --write-doc  # regenerate docs/layers.md's block
    python3 scripts/check_layers.py --root DIR   # check another copy of the repository

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
MAY_IMPORT = {
    "core": "core only",
    "operations": "core and operations",
    "interfaces": "core and operations; another interface only as an allowed pair",
}

# Path relative to zig/src -> (layer, what the file holds).
FILES = {
    # core: formats, analysis, indexing, ranking, the loaded generation
    "analysis.zig": ("core", "`analyzer-v1`, the ASCII tokenizer"),
    "analyzer_v2.zig": ("core", "`analyzer-v2`, Unicode tokenization (NFC, case folding, letters and digits)"),
    "apply.zig": ("core", "`apply_changes`: host-fed changes published as the next generation"),
    "benchmark.zig": ("core", "the synthetic ranking benchmark behind `searchd benchmark`"),
    "checksum.zig": ("core", "section integrity checksums"),
    "chunker.zig": ("core", "`line-window-v1` and the chunker chosen by path"),
    "chunker_md.zig": ("core", "`md-section-v1`, the Markdown chunker"),
    "engine.zig": ("core", "the opened generation: search, evidence and reads"),
    "fastmem.zig": ("core", "the library's own `memcpy`, `memmove` and `memset`"),
    "filename_field.zig": ("core", "the file-name channel: catalog, lexical section, search"),
    "find.zig": ("core", "`find`: exact words and phrases over one generation"),
    "fold.zig": ("core", "word-form groups: the fold key and the key map"),
    "fuzzy.zig": ("core", "`fuzzy-v1`, misspelling tolerance at query time"),
    "generation_alloc.zig": ("core", "the next free generation number of a directory"),
    "hybrid.zig": ("core", "documents, search options, scope masks, lexical and vector fusion"),
    "importer.zig": ("core", "imports an interchange snapshot written by the Python reference"),
    "incremental_state.zig": ("core", "`INDEX-STATE.json`, the per-file state of updates"),
    "indexer.zig": ("core", "native folder indexing: walk, read, chunk, publish"),
    "lexical_build.zig": ("core", "a postings index from tokenized documents, for any analyzer"),
    "lexical_segment.zig": ("core", "the lexical section format (`HYBLEX`)"),
    "lifecycle.zig": ("core", "the writer lock, generation retention and pruning"),
    "manifest.zig": ("core", "the generation manifest"),
    "nfc.zig": ("core", "Unicode normalization form C"),
    "postings.zig": ("core", "the inverted index, positions and sparse BM25 scoring"),
    "publication.zig": ("core", "atomic publication and recovery"),
    "scope.zig": ("core", "roots, request scope and visible-scope statistics"),
    "scoring.zig": ("core", "BM25, cosine similarity and reciprocal-rank fusion"),
    "segment.zig": ("core", "the documents section format (`HYBSEG`)"),
    "segment_v5.zig": ("core", "documents record v5: the file table and compact records (`HYBSEG01` version 5)"),
    "snapshot_open.zig": ("core", "opens a published generation for querying"),
    "source.zig": ("core", "the source section (`HYBSRC`): file bytes and line maps"),
    "source_v2.zig": ("core", "the source section v2 (`HYBSRC02`): files rebuilt from chunks and residual bytes"),
    "state_section.zig": ("core", "the recovery-state section (`HYBSTATE`)"),
    "title_field.zig": ("core", "`title-field-v1`: folder and file names as a title"),
    "unicode_tables.zig": ("core", "generated Unicode 13.0.0 tables (`scripts/gen_unicode_tables.py`)"),
    "verb_forms.zig": ("core", "the verb-form rule of the fold groups"),
    # operations: the seam every interface calls
    "filename_response.zig": ("operations", "the result object of `filename` and `both` searches, for JSON-RPC, the CLI and the C ABI"),
    "ops.zig": ("operations", "the folder-knowledge operations as canonical JSON (`find`, `outline`, `read_span`, `list_files`, `index_status`, `evidence`, `apply_changes`)"),
    "report.zig": ("operations", "the tail of a query report: `warnings`, `request`, `profile`"),
    "service.zig": ("operations", "the scoped service over an opened generation: search, status, listings, reads"),
    # interfaces: the ways in
    "abi.zig": ("interfaces", "the C ABI (`ss_*`; `zig/include/search_simpli.h`), under the Dart binding"),
    "cli.zig": ("interfaces", "`searchd` commands and their arguments"),
    "main.zig": ("interfaces", "the `searchd` entry: runs a CLI command, `serve` (stdio or loopback HTTP) or `mcp`"),
    "mcp.zig": ("interfaces", "`searchd mcp`: the Model Context Protocol server over stdio"),
    "rpc.zig": ("interfaces", "JSON-RPC 2.0 dispatch for `searchd serve`"),
}

# Exempt from the direction rule; still accounted for, by pattern or by name.
EXEMPT_PATTERNS = (
    ("*_test.zig", "a test, compiled by `zig build test` through `root.zig` or run alone with `zig test`"),
    ("*_bench.zig", "a benchmark, run by hand with `zig run`"),
)
EXEMPT_FILES = {
    "root.zig": "the root of `zig build test`: imports every file so their tests run",
    "nfc_dump.zig": "a test tool for `scripts/nfc_compare.py`, in no build",
}

# (importer, imported), both paths relative to zig/src -> (kind, why).
# kind "entry": by design; kind "debt": to remove (docs/journey/03-next.md).
ALLOWED = {
    ("main.zig", "cli.zig"): ("entry", "the executable parses its command line with the CLI's parser"),
    ("main.zig", "rpc.zig"): ("entry", "the executable runs `serve`, the JSON-RPC server"),
    ("main.zig", "mcp.zig"): ("entry", "the executable runs `mcp`, the MCP server"),
    ("mcp.zig", "cli.zig"): ("debt", "`cli.McpArgs`, the parsed `searchd mcp` arguments"),
    ("mcp.zig", "rpc.zig"): ("debt", "`rpc.Generation` (open and reload) and `rpc.errorCodeOf`"),
    ("abi.zig", "rpc.zig"): ("debt", "`rpc.parseMode` and `rpc.writeSearchResultValueWith`, the `ss_query` result writer"),
}

# Imports that are not files: `std`, `builtin`, and the modules zig/build.zig supplies
# (`addOptions`). Name -> (lowest layer that may import it, or None for any; what it is).
# Any other name is reported, so a new build-supplied module is placed here on purpose.
MODULES = {
    "std": (None, "the Zig standard library"),
    "builtin": (None, "the compilation's target and options"),
    "build_options": ("interfaces", "`contracts_version`, read from `contracts/CONTRACTS_VERSION` by `zig/build.zig`"),
    "tool_schemas": ("interfaces", "the MCP tools' JSON schemas from `contracts/tools/`, read by `zig/build.zig`"),
}
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
    """(line, target, problem) for every `@import` in code, in order.

    The call may span lines and carry spaces anywhere and a trailing comma:
    `@import ( "x.zig" , )`. Zig accepts only one string literal as the operand;
    anything else (a `++` expression, a name, a multiline string) gives target
    None and a problem, as does an invalid escape."""
    toks = list(tokens(text))
    for k, (kind, value, offset) in enumerate(toks):
        if kind != "builtin" or value != "@import":
            continue
        line = text.count("\n", 0, offset) + 1
        if k + 1 >= len(toks) or toks[k + 1][:2] != ("punct", "("):
            yield line, None, "@import without an argument list"
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
            yield line, None, f"@import's operand is not one string literal ({shown}); the checker cannot resolve it"
            continue
        target = _decode(args[0][1])
        if target is None:
            yield line, None, f"@import's string has an invalid escape ({args[0][1]})"
            continue
        yield line, target, None


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


def exempt_reason(rel: str, exempt_files, exempt_patterns):
    if rel in exempt_files:
        return exempt_files[rel]
    name = posixpath.basename(rel)
    for pattern, reason in exempt_patterns:
        if fnmatch.fnmatchcase(name, pattern):
            return reason
    return None


def _script_line(*names: str) -> str:
    """`scripts/check_layers.py:N` for the line of this script naming all of names."""
    try:
        lines = Path(__file__).read_text(encoding="utf-8").splitlines()
    except OSError:
        lines = []
    quoted = [f'"{name}"' for name in names]
    for number, line in enumerate(lines, 1):
        if all(q in line for q in quoted):
            return f"scripts/check_layers.py:{number}"
    return "scripts/check_layers.py"


def render_doc(files=None, allowed=None, exempt_files=None, exempt_patterns=None) -> str:
    """The generated block of docs/layers.md, markers included."""
    files = FILES if files is None else files
    allowed = ALLOWED if allowed is None else allowed
    exempt_files = EXEMPT_FILES if exempt_files is None else exempt_files
    exempt_patterns = EXEMPT_PATTERNS if exempt_patterns is None else exempt_patterns
    out = [BEGIN, ""]
    counts = {layer: sum(1 for v in files.values() if v[0] == layer) for layer in LAYER_ORDER}
    out.append("| Layer | Files | May import |")
    out.append("|---|---:|---|")
    for layer in LAYER_ORDER:
        out.append(f"| {layer} | {counts[layer]} | {MAY_IMPORT[layer]} |")
    out += ["", "| File (`zig/src/`) | Layer | What it holds |", "|---|---|---|"]
    for rel, (layer, role) in sorted(files.items(), key=lambda kv: (LAYER_ORDER.index(kv[1][0]), kv[0])):
        out.append(f"| `{rel}` | {layer} | {role} |")
    out += ["", "Imports between interfaces that are allowed (any other fails the check):", ""]
    out += ["| File | Imports | Kind | What it uses |", "|---|---|---|---|"]
    for (importer, imported), (kind, why) in sorted(allowed.items(), key=lambda kv: (kv[1][0] != "entry", kv[0])):
        out.append(f"| `{importer}` | `{imported}` | {kind} | {why} |")
    out += ["", "Imports that are not files (any other name fails the check):", ""]
    out += ["| Module | Who may import it | What it is |", "|---|---|---|"]
    for name, (lowest, what) in MODULES.items():
        who = "any file" if lowest is None else \
            ", ".join(LAYER_ORDER[LAYER_ORDER.index(lowest):]) + " and exempt files"
        out.append(f"| `{name}` | {who} | {what} |")
    out += ["", "Exempt from the direction rule (still accounted for):", ""]
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


def check(root: Path, files=None, allowed=None, exempt_files=None, exempt_patterns=None, doc=True):
    """Every problem found, as `path:line: message` strings (empty when clean)."""
    files = FILES if files is None else files
    allowed = ALLOWED if allowed is None else allowed
    exempt_files = EXEMPT_FILES if exempt_files is None else exempt_files
    exempt_patterns = EXEMPT_PATTERNS if exempt_patterns is None else exempt_patterns
    problems = []
    src = root / SRC
    present = zig_files(src)
    present_set = set(present)

    for rel in sorted(set(files) & set(exempt_files)):
        problems.append(f"{_script_line(rel)}: {rel} is both assigned to a layer and exempt")
    for (importer, imported) in sorted(allowed):
        if files.get(importer, ("",))[0] != "interfaces" or files.get(imported, ("",))[0] != "interfaces":
            problems.append(f"{_script_line(importer, imported)}: allowed pair {importer} -> {imported} "
                            "is not between two interface files")

    for rel in sorted(files):
        if rel not in present_set:
            problems.append(f"{_script_line(rel)}: FILES names {SRC}/{rel}, which does not exist")
    for rel in sorted(exempt_files):
        if rel not in present_set:
            problems.append(f"{_script_line(rel)}: EXEMPT_FILES names {SRC}/{rel}, which does not exist")

    used = set()
    for rel in present:
        if rel in files:
            layer = files[rel][0]
        elif exempt_reason(rel, exempt_files, exempt_patterns) is not None:
            layer = None  # exempt from the direction rule; its imports must still resolve
        else:
            layer = None
            problems.append(f"{SRC}/{rel}:1: not assigned to a layer: add it to FILES in "
                            "scripts/check_layers.py (core, operations or interfaces), "
                            "then run scripts/check_layers.py --write-doc")
        text = (src / rel).read_text(encoding="utf-8", errors="replace")
        for number, target, problem in imports_of(text):
            where = f"{SRC}/{rel}:{number}"
            if problem is not None:
                problems.append(f"{where}: {problem}")
                continue
            if not target.endswith(".zig"):
                if target not in MODULES:
                    problems.append(f"{where}: imports {target!r}, which is neither a .zig file nor a "
                                    "module listed in MODULES (scripts/check_layers.py)")
                elif layer is not None and MODULES[target][0] is not None and \
                        LAYER_ORDER.index(layer) < LAYER_ORDER.index(MODULES[target][0]):
                    problems.append(f"{where}: {layer} file imports the module {target}, "
                                    f"which only {MODULES[target][0]} may import")
                continue
            dep = resolve(src, rel, target)
            if dep is None:
                problems.append(f"{where}: imports {target}, which is outside {SRC}/")
                continue
            if dep in files:
                dep_layer = files[dep][0]
            elif exempt_reason(dep, exempt_files, exempt_patterns) is not None and dep in present_set:
                if layer is not None:
                    problems.append(f"{where}: {layer} file imports {target}, a test, benchmark or tool file")
                continue
            elif dep in present_set:
                problems.append(f"{where}: imports {target} ({SRC}/{dep}), which is not assigned to a layer")
                continue
            else:
                problems.append(f"{where}: imports {target}, which resolves to {SRC}/{dep}: no such file")
                continue
            if layer is None:
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

    for pair in sorted(set(allowed) - used):
        importer, imported = pair
        if importer in present_set and imported in present_set:
            problems.append(f"{_script_line(importer, imported)}: allowed pair {importer} -> {imported} "
                            "no longer occurs: remove it from ALLOWED")

    if doc:
        doc_path = root / DOC
        expected = render_doc(files, allowed, exempt_files, exempt_patterns)
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
    args = parser.parse_args(argv)
    root = args.root.resolve()
    if args.write_doc:
        write_doc(root)
    problems = check(root)
    for problem in problems:
        print(problem)
    assigned = len(FILES)
    if problems:
        print(f"check_layers: {len(problems)} problem(s)")
        return 1
    print(f"check_layers: OK ({assigned} files in layers, {len(ALLOWED)} allowed interface imports)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

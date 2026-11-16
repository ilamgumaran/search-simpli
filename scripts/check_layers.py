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
- no assigned file imports an exempt file.

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
    "snapshot_open.zig": ("core", "opens a published generation for querying"),
    "source.zig": ("core", "the source section (`HYBSRC`): file bytes and line maps"),
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

IMPORT = re.compile(r'@import\(\s*"([^"]+)"\s*\)')
BEGIN = "<!-- BEGIN generated by scripts/check_layers.py --write-doc: edit the script, not this block -->"
END = "<!-- END generated by scripts/check_layers.py -->"


def code_part(line: str) -> str:
    """The line without its `//` comment; string and character literals blanked.

    A line of a Zig multiline string literal (`\\\\...`) has no code at all.
    """
    if line.lstrip().startswith("\\\\"):
        return ""
    out = []
    i = 0
    while i < len(line):
        ch = line[i]
        if ch == "/" and line.startswith("//", i):
            break
        if ch in "\"'":
            quote = ch
            j = i + 1
            while j < len(line) and line[j] != quote:
                j += 2 if line[j] == "\\" else 1
            literal = line[i : j + 1]
            # Keep string literals (an import's argument is one); blank characters.
            out.append(literal if quote == '"' else "' '")
            i = j + 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def imports_of(text: str):
    """(line number, import string) for every `@import` in code, in order."""
    for number, line in enumerate(text.splitlines(), 1):
        for match in IMPORT.finditer(code_part(line)):
            yield number, match.group(1)


def zig_files(src: Path):
    """Every `.zig` file under src, relative and with `/`, skipping dot folders."""
    found = []
    for path in src.rglob("*.zig"):
        rel = path.relative_to(src)
        if any(part.startswith(".") for part in rel.parts):
            continue
        found.append(rel.as_posix())
    return sorted(found)


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
            continue
        else:
            problems.append(f"{SRC}/{rel}:1: not assigned to a layer: add it to FILES in "
                            "scripts/check_layers.py (core, operations or interfaces), "
                            "then run scripts/check_layers.py --write-doc")
            continue
        text = (src / rel).read_text(encoding="utf-8", errors="replace")
        for number, target in imports_of(text):
            if not target.endswith(".zig"):
                continue  # std, builtin and build-supplied modules
            dep = posixpath.normpath(posixpath.join(posixpath.dirname(rel), target))
            where = f"{SRC}/{rel}:{number}"
            if dep in files:
                dep_layer = files[dep][0]
            elif exempt_reason(dep, exempt_files, exempt_patterns) is not None:
                problems.append(f"{where}: {layer} file imports {target}, a test, benchmark or tool file")
                continue
            else:
                continue  # outside zig/src or unassigned (reported above)
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

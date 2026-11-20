# Layers: the core and the interfaces

**State:** written by S6-T1 (16 Nov 2026, from `main` at `7cd2c16`), item B1 of the
[objective plan](plans/2026-11-16-objective-plan.md); the folders by S6-T14 (item B2),
which moved every file into its layer's folder without changing what it does; the
check that every test runs by S6-T15.

The engine's Zig sources form three layers, and each layer is a folder of `zig/src/`
and a Zig module. The core can be improved without touching an interface, and a new
interface can be added without touching the core, as long as imports run one way only:

```text
bindings     bindings/dart (later: JavaScript, Swift, Kotlin, Python)   -> the C ABI only
interfaces/  abi.zig · cli.zig + main.zig · rpc.zig · mcp.zig          -> operations, core
ops/         service.zig · ops.zig · report.zig · filename_response.zig -> core   (module `operations`)
core/        formats, analysis, indexing, ranking, the opened generation -> core   (module `core`)
tests/       the tests, benchmarks and tools that cross layers          -> any module
```

`zig/build.zig` builds `core/` as the module `core` (root `core/core.zig`) and `ops/`
as the module `operations` (root `ops/operations.zig`, which imports `core`). The
`searchd` executable (`interfaces/main.zig`) and the C ABI libraries
(`interfaces/abi.zig`) import both. An interface reaches a core file as
`@import("core").engine` and an operations file as `@import("operations").service`;
a file imports another file of its own folder by path, as before. A third module,
`interfaces` (root `interfaces/interfaces.zig`), exists only for the tests in `tests/`.

`zig build test` runs one test step per folder (core, operations, interfaces, tests)
and the `fastmem` step, because a Zig test build only collects the tests of its root
module's files. A module root names its folder's files in a `comptime` block that is
compiled in a test build only, so it adds no test of its own; the totals are the same
as when every file sat in one folder. The checker fails when a module root leaves out
a file of its folder, and when a file holding a test is reached by no step (below).

`scripts/check_layers.py` holds the assignment of every file and checks it. It runs
in CI (the `checks` job, no Zig needed) and through `python3 -m unittest`
(`tests/test_check_layers.py`). `scripts/check_test_counts.py` runs `zig build test
--summary all` and compares each step's total with the checker's listing; it runs in
CI where the Zig tests run (the `native-linux` job in Debug and `native-linux-release`
in ReleaseSmall) and is tested by `tests/test_check_test_counts.py`. Run both yourself
with:

```sh
python3 scripts/check_layers.py
python3 scripts/check_test_counts.py --run      # needs Zig 0.16 on PATH
```

## What each layer may import

- **Core** (`core/`) imports core files only, by path within its folder. It knows
  nothing of JSON-RPC, MCP, the command line or the C ABI: no core file imports the
  module `operations`, the module `interfaces` or a path outside `core/`.
- **Operations** (`ops/`) imports the module `core` and operations files. It is the
  one seam every interface calls: the scoped service, the folder-knowledge operations
  as canonical JSON (so every surface answers the same request with the same bytes),
  and the shared parts of a query report.
- **Interfaces** (`interfaces/`) import the modules `core` and `operations`. An
  interface importing another interface fails the check unless the pair is listed as
  allowed (below).
- **Tests, benchmarks and tools** (`*_test.zig`, `*_bench.zig`, `tests/root.zig`,
  `core/nfc_dump.zig`) sit beside their subject when they import one layer's files
  only, and are held to that layer's rule there. One that crosses layers sits in
  `tests/` and may import any module. No layer's file imports them, by path or
  through a module.
- **No path leaves its folder.** A `.zig` import resolves inside the importing file's
  own folder; another layer is reached through its module, never by `../`.
- **Bindings** sit outside `zig/src/`. The Dart package (`bindings/dart/search_simpli/`)
  calls the C ABI through `dart:ffi`, generated from `zig/include/search_simpli.h`;
  it never sees a Zig file. A later binding (JavaScript over WebAssembly, Swift,
  Kotlin, Python) does the same.
- **The Python reference** (`src/search_platform/`, `search.py` and the scripts
  beside it) is a separate implementation that pins behaviour. It talks to the
  engine only as a process (`searchd`) and is not part of this check.

## Imports between interfaces, today

The plan named one: `mcp.zig` imports `cli.zig`. The import graph has three such
imports that are debt, and three more that are by design:

- **By design (entry).** `main.zig` is the `searchd` executable: it parses the command
  line with `cli.zig` and then runs a CLI command, `serve` (`rpc.zig`, over stdio or
  loopback HTTP) or `mcp` (`mcp.zig`). An executable's entry starts the interfaces it
  hosts.
- **Debt.** `mcp.zig` imports `cli.zig` for `cli.McpArgs`; `mcp.zig` imports `rpc.zig`
  for `rpc.Generation` (open and reload of the served generation) and `rpc.errorCodeOf`;
  `abi.zig` imports `rpc.zig` for `rpc.parseMode` and the `ss_query` result writer
  (`rpc.writeSearchResultValueWith`). Each is shared code that belongs in operations.
  [03-next](journey/03-next.md) has a row to remove them. S6-T14 moved the files only
  and left these imports as they were, since removing them changes function bodies.

The checker fails on any other import between interfaces, and on an allowed pair
that no longer occurs, so the list can only shrink by being edited.

## Every file

Generated from `scripts/check_layers.py`; the checker fails when this block differs
from its tables.

<!-- BEGIN generated by scripts/check_layers.py --write-doc: edit the script, not this block -->

| Layer | Folder (`zig/src/`) | Module | Files | May import |
|---|---|---|---:|---|
| core | `core/` | `core` (`core/core.zig`) | 36 | core only |
| operations | `ops/` | `operations` (`ops/operations.zig`) | 4 | core and operations |
| interfaces | `interfaces/` | `interfaces` (`interfaces/interfaces.zig`) | 5 | core and operations; another interface only as an allowed pair |

| File (`zig/src/`) | Layer | What it holds |
|---|---|---|
| `core/analysis.zig` | core | `analyzer-v1`, the ASCII tokenizer |
| `core/analyzer_v2.zig` | core | `analyzer-v2`, Unicode tokenization (NFC, case folding, letters and digits) |
| `core/apply.zig` | core | `apply_changes`: host-fed changes published as the next generation |
| `core/benchmark.zig` | core | the synthetic ranking benchmark behind `searchd benchmark` |
| `core/checksum.zig` | core | section integrity checksums |
| `core/chunker.zig` | core | `line-window-v1` and the chunker chosen by path |
| `core/chunker_md.zig` | core | `md-section-v1`, the Markdown chunker |
| `core/engine.zig` | core | the opened generation: search, evidence and reads |
| `core/fastmem.zig` | core | the library's own `memcpy`, `memmove` and `memset` |
| `core/filename_field.zig` | core | the file-name channel: catalog, lexical section, search |
| `core/find.zig` | core | `find`: exact words and phrases over one generation |
| `core/fold.zig` | core | word-form groups: the fold key and the key map |
| `core/fuzzy.zig` | core | `fuzzy-v1`, misspelling tolerance at query time |
| `core/generation_alloc.zig` | core | the next free generation number of a directory |
| `core/hybrid.zig` | core | documents, search options, scope masks, lexical and vector fusion |
| `core/importer.zig` | core | imports an interchange snapshot written by the Python reference |
| `core/incremental_state.zig` | core | `INDEX-STATE.json`, the per-file state of updates |
| `core/indexer.zig` | core | native folder indexing: walk, read, chunk, publish |
| `core/lexical_build.zig` | core | a postings index from tokenized documents, for any analyzer |
| `core/lexical_segment.zig` | core | the lexical section format (`HYBLEX`) |
| `core/lifecycle.zig` | core | the writer lock, generation retention and pruning |
| `core/manifest.zig` | core | the generation manifest |
| `core/nfc.zig` | core | Unicode normalization form C |
| `core/postings.zig` | core | the inverted index, positions and sparse BM25 scoring |
| `core/publication.zig` | core | atomic publication and recovery |
| `core/scope.zig` | core | roots, request scope and visible-scope statistics |
| `core/scoring.zig` | core | BM25, cosine similarity and reciprocal-rank fusion |
| `core/segment.zig` | core | the documents section format (`HYBSEG`) |
| `core/segment_v5.zig` | core | documents record v5: the file table and compact records (`HYBSEG01` version 5) |
| `core/snapshot_open.zig` | core | opens a published generation for querying |
| `core/source.zig` | core | the source section (`HYBSRC`): file bytes and line maps |
| `core/source_v2.zig` | core | the source section v2 (`HYBSRC02`): files rebuilt from chunks and residual bytes |
| `core/state_section.zig` | core | the recovery-state section (`HYBSTATE`) |
| `core/title_field.zig` | core | `title-field-v1`: folder and file names as a title |
| `core/unicode_tables.zig` | core | generated Unicode 13.0.0 tables (`scripts/gen_unicode_tables.py`) |
| `core/verb_forms.zig` | core | the verb-form rule of the fold groups |
| `ops/filename_response.zig` | operations | the result object of `filename` and `both` searches, for JSON-RPC, the CLI and the C ABI |
| `ops/ops.zig` | operations | the folder-knowledge operations as canonical JSON (`find`, `outline`, `read_span`, `list_files`, `index_status`, `evidence`, `apply_changes`) |
| `ops/report.zig` | operations | the tail of a query report: `warnings`, `request`, `profile` |
| `ops/service.zig` | operations | the scoped service over an opened generation: search, status, listings, reads |
| `interfaces/abi.zig` | interfaces | the C ABI (`ss_*`; `zig/include/search_simpli.h`), under the Dart binding |
| `interfaces/cli.zig` | interfaces | `searchd` commands and their arguments |
| `interfaces/main.zig` | interfaces | the `searchd` entry: runs a CLI command, `serve` (stdio or loopback HTTP) or `mcp` |
| `interfaces/mcp.zig` | interfaces | `searchd mcp`: the Model Context Protocol server over stdio |
| `interfaces/rpc.zig` | interfaces | JSON-RPC 2.0 dispatch for `searchd serve` |

Module roots (only `pub const` imports of their folder's files):

| File (`zig/src/`) | Module | What it is |
|---|---|---|
| `core/core.zig` | `core` | the module `core`: every core file but `fastmem.zig`, and every core test |
| `ops/operations.zig` | `operations` | the module `operations` (it imports `core`): every operations file |
| `interfaces/interfaces.zig` | `interfaces` | the module `interfaces`, for the tests in `tests/`: every interface file but `main.zig`, and `field_warnings_test.zig` |

The roots `zig/build.zig` compiles (a test step runs the tests of the files its root reaches by path):

| File (`zig/src/`) | Step of `zig build test` | What it is the root of |
|---|---|---|
| `core/core.zig` | `core` | the module `core`, and the test step `core` |
| `ops/operations.zig` | `operations` | the module `operations`, and the test step `operations` |
| `interfaces/interfaces.zig` | `interfaces` | the module `interfaces` (for `tests/`), and the test step `interfaces` |
| `tests/root.zig` | `tests` | the test step `tests`: the cross-layer tests |
| `core/fastmem.zig` | `fastmem` | the `fastmem` object, and its own test step (`run test` in the Build Summary) |
| `interfaces/main.zig` | none | the `searchd` executable |
| `interfaces/abi.zig` | none | the C ABI libraries, and the library of `zig build test-abi` |

Imports between interfaces that are allowed (any other fails the check):

| File | Imports | Kind | What it uses |
|---|---|---|---|
| `interfaces/main.zig` | `interfaces/cli.zig` | entry | the executable parses its command line with the CLI's parser |
| `interfaces/main.zig` | `interfaces/mcp.zig` | entry | the executable runs `mcp`, the MCP server |
| `interfaces/main.zig` | `interfaces/rpc.zig` | entry | the executable runs `serve`, the JSON-RPC server |
| `interfaces/abi.zig` | `interfaces/rpc.zig` | debt | `rpc.parseMode` and `rpc.writeSearchResultValueWith`, the `ss_query` result writer |
| `interfaces/mcp.zig` | `interfaces/cli.zig` | debt | `cli.McpArgs`, the parsed `searchd mcp` arguments |
| `interfaces/mcp.zig` | `interfaces/rpc.zig` | debt | `rpc.Generation` (open and reload) and `rpc.errorCodeOf` |

Imports that are not files (any other name fails the check):

| Module | Who may import it | What it is |
|---|---|---|
| `std` | any file | the Zig standard library |
| `builtin` | any file | the compilation's target and options |
| `core` | files of operations, interfaces and tests | the core layer, `core/core.zig` (S6-T14) |
| `operations` | files of interfaces and tests | the operations layer, `ops/operations.zig` (S6-T14) |
| `interfaces` | files of tests | the interfaces, `interfaces/interfaces.zig`, for the cross-layer tests (S6-T14) |
| `build_options` | files of interfaces and tests | `contracts_version`, read from `contracts/CONTRACTS_VERSION` by `zig/build.zig` |
| `tool_schemas` | files of interfaces and tests | the MCP tools' JSON schemas from `contracts/tools/`, read by `zig/build.zig` |

Tests, benchmarks and tools (in their subject's layer folder, or `tests/` when they cross layers):

| File or pattern | Why |
|---|---|
| `*_test.zig` | a test: named in its folder's module root, or reached from the test block of `tests/root.zig`, so that its folder's step of `zig build test` runs it (or run alone with `zig test`) |
| `*_bench.zig` | a benchmark, run by hand with `zig run` (zig/README.md) |
| `core/nfc_dump.zig` | a test tool for `scripts/nfc_compare.py`, in no build |
| `tests/root.zig` | the root of the cross-layer tests' step of `zig build test`: names every module and every test in `tests/` |

<!-- END generated by scripts/check_layers.py -->

## Adding a new interface, or a core feature

**A new interface** (a WebAssembly entry, an HTTP server, a new command) is a new file
in `interfaces/`, assigned to `interfaces` in `scripts/check_layers.py`. It calls
`@import("operations").service` and `.ops` (and core types through `@import("core")`
where it must), never another interface; if it needs something an interface already
has (argument parsing, a result writer), move that piece into operations first.
**A core feature** (a new section, an analyzer, a ranking rule) is a file in `core/`
that imports core files only; add it to `core/core.zig` so the other folders can reach
it. The interfaces reach it through operations, so add the operation (and its JSON in
`ops/ops.zig`) beside it. A new operations file goes in `ops/` and in
`ops/operations.zig`. In every case run `python3 scripts/check_layers.py --write-doc`
to regenerate the table above, then `python3 scripts/check_layers.py`. A change to a
contract, an index format or the C ABI still needs its
[capability document](capability-process.md) first.

**A new test** sits beside its subject (an in-file `test` block, or `core/x_test.zig`)
or, when it crosses layers, in `tests/`, and runs only when a step's root reaches its
file by path. In `core/`, `ops/` or `interfaces/` that means a `pub const` in the
folder's module root and a `_ = name;` line in the root's test-build `comptime` block
(every file of the folder is named there, tested or not); in `tests/`, a `pub const`
in `tests/root.zig` and a `_ = name;` line in its test block, or an import that a
reached test compiles. A file reached only through a module (`@import("core").name`)
does not count, since a test build runs the tests of its root module's files only.
`python3 scripts/check_layers.py` fails, naming the file, when a file that holds a
`test` is reached by no step, and `--list-tests` prints which step runs each file's
tests and how many there are. Whether those are the tests Zig runs is settled by
`python3 scripts/check_test_counts.py --run`: it fails when a step's total in
`zig build test --summary all` differs from the listing, or a step is missing or extra.

## What the check reads, and what it does not

It reads every `.zig` file under `zig/src/` (dot folders included) as Zig tokens, so
text in a comment (`//`, `///`, `//!`), a string, a character literal or a multiline
`\\` string is never taken for code. An `@import` is found however it is laid out:
across lines, with spaces before or inside the parentheses, with a trailing comma
(`zig fmt`'s own layout), with escapes in its string, and the name after it
(`@import("core").engine`) is read as well. Each `.zig` target is resolved against
the importing file's real directory, so `../ops/ops.zig` from `zig/src/core/engine.zig`
is `ops/ops.zig`, and fails as a path into another folder. A target that leaves
`zig/src/`, or names no file there, fails; so does an unassigned file that is imported,
a name a module root does not export, and an import whose operand is not one string
literal (`"o" ++ "ps.zig"`, a `const` holding the path, a multiline string): Zig itself
refuses those, and the checker reports them rather than guess. Imports that are not
files must be named in the "Imports that are not files" table above, and only the
folders listed there may use them; an unknown name fails. A file directly in
`zig/src/`, in an unknown folder, or in a folder other than its layer's, fails.

**Which tests run.** The roots are the `"src/....zig"` strings of `zig/build.zig`, each
listed in the roots table above with its test step (the checker fails on a root
missing from either side). The steps are read from the build's structure: the rows of
`test_roots` (`.{ .name = "...", .path = "src/....zig" }`) compiled in the loop over
them, and every other `b.addTest`, with the root of its module. The checker fails
when the `test` step does not run a test the build compiles (a `dependOn` dropped), when
a step's root is not the one the roots table gives that step (a row deleted, or one
root pasted into another row), or when it cannot read that structure.

From a step's root it follows the `.zig` imports a test build compiles. It starts from
the file's `test` blocks and container-level `comptime` blocks, and adds each
declaration of the same file they name, directly or through other declarations
(`_ = engine;` compiles `const engine = @import("engine.zig");`); then on from file to
file. Not followed: a name inside a function body (compiled only if the function is
called), a name under a guard that is false in a test build (`if (false)`,
`if (!@import("builtin").is_test)`), a name after `.` (a member) or before `:` (a field
or a label), and an `@import` inside a nested `struct`, `enum`, `union` or `opaque`.
Imports through a module are not followed for tests. A test counts when it is a
top-level test of a reached file, or sits inside a declaration that is followed (a
nested struct a test names, a generic function a test calls) and not under a false
guard; a reached file with a test that does not count fails.

**What it cannot see, and which way it errs.** Its reading of Zig is not exact, and
`scripts/check_test_counts.py`, which compares each step's total with a real run, is
the authority. Its listing takes the steps from the roots table, not from
`zig/build.zig`, so a step the build loses still shows as missing from the run; it
matches them by the name the Build Summary prints after `run test` (the step's own
name, and none for `fastmem`). The checker's limits:

- *Strict* (it fails a test that does run): an import compiled only through a function
  that a test calls, in the same file or another (`std.testing.refAllDecls` included),
  or through a nested container's declaration that a test names (`Fixture.data`). The
  fix the message names, naming the file in its root, makes both agree.
- *Lenient* (it passes a test that does not run): a followed declaration is taken
  whole, so a name in it reaches though nothing compiled uses that part (a field's
  default value, a `const` alias inside a struct no test reaches into); a generic
  function a test names but never calls; a branch compiled out by a condition other
  than the three false guards (`if (builtin.os.tag == .windows)`, an `else` of
  `is_test`). The count comparison catches each, as a step's total one lower than
  the listing.
- *Not read at all*: what a named module added with `addImport` or `addOptions`
  contains (a new one must be listed, its contents are not read); `@embedFile` and
  `@cImport`, which bring in bytes or C declarations rather than Zig files; and imports
  in files outside `zig/src/` (`zig/build.zig`, `zig/tests/`).

For the import rules (the layer boundary), every `@import` in a file counts wherever it
is written, compiled or not, so an import under `if (false)` still fails a boundary it
crosses: there the check errs on the strict side. It does not judge the bindings or the
Python reference.

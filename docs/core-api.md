# The public core API

**State:** written by [S6-T16](tasks/S6-T16.md) (20 Nov 2026, from `main` at `10f3d40`),
step B3 of the [objective plan](plans/2026-11-16-objective-plan.md). It adds names,
aliases and doc comments only: no function body, format, contract or answer changed.
[S6-T18](tasks/S6-T18.md) (21 Nov 2026) replaced `title_field.derive` with the core call
`engine.queryOneShot`, the first of the follow-ups below; the answers did not change.
[S6-T19](tasks/S6-T19.md) (21 Nov 2026) moved the two tests beside the code that used
`analyzer_v2.analyzer_id` and `manifest.decode` to `zig/src/tests/`, and those two names
left `api`; no shipped code changed. [S6-T20](tasks/S6-T20.md) (21 Nov 2026) moved the
choice of a full rebuild's generation number into the core, under the writer lock, and
`generation_alloc.nextFreeGeneration` left `api`.

The core is one Zig module, `core` (root `zig/src/core/core.zig`; see
[layers.md](layers.md)). Its root has two parts:

- **`api`, the public core API.** The names an operation or an interface may use, one
  namespace per core file they come from, named as the file (`api.engine`,
  `api.snapshot_open`, ...). Each name is an alias of that file's own declaration
  under its own name, `pub const Engine = internal.engine.Engine;`, so it is the same
  type or function and adds no code. Every namespace and name has a doc comment: what
  it does, who owns the memory it returns, and which errors come back.
- **The rest, every core file by name** (`@import("core").engine`, 55 files). It is
  internal: the core's own files and tests reach each other by path inside `core/`,
  and the tests in `zig/src/tests/` reach a core file through the module.

## The rule

A file in `zig/src/ops/` or `zig/src/interfaces/`, its tests included, reaches the core
only through `api`:

```zig
const core = @import("core").api;              // the whole API
const engine_module = @import("core").api.engine; // or one namespace, as the files do today
```

and uses only names `api` has. `python3 scripts/check_layers.py` fails, naming the file,
the line and the name, on any other core name there: an internal file
(`@import("core").engine`), a namespace `api` lacks, a name its namespace lacks, the
module used whole (passed, `@field`, `@typeInfo`), and any binding of the whole module,
`const c = @import("core");`, wherever it is (a block, a struct, `pub`): an alias always
starts at `api`. It reads the uses from Zig tokens, inline and through aliases in the
block they are bound in, as its other rules are read. It also checks `api` itself: each
namespace is a core file the root exports, each entry is exactly
`pub const NAME = internal.<file>.NAME;` of a top-level `pub` declaration of that file,
each carries a `///` doc comment, and `internal` is never `pub`. Zig refuses a name `api`
lacks when the code is compiled; the checker gives the line without a toolchain, and also
catches the internal path, which compiles.

**What the guard does not catch.** With every alias starting at `api`, an internal can
only be written as `@import("core").<file>` (inline or bound) or through the module whole,
and all of those fail. What remains:

- *The members of a published type are public too.* `api.engine.Engine` brings every
  `pub` field, method and nested declaration of `Engine` (`Engine.open`, `Engine.openWith`,
  which open an engine without `snapshot_open`); the checker does not read past
  `api.<namespace>.<name>`, and Zig accepts them. Publishing a type publishes its members.
- *The tests in `tests/`,* by design.
- *What the checker does not read at all:* `@embedFile` and `@cImport`. A path import of a
  core file from `ops/` or `interfaces/` fails the folder rule, and Zig refuses it too.

**Cross-layer tests may use internals.** A test in `zig/src/tests/` may name any `pub`
declaration of any core file, through `@import("core").<file>`; the rule does not read
`tests/`. A test beside its subject in `core/` imports by path. The rule binds the tests
inside `ops/` and `interfaces/` (in-file `test` blocks, `field_warnings_test.zig`) like
the code beside them.

A type's fields and methods come with the type: `api.engine.Engine` is the whole
`Engine`, its `queryTraced`, `evidence` and the rest, documented in `engine.zig`.

## The names, by purpose

101 names in 24 namespaces, as `python3 scripts/check_layers.py` counts them in its last
line ("the public core API `api`: 101 names in 24 namespaces"): every core name operations
and interfaces used at `10f3d40` (the measurement,
[`docs/evidence/s6-t16/measure.txt`](evidence/s6-t16/measure.txt)), less
`title_field.derive` and with `engine.queryOneShot` in its place (S6-T18), less
`analyzer_v2.analyzer_id` and `manifest.decode` (S6-T19), less
`generation_alloc.nextFreeGeneration` (S6-T20), with
`generation_alloc.describeStaleGeneration` added (S6-T21: `main.zig` and `abi.zig`
print the line of a caller's number refused as stale), with S6-T24's 15 for `scan`
(`pattern.Mode`, `pattern.Case` and 13 in `scan`), and nothing else. Every one of
the 101 is used by a declaration of `ops/` or `interfaces/` that is not a test
([`docs/evidence/s6-t19/measure.txt`](evidence/s6-t19/measure.txt) and
[`after.txt`](evidence/s6-t19/after.txt)). Their doc comments in `core.zig` say what each does, what it allocates and what it
returns.

| Purpose | Namespace | Names | Count |
|---|---|---|---:|
| Open a generation | `snapshot_open` | `open`, `openDetached`, `openScoped`, `openScopedWith`, `openScopedDetached`, `close`, `Sections` | 7 |
| | `engine` | `Engine`, `Evidence` | 2 |
| Search | `hybrid` | `Document`, `Result`, `RetrievalMode`, `RootMask`, `SearchOptions`, `Trace`, `search`, `isAuthorized`, `matchesPath`, `no_source_doc` | 10 |
| | `engine` | `queryOneShot` | 1 |
| | `scoring` | `isValidVector` | 1 |
| | `filename_field` | `Field`, `Hit`, `tokenize` | 3 |
| | `scope` | `Request`, `Folder`, `View`, `visibleCollection`, `documentFrequency`, `holdsAll`, `recordPath`, `relativePath`, `rootOfPath`, `isLegacy`, `legacy_root_id` | 11 |
| Find | `find` | `Request`, `Mode`, `Outcome`, `find`, `writeFields`, `default_page_size`, `max_page_size`, `stale_cursor_message` | 8 |
| Scan (S6-T24) | `scan` | `Request`, `Outcome`, `Candidate`, `NotScanned`, `default_page_size`, `default_max_hits_per_file`, `default_time_budget_ms`, `indexSource`, `folderSource`, `run`, `inScope`, `IoClock`, `writeJson` | 13 |
| | `pattern` | `Mode`, `Case` | 2 |
| Read a span | `source` | `readSpan`, `SpanResult`, `outline`, `OutlineResult`, `Failure`, `Code`, `writeSpanFields`, `writeOutlineFields`, `max_context_lines`, `source_absent_message` | 10 |
| Apply changes | `apply` | `applyChanges`, `Options`, `writeReportJson`, `default_max_file_bytes`, `default_max_total_bytes` | 5 |
| Build an index | `indexer` | `indexFolder`, `indexFolderIncremental`, `buildFolderDetached`, `Caps`, `IncrementalReport`, `AnalyzerId` | 6 |
| | `chunker` | `default_max_chars`, `default_overlap_lines` | 2 |
| | `generation_alloc` | `describeNoFreeGeneration`, `describeStaleGeneration` | 2 |
| | `title_field` | `policy_id` | 1 |
| Write a generation by hand | `importer` | `importJson`, `importJsonKeeping` | 2 |
| | `manifest` | `create`, `encode`, `PendingEntry` | 3 |
| | `segment` | `encode` | 1 |
| | `lexical_segment` | `encode` | 1 |
| | `postings` | `build`, `TermEntry`, `Posting` | 3 |
| | `lifecycle` | `publishSerialized` | 1 |
| Benchmark | `benchmark` | `run`, `max_documents`, `max_dimensions`, `max_queries` | 4 |
| The formats' identities | `fold` | `policy_id` | 1 |
| | `fuzzy` | `policy_id` | 1 |

By purpose: open 9, search 26, find 8, scan 15, read a span 10, apply 5, build an index 11, write a
generation by hand 11, benchmark 4, the formats' identities 2 (a third,
`title_field.policy_id`, sits with its file under build an index). The `engine` namespace
appears twice: `Engine` and `Evidence` open a generation, `queryOneShot` searches it.

Until S6-T19, `analyzer_v2.analyzer_id` and `manifest.decode` were used only in one test
block each, of `ops/filename_response.zig` and `interfaces/abi.zig`, and were public
because the rule binds tests beside the code too. Those two tests now sit in
`zig/src/tests/` (`filename_response_test.zig`, `abi_index_folder_test.zig`), where
internals are allowed, and the names left `api`. A test that only an internal name lets
you write belongs in `tests/`, not beside the code.

## Memory and errors

**Memory.** Every function that allocates takes the allocator it allocates from, and
what it returns lives there. The callers give an arena (one per command, request or
handle) and release it whole; the doc comment says so where a function relies on it
(`applyChanges`, the indexers, `find`). Exceptions, each documented: a scoped open
(`openScoped`, `openScopedWith`, `openScopedDetached`) keeps open files and, with
`openScopedWith`, exact blocks outside the arena, released by `snapshot_open.close`
before the arena goes; `engine.queryOneShot` needs an arena, since its result buffer
(one slot per chunk) and the title field it derives for an engine without a folder are
not freed separately (a scoped open's engine ranks with its folder's field, which the
open keeps); `scope.View`'s group flags are freed with `View.deinit`; a detached
open borrows its `Sections`, which must outlive the engine; `lifecycle.publishSerialized`
takes no allocator and, since S6-T21, reads `MANIFEST` and `INDEX-STATE.json` for its check
of the caller's number from `std.heap.smp_allocator`, freed before it returns. Encoders (`segment.encode`,
`lexical_segment.encode`, `manifest.encode`) and `postings.build`, `hybrid.search` write
into caller memory and allocate nothing.

**Errors.** Each function's error set is the one Zig infers; the full sets, read from the
compiler, are in [`docs/evidence/s6-t16/error-sets.txt`](evidence/s6-t16/error-sets.txt).
They fall in four kinds:

- `OutOfMemory`;
- the file and directory errors of `std.Io` (`FileNotFound` when a directory holds no
  `MANIFEST`, `AccessDenied`, `NoSpaceLeft`, ...), from the opens, the indexers, the
  importer, `applyChanges` and `publishSerialized`;
- a damaged or foreign index (`BadMagic`, `UnsupportedVersion`, `Truncated`,
  `ChecksumMismatch`, the section size and count mismatches), from every function that
  reads one;
- the core's refusals, named on each function: `WriterBusy` (another writer holds the
  lock), `NoFreeGeneration` (no generation number left; `describeNoFreeGeneration`
  gives the line to print), `StaleGeneration` (a caller's own generation number,
  from `indexFolder`'s `generation` or an import, at or below the highest generation
  the directory has any trace of; `describeStaleGeneration` gives the line, S6-T21),
  `AnalyzerMismatch`, `FilenameSettingMismatch`,
  `IndexTooLarge`, `ApplyRefused`, `DetachedNeedsFreshGeneration`,
  `UnsupportedInterchangeVersion`, the encoders' `BufferTooSmall` and overflows, the
  benchmark's `Invalid...Count` and `InvalidDimensions`, and `hybrid.search`'s
  `WorkspaceTooSmall`, `VectorDimensionMismatch`, `LexicalScoreCountMismatch`.

A refused request that is not an error comes back as a value: `find.Outcome`,
`source.SpanResult`, `source.OutlineResult` and `applyChanges`' outcome are `.ok` or
`.failed` with a `source.Failure` (a `source.Code`, `invalid_argument`, `not_found` or
`capacity`, which maps to the C ABI's `SS_ERR_*`, and a message). The fixed messages
are public so that every surface says the same thing: `find.stale_cursor_message`,
`source.source_absent_message`.

## A new interface, in short

A new interface (here an invented `interfaces/peek.zig`, which prints the answer to one
`find` request) calls operations for the request and the core API for the open. It is
assigned to `interfaces` in `scripts/check_layers.py` and named in
`interfaces/interfaces.zig`, as [layers.md](layers.md) says.

```zig
const std = @import("std");
const core = @import("core").api;
const operations = @import("operations");

/// Print the canonical JSON of one `find` request (a JSON object) over the index in
/// `dir`. `arena` holds everything and is released by the caller.
pub fn peek(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, request: []const u8, out: *std.Io.Writer) !void {
    const opened = try core.snapshot_open.openScoped(arena, io, dir);
    defer core.snapshot_open.close(opened.engine, opened.folder);
    const service = operations.service.Service{ .engine = opened.engine, .folder = opened.folder };
    const params = switch (try operations.ops.parseObject(arena, request)) {
        .ok => |object| object,
        .failed => |failure| return out.print("refused: {s}\n", .{failure.message}),
    };
    switch (try operations.ops.find(arena, service, params, .{})) {
        .ok => |json| try out.writeAll(json),
        .failed => |failure| try out.print("refused: {s}\n", .{failure.message}),
    }
}
```

The interface reaches the answer through `operations.ops.find`, so it answers with the
same bytes as the C ABI, RPC and MCP; it touches the core only to open the generation.
(S6-T16 compiled this example and ran the checker on it in a scratch copy.)

## Adding a name

1. **First ask whether operations should hold it.** An interface that needs a core name
   for a request's work usually needs an operation instead; a name is added to `api`
   when the caller has to hold or pass the thing itself (a handle, an options type, a
   limit it judges before calling).
2. Add it to the namespace of the core file that declares it (or add the namespace,
   named as the file, in the section of its purpose), as
   `pub const NAME = internal.<file>.NAME;`, under its own name.
3. Give it a `///` doc comment: what it does, who owns the memory it returns, and its
   errors. Read the code and the inferred error set; do not guess.
4. Add it to the table above, and run `python3 scripts/check_layers.py` and the Zig
   tests. An alias adds no code, but the change touches the natives' digest inputs,
   so rebuild and restamp them (`bindings/dart/search_simpli/tool/build_native.sh`).

Removing a name is the reverse, once nothing in `ops/` or `interfaces/` uses it.

## Names that look like internals (follow-ups)

The API publishes what was used (ruling 2 of S6-T16), and some of it is the core's work
done outside the core. Each is a follow-up; none is changed here, since that changes
function bodies.

- **Scope statistics in operations.** `scope.visibleCollection`, `scope.View`,
  `scope.documentFrequency` (`ops/service.zig`) compute BM25's visible-scope
  statistics, and `scope.holdsAll`, `hybrid.isAuthorized`, `hybrid.RootMask`,
  `hybrid.matchesPath` filter documents by label, root and path, in operations. They
  belong behind one core call that runs a scoped query.
- **The file-name channel in operations.** `filename_field.tokenize` and
  `filename_field.Hit` (`ops/filename_response.zig`) tokenize the query and rank file
  names outside the core.
- ~~**A query that derives its own title field.** `title_field.derive`
  (`interfaces/cli.zig`, `runSearch`) builds a ranking input in an interface.~~
  Done by [S6-T18](tasks/S6-T18.md): `engine.queryOneShot` derives it in the core, and
  `title_field.derive` left `api`.
- **Writing a generation by hand.** `segment.encode`, `lexical_segment.encode`,
  `postings.build`, `postings.TermEntry`, `postings.Posting`, `manifest.create`,
  `manifest.encode` and `lifecycle.publishSerialized`: the section encoders and the
  publisher, used by `searchd init-demo` (`initDemoSnapshot` in `interfaces/main.zig`) and
  by tests in `interfaces/abi.zig`, `interfaces/rpc.zig` and `ops/service.zig`. Narrowed by
  [S6-T19](tasks/S6-T19.md): `manifest.decode` was used by a test only, which moved to
  `tests/`, and the name left `api`. Every other name here is used by `initDemoSnapshot`,
  so moving the tests would drop none of them; they leave `api` only if the demo uses the
  importer or an operation instead.
- ~~**Generation numbering in interfaces.** `generation_alloc.nextFreeGeneration`
  (`interfaces/abi.zig`, `interfaces/cli.zig`) chooses a generation number before a
  detached build; the indexer could do it.~~ Done by [S6-T20](tasks/S6-T20.md): the
  interfaces pass no number, the core chooses it under the writer lock, and
  `nextFreeGeneration` left `api`.
- **Record paths.** `scope.recordPath`, `scope.relativePath`, `scope.rootOfPath`,
  `scope.isLegacy`, `scope.legacy_root_id` are the record-path convention
  (`root_id/relative`, bare in the legacy root), which every answer carries; they may be
  public by right, but only operations should need them.
- ~~**Test-only names.** `analyzer_v2.analyzer_id` and `manifest.decode` are used only by
  tests beside the code; moving those tests to `tests/` would let them leave `api`.~~
  Done by [S6-T19](tasks/S6-T19.md): the two tests moved to `zig/src/tests/` and both
  names left `api`.

[03-next](journey/03-next.md) carries these as one row.

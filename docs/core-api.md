# The public core API

**State:** written by [S6-T16](tasks/S6-T16.md) (20 Nov 2026, from `main` at `10f3d40`),
step B3 of the [objective plan](plans/2026-11-16-objective-plan.md). It adds names,
aliases and doc comments only: no function body, format, contract or answer changed.

The core is one Zig module, `core` (root `zig/src/core/core.zig`; see
[layers.md](layers.md)). Its root has two parts:

- **`api`, the public core API.** The names an operation or an interface may use, one
  namespace per core file they come from, named as the file (`api.engine`,
  `api.snapshot_open`, ...). Each name is an alias of that file's own declaration
  under its own name, `pub const Engine = internal.engine.Engine;`, so it is the same
  type or function and adds no code. Every namespace and name has a doc comment: what
  it does, who owns the memory it returns, and which errors come back.
- **The rest, every core file by name** (`@import("core").engine`, 51 files). It is
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
(`@import("core").engine`), a namespace `api` lacks, a name its namespace lacks, or the
module used whole. It reads the uses from Zig tokens, inline and through aliases in the
block they are bound in, as its other rules are read. It also checks `api` itself: each
namespace is a core file the root exports, each entry is exactly
`pub const NAME = internal.<file>.NAME;` of a top-level `pub` declaration of that file,
and each carries a `///` doc comment. Zig refuses a name `api` lacks when the code is
compiled; the checker gives the line without a toolchain, and also catches the internal
path, which compiles.

**Cross-layer tests may use internals.** A test in `zig/src/tests/` may name any `pub`
declaration of any core file, through `@import("core").<file>`; the rule does not read
`tests/`. A test beside its subject in `core/` imports by path. The rule binds the tests
inside `ops/` and `interfaces/` (in-file `test` blocks, `field_warnings_test.zig`) like
the code beside them.

A type's fields and methods come with the type: `api.engine.Engine` is the whole
`Engine`, its `queryTraced`, `evidence` and the rest, documented in `engine.zig`.

## The names, by purpose

88 names in 23 namespaces: every core name operations and interfaces used at `10f3d40`
(the measurement, [`docs/evidence/s6-t16/measure.txt`](evidence/s6-t16/measure.txt)),
and nothing else. Their doc comments in `core.zig` say what each does, what it
allocates and what it returns.

| Purpose | Namespace | Names | Count |
|---|---|---|---:|
| Open a generation | `snapshot_open` | `open`, `openDetached`, `openScoped`, `openScopedWith`, `openScopedDetached`, `close`, `Sections` | 7 |
| | `engine` | `Engine`, `Evidence` | 2 |
| Search | `hybrid` | `Document`, `Result`, `RetrievalMode`, `RootMask`, `SearchOptions`, `Trace`, `search`, `isAuthorized`, `matchesPath`, `no_source_doc` | 10 |
| | `scoring` | `isValidVector` | 1 |
| | `filename_field` | `Field`, `Hit`, `tokenize` | 3 |
| | `scope` | `Request`, `Folder`, `View`, `visibleCollection`, `documentFrequency`, `holdsAll`, `recordPath`, `relativePath`, `rootOfPath`, `isLegacy`, `legacy_root_id` | 11 |
| Find | `find` | `Request`, `Mode`, `Outcome`, `find`, `writeFields`, `default_page_size`, `max_page_size`, `stale_cursor_message` | 8 |
| Read a span | `source` | `readSpan`, `SpanResult`, `outline`, `OutlineResult`, `Failure`, `Code`, `writeSpanFields`, `writeOutlineFields`, `max_context_lines`, `source_absent_message` | 10 |
| Apply changes | `apply` | `applyChanges`, `Options`, `writeReportJson`, `default_max_file_bytes`, `default_max_total_bytes` | 5 |
| Build an index | `indexer` | `indexFolder`, `indexFolderIncremental`, `buildFolderDetached`, `Caps`, `IncrementalReport`, `AnalyzerId` | 6 |
| | `chunker` | `default_max_chars`, `default_overlap_lines` | 2 |
| | `generation_alloc` | `nextFreeGeneration`, `describeNoFreeGeneration` | 2 |
| | `title_field` | `derive`, `policy_id` | 2 |
| Write a generation by hand | `importer` | `importJson`, `importJsonKeeping` | 2 |
| | `manifest` | `create`, `encode`, `decode`, `PendingEntry` | 4 |
| | `segment` | `encode` | 1 |
| | `lexical_segment` | `encode` | 1 |
| | `postings` | `build`, `TermEntry`, `Posting` | 3 |
| | `lifecycle` | `publishSerialized` | 1 |
| Benchmark | `benchmark` | `run`, `max_documents`, `max_dimensions`, `max_queries` | 4 |
| The formats' identities | `analyzer_v2` | `analyzer_id` | 1 |
| | `fold` | `policy_id` | 1 |
| | `fuzzy` | `policy_id` | 1 |

By purpose: open 9, search 25, find 8, read a span 10, apply 5, build an index 12, write a
generation by hand 12, benchmark 4, the formats' identities 3 (a fourth,
`title_field.policy_id`, sits with its file under build an index).

`analyzer_v2.analyzer_id` and `manifest.decode` are used only in test blocks of
`ops/filename_response.zig` and `interfaces/abi.zig`; they are public because those tests
sit beside the code and the rule binds them too.

## Memory and errors

**Memory.** Every function that allocates takes the allocator it allocates from, and
what it returns lives there. The callers give an arena (one per command, request or
handle) and release it whole; the doc comment says so where a function relies on it
(`applyChanges`, the indexers, `find`). Exceptions, each documented: a scoped open
(`openScoped`, `openScopedWith`, `openScopedDetached`) keeps open files and, with
`openScopedWith`, exact blocks outside the arena, released by `snapshot_open.close`
before the arena goes; `title_field.derive` returns one block to free with
`Derived.deinit`; `scope.View`'s group flags are freed with `View.deinit`; a detached
open borrows its `Sections`, which must outlive the engine. Encoders (`segment.encode`,
`lexical_segment.encode`, `manifest.encode`) and `postings.build`, `hybrid.search` write
into caller memory and allocate nothing.

**Errors.** Each function's error set is the one Zig infers; the full sets, read from the
compiler, are in [`docs/evidence/s6-t16/error-sets.txt`](evidence/s6-t16/error-sets.txt).
They fall in four kinds:

- `OutOfMemory`;
- the file and directory errors of `std.Io` (`FileNotFound` when a directory holds no
  `MANIFEST`, `AccessDenied`, `NoSpaceLeft`, ...), from the opens, the indexers, the
  importer, `applyChanges`, `nextFreeGeneration` and `publishSerialized`;
- a damaged or foreign index (`BadMagic`, `UnsupportedVersion`, `Truncated`,
  `ChecksumMismatch`, the section size and count mismatches), from every function that
  reads one;
- the core's refusals, named on each function: `WriterBusy` (another writer holds the
  lock), `NoFreeGeneration` (no generation number left; `describeNoFreeGeneration`
  gives the line to print), `AnalyzerMismatch`, `FilenameSettingMismatch`,
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
- **A query that derives its own title field.** `title_field.derive`
  (`interfaces/cli.zig`, `runSearch`) builds a ranking input in an interface.
- **Writing a generation by hand.** `segment.encode`, `lexical_segment.encode`,
  `postings.build`, `postings.TermEntry`, `postings.Posting`, `manifest.create`,
  `manifest.encode`, `manifest.decode` and `lifecycle.publishSerialized`: the section
  encoders and the publisher, used by `searchd init-demo` (`interfaces/main.zig`) and by
  tests in `interfaces/abi.zig`, `interfaces/rpc.zig` and `ops/service.zig`. The demo
  could use the importer or an operation, and the tests could move to `tests/`.
- **Generation numbering in interfaces.** `generation_alloc.nextFreeGeneration`
  (`interfaces/abi.zig`, `interfaces/cli.zig`) chooses a generation number before a
  detached build; the indexer could do it.
- **Record paths.** `scope.recordPath`, `scope.relativePath`, `scope.rootOfPath`,
  `scope.isLegacy`, `scope.legacy_root_id` are the record-path convention
  (`root_id/relative`, bare in the legacy root), which every answer carries; they may be
  public by right, but only operations should need them.
- **Test-only names.** `analyzer_v2.analyzer_id` and `manifest.decode` are used only by
  tests beside the code; moving those tests to `tests/` would let them leave `api`.

[03-next](journey/03-next.md) carries these as one row.

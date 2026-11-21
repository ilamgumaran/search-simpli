//! The core layer as one module, `core` (S6-T14; docs/layers.md). zig/build.zig
//! builds zig/src/core/ as this module. It has two parts (S6-T16; docs/core-api.md):
//!
//! - `api`, the public core API: the names an operation or an interface may use,
//!   one namespace per core file they come from, laid out by purpose. Operations
//!   and interfaces import `@import("core").api.<file>` (or `@import("core").api`)
//!   and nothing else of the core; `scripts/check_layers.py` fails on any other
//!   core name in zig/src/ops/ or zig/src/interfaces/. Each name is the core file's
//!   own declaration under its own name, an alias, so it adds no code.
//! - the rest, below `api`: every core file by name, which is internal. The core's
//!   own files and tests reach each other by path inside core/; the tests in
//!   zig/src/tests/ reach a core file as `@import("core").<file name>` and may use
//!   any of its `pub` names. Every core file but fastmem.zig (an object of its own
//!   in zig/build.zig) and the core tests that another folder names.

/// The public core API (S6-T16, docs/core-api.md): every core name operations
/// and interfaces use, by the core file it comes from. A type's fields and
/// methods come with it, documented in its file. Errors are each function's
/// error set as the compiler infers it, summarised: `OutOfMemory`; the file
/// and directory errors of `std.Io` (`FileNotFound`, `AccessDenied`, `NoSpaceLeft`,
/// ...); and the core's own, a damaged or foreign index (`BadMagic`,
/// `UnsupportedVersion`, `Truncated`, `ChecksumMismatch` and the section size and
/// count mismatches) or a refusal named where it is listed. A refused request
/// that is not an error is a `.failed` value (`source.Failure`).
pub const api = struct {
    // ---------------------------------------------------------- open a generation

    /// Opening the current published generation of an index directory, or one
    /// built in memory, for queries (`snapshot_open.zig`).
    pub const snapshot_open = struct {
        /// Open the current generation of `dir` eagerly, for a one-shot command:
        /// the manifest and the documents and lexical sections are read, checked
        /// and decoded, and so are the two filename sections when the manifest
        /// names them. The source section is not read (a lost or damaged one does
        /// not fail the open). The `Engine` and everything it points to are
        /// allocated from `allocator` (an arena, discarded wholesale; there is no
        /// close).
        /// Errors: `OutOfMemory`, `std.Io` file errors (`FileNotFound` when `dir`
        /// holds no `MANIFEST`), and the core's format errors.
        pub const open = internal.snapshot_open.open;
        /// `open` over `Sections` in memory: the same checks and decode of the same
        /// sections (`Sections.source` is not read), nothing read from disk. The
        /// engine points into `sections`, which must outlive it; the rest is
        /// allocated from `allocator`. Errors: as `open`.
        pub const openDetached = internal.snapshot_open.openDetached;
        /// Open the current generation of `dir` for scoped operations: the engine
        /// and its `scope.Folder` (roots, pending files, chunkers), returned as
        /// `Scoped`. A lazy open: the manifest and the document and lexical
        /// sections are checked and decoded now; the source section, the filename
        /// sections, the statistics and the position tables at their first use.
        /// Everything is allocated from `allocator`; the source and filename
        /// sections' files are opened now and stay open until `close` (or
        /// `folder.close()`). Errors: `OutOfMemory`,
        /// `std.Io` file errors (`FileNotFound` without a `MANIFEST`), and the
        /// core's format errors.
        pub const openScoped = internal.snapshot_open.openScoped;
        /// `openScoped` with two allocators (`snapshot_open.Allocators`): the exact
        /// blocks the handle keeps (the open's, later the source and filename
        /// sections') from `.blocks`, the rest from `.arena`. The owner calls
        /// `close` before it releases the arena. Errors: as `openScoped`.
        pub const openScopedWith = internal.snapshot_open.openScopedWith;
        /// `openScoped` over `Sections` in memory (`searchd search`): the same
        /// checks, decode and scope data; the source and filename sections are
        /// decoded from their bytes at first use. The engine points into
        /// `sections`, which must outlive it; the rest is from `allocator`.
        /// Errors: as `openScoped`.
        pub const openScopedDetached = internal.snapshot_open.openScopedDetached;
        /// Release what a scoped open keeps outside its arena: the folder's open
        /// files and the exact blocks, through the allocator the open was given.
        /// Nothing of the opened generation may be used afterwards; the arena is
        /// still the owner's to release. No errors.
        pub const close = internal.snapshot_open.close;
        /// A generation's encoded sections held in memory, never published (the
        /// manifest, documents and lexical sections, and the optional source and
        /// filename sections). Borrowed, not copied: the caller owns the bytes and
        /// keeps them for as long as an engine opened from them is used.
        pub const Sections = internal.snapshot_open.Sections;
    };

    /// The opened generation and its one-shot query (`engine.zig`).
    pub const engine = struct {
        /// An opened generation: its documents, lexical index, roots and manifest
        /// fields, with the query methods operations call (among them
        /// `queryTraced`, `queryTokenized`, `queryFields`, `queryFieldsTraced`,
        /// `evidence`, `validateQueryText`, `titleApplies`, `foldApplies` and
        /// `fuzzyApplies`; their errors and
        /// allocations are documented in engine.zig). Made by an open; it points
        /// into what that open allocated and is valid until the open's memory is
        /// released (and `snapshot_open.close`, for a scoped open).
        pub const Engine = internal.engine.Engine;
        /// One result with its cited chunk (`Engine.evidence`): chunk id, path,
        /// lines, the chunk's text, and the scores and ranks. Its slices point into the
        /// engine's documents, so it is valid as long as the engine is.
        pub const Evidence = internal.engine.Evidence;
        /// A one-shot lexical query (S6-T18): the best `top_k` chunks for the
        /// query text, ranked with the title field, as `searchd query` answers
        /// under `content`. An engine from a scoped open ranks with the title
        /// field its folder holds (`scope.Folder.titleField`): derived and kept
        /// by the folder as for any other query, on its first use (this call's,
        /// if no query came before), in the scoped open's memory, not from
        /// `allocator`. Any other engine's field is derived for this query from
        /// `allocator`. What the call allocates comes from `allocator` (an arena:
        /// a buffer of one result per chunk and a derived field are not freed
        /// separately); the results point into that buffer and the engine's
        /// documents.
        /// Errors: `OutOfMemory`, `InvalidQueryText`, `InvalidUtf8`,
        /// `IndexTooLarge`, `WorkspaceTooSmall`, `VectorDimensionMismatch`,
        /// `LexicalScoreCountMismatch` (as `Engine.queryTokenized`).
        pub const queryOneShot = internal.engine.queryOneShot;
    };

    // ------------------------------------------------------------------- search

    /// Documents, search options, results and the lexical-and-vector fusion
    /// (`hybrid.zig`).
    pub const hybrid = struct {
        /// A chunk as the documents section holds it: id, text, vector, path,
        /// lines, required labels, chunker, section data and source document. Plain data; its
        /// slices are borrowed from whoever made it (an open's memory, or the
        /// caller's own records).
        pub const Document = internal.hybrid.Document;
        /// One ranked chunk: its index and id, path and lines, the lexical,
        /// semantic and fused scores and ranks. Its slices point into the
        /// documents it was ranked from.
        pub const Result = internal.hybrid.Result;
        /// Which retrieval a query runs: `lexical`, `vector` or `hybrid`.
        pub const RetrievalMode = internal.hybrid.RetrievalMode;
        /// Which roots a request may see: each document's root ordinal and
        /// whether each root is allowed. Borrows both slices from its maker
        /// (`scope.Folder`).
        pub const RootMask = internal.hybrid.RootMask;
        /// How a query ranks and what it may see: `top_k`, `candidate_k`, the
        /// fusion and BM25 parameters, the retrieval mode, the path prefix, the
        /// trusted caller's labels and roots, the title field and its weight, and
        /// the fuzzy (with its groups) and fold switches. Plain data; every pointer in it is borrowed.
        pub const SearchOptions = internal.hybrid.SearchOptions;
        /// What a traced query reports about itself (among others the unmatched,
        /// expanded and grouped words, the matched chunks and candidate counts,
        /// and the stage times when `profile` is set).
        /// Its lists grow in the `allocator` the caller puts in it and are the
        /// caller's to release (an arena in every caller).
        pub const Trace = internal.hybrid.Trace;
        /// Exhaustive hybrid ranking of `documents` for one query, the simple
        /// reference ranking (`searchd demo` runs it). Allocation-free:
        /// results are written into the caller's `workspace` (at least one slot
        /// per document) and the returned slice is part of it. Errors:
        /// `WorkspaceTooSmall`, `VectorDimensionMismatch`,
        /// `LexicalScoreCountMismatch`.
        pub const search = internal.hybrid.search;
        /// Whether `principal_labels` holds every label of `required_labels` (a
        /// document's canonical newline-separated label field; empty requires
        /// none). Allocates nothing; no errors.
        pub const isAuthorized = internal.hybrid.isAuthorized;
        /// Whether `path` starts with `prefix` (true when `prefix` is null).
        /// Allocates nothing; no errors.
        pub const matchesPath = internal.hybrid.matchesPath;
        /// A document's `source_doc_index` when the generation keeps no source
        /// bytes for its file (`maxInt(u32)`).
        pub const no_source_doc = internal.hybrid.no_source_doc;
    };

    /// Vector checks of the ranking (`scoring.zig`).
    pub const scoring = struct {
        /// Whether a query or document vector is valid: every component finite
        /// and the `f32` sum of their squares finite (an all-zero vector is valid).
        /// Allocates nothing; no errors.
        pub const isValidVector = internal.scoring.isValidVector;
    };

    /// The file-name channel of a search (`filename_field.zig`).
    pub const filename_field = struct {
        /// Which field a search ranks: `content`, `filename` or `both`.
        pub const Field = internal.filename_field.Field;
        /// One file-name or `both` result: the document's index with its body,
        /// filename and fused scores and ranks. Plain values.
        pub const Hit = internal.filename_field.Hit;
        /// The terms of `text` under the analyzer named `analyzer_id`
        /// (`analyzer-v2`, else the ASCII analyzer, lowercased). The slice and
        /// each term are allocated from `allocator` (an arena, or free each term
        /// and then the slice). Errors: `OutOfMemory`, `InvalidUtf8`.
        pub const tokenize = internal.filename_field.tokenize;
    };

    /// Roots, a request's scope and the visible-scope statistics (`scope.zig`).
    pub const scope = struct {
        /// A request's scope as the trusted caller states it: the root ids to
        /// search (null: every root) and the caller's labels. Borrowed slices.
        pub const Request = internal.scope.Request;
        /// A scoped open's generation data beside the engine: roots, pending,
        /// unchunked and skipped files, chunkers, document roots, and the lazy
        /// loads (source section, statistics, positions). Made by
        /// `snapshot_open.openScoped` in its allocator; released with
        /// `snapshot_open.close`.
        pub const Folder = internal.scope.Folder;
        /// What BM25 divides by for one request when its scope hides a document.
        /// Its `visible_groups` belong to the allocator given to
        /// `visibleCollection` (free with `View.deinit`, or with the arena).
        pub const View = internal.scope.View;
        /// The visible scope's collection statistics for a request (its root
        /// mask and labels), or null when every document is visible. The view's
        /// group flags are allocated from `allocator`. Errors: `OutOfMemory`.
        pub const visibleCollection = internal.scope.visibleCollection;
        /// A term's document frequency within a view's scope. Allocates
        /// nothing; no errors.
        pub const documentFrequency = internal.scope.documentFrequency;
        /// Whether `principal_labels` holds every label in `required`. Allocates
        /// nothing; no errors.
        pub const holdsAll = internal.scope.holdsAll;
        /// The record path of `relative` in root `root_id` (`root_id/relative`,
        /// or `relative` itself in the legacy root), allocated from `allocator`.
        /// Errors: `OutOfMemory`.
        pub const recordPath = internal.scope.recordPath;
        /// The root-relative part of a record path of `root`: a slice of `path`.
        /// Allocates nothing; no errors.
        pub const relativePath = internal.scope.relativePath;
        /// The ordinal in `roots` of the root a record path belongs to (the
        /// legacy root when no other matches), or null. No errors.
        pub const rootOfPath = internal.scope.rootOfPath;
        /// Whether `root_id` is the legacy folder root. No errors.
        pub const isLegacy = internal.scope.isLegacy;
        /// The legacy folder root's id, `r-legacy`: the one root of a generation
        /// written before roots, whose record paths carry no root prefix.
        pub const legacy_root_id = internal.scope.legacy_root_id;
    };

    // --------------------------------------------------------------------- find

    /// `find`: exact words, phrases and prefixes over one generation (`find.zig`).
    pub const find = struct {
        /// A `find` request: the query, mode, path prefix, trusted labels, page
        /// size and cursor, and the scoped caller's roots, statistics and
        /// pending counts. Borrowed slices.
        pub const Request = internal.find.Request;
        /// `words`, `phrase` or `prefix`; `Mode.parse` reads the name.
        pub const Mode = internal.find.Mode;
        /// What `find` answers: `.ok` with the page of hits, or `.failed` with a
        /// `source.Failure` (invalid argument or capacity, with its message).
        pub const Outcome = internal.find.Outcome;
        /// Run a `find` request over `engine`, every match scored and the page
        /// cut by the cursor. The answer, its hits and snippets and any failure
        /// message are allocated from `allocator` (an arena in every caller);
        /// hits also point into the engine's documents. A refused request is
        /// `.failed`, not an error. Errors (`find.Error`): `OutOfMemory`,
        /// `InvalidUtf8`, `OffsetsPastText`.
        pub const find = internal.find.find;
        /// Write an answer's fields after the request echo and the generation
        /// (`hits` through `pending_files`) to `json`, for a caller that writes
        /// its own envelope. Allocates nothing itself. Errors: `WriteFailed`.
        pub const writeFields = internal.find.writeFields;
        /// The page size when a request gives none: 20.
        pub const default_page_size = internal.find.default_page_size;
        /// The largest page size a request may ask for: 100.
        pub const max_page_size = internal.find.max_page_size;
        /// The message of a cursor from another generation: "stale cursor".
        pub const stale_cursor_message = internal.find.stale_cursor_message;
    };

    // ---------------------------------------------------------------- read a span

    /// Reads of a file's retained bytes: `read_span` and `outline` (`source.zig`).
    pub const source = struct {
        /// `read_span`: lines `start_line..end_line` of `path` plus up to
        /// `context_lines` on each side, byte for byte. `.failed` (not an error)
        /// for a bad range, an unknown path, more than 400 lines or 256 KiB
        /// with the context, or no source section. `allocator` holds the messages and, for a streamed
        /// section, the file's bytes, which the span's slices point into.
        /// Errors: `OutOfMemory`.
        pub const readSpan = internal.source.readSpan;
        /// What `readSpan` answers: `.ok` with the span, or `.failed`.
        pub const SpanResult = internal.source.SpanResult;
        /// `outline`: a file's line count and chunker, and for Markdown its
        /// headings and front matter. `.failed` for an unknown path or no source
        /// section. Allocated from `allocator`. Errors: `OutOfMemory`,
        /// `InvalidUtf8`.
        pub const outline = internal.source.outline;
        /// What `outline` answers: `.ok` with the outline, or `.failed`.
        pub const OutlineResult = internal.source.OutlineResult;
        /// A refusal: its `Code` and message (the message is static or in the
        /// allocator of the call that refused).
        pub const Failure = internal.source.Failure;
        /// A refusal's kind: `invalid_argument`, `not_found` or `capacity`, with
        /// the C ABI's `SS_ERR_*` value and name (`ssError`, `ssName`).
        pub const Code = internal.source.Code;
        /// Write a span's fields, without the braces, to `json`. Allocates
        /// nothing itself. Errors: `WriteFailed`.
        pub const writeSpanFields = internal.source.writeSpanFields;
        /// Write an outline's fields, without the braces, to `json`. Allocates
        /// nothing itself. Errors: `WriteFailed`.
        pub const writeOutlineFields = internal.source.writeOutlineFields;
        /// The most context lines a span may ask for on each side: 20.
        pub const max_context_lines = internal.source.max_context_lines;
        /// The message of a read from a generation with no source section:
        /// "re-index required: source absent".
        pub const source_absent_message = internal.source.source_absent_message;
    };

    // ------------------------------------------------------------- apply changes

    /// `apply_changes`: host-fed changes published as the next generation
    /// (`apply.zig`).
    pub const apply = struct {
        /// Parse an `apply_changes` request (JSON) and apply it to the index
        /// directory `dir`, publishing exactly one new generation. A refused
        /// request (malformed, stale `expect_generation`, over capacity) is
        /// `.failed` and changes nothing; per-change outcomes are in the report.
        /// `allocator` should be an arena: the report lives in it. Errors:
        /// `OutOfMemory`, `std.Io` file errors, the core's format errors, and its
        /// refusals of the directory (`WriterBusy`, `NoFreeGeneration`,
        /// `AnalyzerMismatch`, `FilenameSettingMismatch`, `IndexTooLarge`, ...).
        pub const applyChanges = internal.apply.applyChanges;
        /// The options of an apply: filename index, write roots and labels,
        /// analyzer, chunking, size caps, file reads, retention and the walk's
        /// settings. Plain data with defaults.
        pub const Options = internal.apply.Options;
        /// Write an apply report as JSON (paths as `{root_id, path}`) to `json`.
        /// Allocates nothing itself. Errors: `WriteFailed`.
        pub const writeReportJson = internal.apply.writeReportJson;
        /// The default largest file one apply reads (`Options.max_file_bytes`): 10 MiB.
        pub const default_max_file_bytes = internal.apply.default_max_file_bytes;
        /// The default most content one apply reads (`Options.max_total_bytes`): 512 MiB.
        pub const default_max_total_bytes = internal.apply.default_max_total_bytes;
    };

    // ------------------------------------------------------------ build an index

    /// Native folder indexing: walk, read, chunk, publish (`indexer.zig`).
    pub const indexer = struct {
        /// Walk `root`, chunk and tokenize every matching file, and publish a
        /// fresh generation (a full rebuild) into `out_dir`. `allocator` should
        /// be an arena: the report lives in it. Errors: `OutOfMemory`, `std.Io`
        /// file errors, the core's format errors, `ApplyRefused`, and the
        /// directory's refusals (`WriterBusy`, `NoFreeGeneration`,
        /// `IndexTooLarge`, `FilenameSettingMismatch`, `AnalyzerMismatch`, ...).
        pub const indexFolder = internal.indexer.indexFolder;
        /// Re-walk `root` and apply the walk as one batch over the current
        /// generation of `out_dir` (unchanged files keep their chunks), then
        /// publish the next generation and its state. `allocator` should be an
        /// arena. Errors: as `indexFolder`; here `AnalyzerMismatch` is a current
        /// generation made with another analyzer (it fails closed).
        pub const indexFolderIncremental = internal.indexer.indexFolderIncremental;
        /// The generation `indexFolder` would publish for `root` into an empty
        /// directory, built in memory and written nowhere (`searchd search`). The
        /// sections and the report live in `allocator` (an arena). Errors: as
        /// `indexFolder` (the same inferred set), and `DetachedNeedsFreshGeneration`.
        pub const buildFolderDetached = internal.indexer.buildFolderDetached;
        /// The caps of one indexing run: filename index, retention, largest file,
        /// most bytes, source retention. Plain data with defaults.
        pub const Caps = internal.indexer.Caps;
        /// What an indexing run reports: generation, analyzer, counts and the
        /// paths left out. Its slices are in the run's allocator.
        pub const IncrementalReport = internal.indexer.IncrementalReport;
        /// `v1` or `v2`; `AnalyzerId.parse` reads `analyzer-v1`/`v1` and
        /// `analyzer-v2`/`v2`, `label` gives the id.
        pub const AnalyzerId = internal.indexer.AnalyzerId;
    };

    /// The chunker's defaults (`chunker.zig`).
    pub const chunker = struct {
        /// The default most characters in a chunk: 1,600.
        pub const default_max_chars = internal.chunker.default_max_chars;
        /// The default lines two neighbouring chunks share: 3.
        pub const default_overlap_lines = internal.chunker.default_overlap_lines;
    };

    /// The next free generation number of a directory (`generation_alloc.zig`).
    pub const generation_alloc = struct {
        /// The smallest generation number above every one `dir` has a trace of
        /// whose six section names are all free: `documents-N.hybseg`,
        /// `lexical-N.hyblex`, `source-N.hybsrc`, `filenames-N.hybseg`,
        /// `filename-lexical-N.hyblex` and `state-N.hybstate`.
        /// `allocator` is for transient reads
        /// only (an arena is fine). Errors: `OutOfMemory`, `std.Io` file errors,
        /// the core's format errors, and `NoFreeGeneration` at `u64` max or after
        /// a million taken numbers.
        pub const nextFreeGeneration = internal.generation_alloc.nextFreeGeneration;
        /// One line for this thread's last `error.NoFreeGeneration` (the highest
        /// generation and the file names in the way), formatted into `buffer`;
        /// the result is a slice of `buffer`, or a static fallback when it does
        /// not fit. No errors.
        pub const describeNoFreeGeneration = internal.generation_alloc.describeNoFreeGeneration;
    };

    /// The title field: folder and file names as a title (`title_field.zig`).
    pub const title_field = struct {
        /// The title field's policy id: "title-field-v1".
        pub const policy_id = internal.title_field.policy_id;
    };

    // ------------------------------------------- write a generation by hand

    /// Importing an interchange snapshot written by the Python reference
    /// (`importer.zig`).
    pub const importer = struct {
        /// Parse an interchange snapshot (JSON) and publish it as the next
        /// generation of `dir`, keeping the payload's `keep_generations`.
        /// `allocator` gives the call's working memory, which it frees before it
        /// returns (the report holds no slices). Errors: `OutOfMemory`, `std.Io`
        /// file errors, the JSON parser's, the core's format errors,
        /// `UnsupportedInterchangeVersion`, `UnsupportedFilenamePolicy` and
        /// `WriterBusy`, among others.
        pub const importJson = internal.importer.importJson;
        /// `importJson` with an explicit `keep_generations` that overrides the
        /// payload's own. Errors: as `importJson`.
        pub const importJsonKeeping = internal.importer.importJsonKeeping;
    };

    /// The generation manifest (`manifest.zig`).
    pub const manifest = struct {
        /// A version 1 manifest for two encoded sections (documents, lexical):
        /// their counts and checksums, read from the bytes and checked. The
        /// returned value borrows the names given. Errors (`ManifestError`): the
        /// core's checks of the fields and sections.
        pub const create = internal.manifest.create;
        /// Encode a manifest into the caller's `output`; the result is a slice of
        /// it. Errors (`ManifestError`): `BufferTooSmall` and the field checks.
        pub const encode = internal.manifest.encode;
        /// Decode and check an encoded manifest. The value borrows `encoded`.
        /// Errors (`ManifestError`): the core's format errors.
        pub const decode = internal.manifest.decode;
        /// A file the host named whose bytes have not arrived, or one left
        /// out: root id, path, size, labels and reason. Borrowed slices.
        pub const PendingEntry = internal.manifest.PendingEntry;
    };

    /// The documents section format (`segment.zig`).
    pub const segment = struct {
        /// Encode `documents` as one documents section (record v3) into the
        /// caller's `output`; the result is a slice of it. Errors: `BufferTooSmall`,
        /// `FieldTooLarge`, `SizeOverflow`, `DocumentCountOverflow`,
        /// `VectorDimensionsInconsistent`, `InvalidCitation`,
        /// `InvalidRequiredLabels`, `InvalidSection`, `RequiresVersion4`.
        pub const encode = internal.segment.encode;
    };

    /// The lexical section format (`lexical_segment.zig`).
    pub const lexical_segment = struct {
        /// Encode a postings index as a lexical section (`HYBLEX01`, or `HYBLEX02`
        /// when it carries positions) into the caller's `output` (validated
        /// first; nothing is written if it is invalid); the
        /// result is a slice of it. Errors (`EncodeError`, which also names
        /// `OutOfMemory`): `BufferTooSmall`, the size and count overflows and the
        /// index checks (`InvalidTerm`, `DuplicateTerm`, `UnsortedTerms`, ...).
        pub const encode = internal.lexical_segment.encode;
    };

    /// The inverted index (`postings.zig`).
    pub const postings = struct {
        /// Build an inverted index of `documents` into the caller's arrays (terms,
        /// postings, document lengths, fill counters). Allocation-free: the index
        /// points into those arrays and its terms into the documents' text.
        /// Errors (`BuildError`): `DocumentCountOverflow`, `DocumentLengthOverflow`,
        /// `PostingCountOverflow` and the `...CapacityTooSmall` of each array.
        pub const build = internal.postings.build;
        /// One term of the dictionary: its text, document frequency and range of
        /// postings.
        pub const TermEntry = internal.postings.TermEntry;
        /// One posting: a document index and the term's frequency in it.
        pub const Posting = internal.postings.Posting;
    };

    /// The writer lock and publication (`lifecycle.zig`).
    pub const lifecycle = struct {
        /// Publish two encoded sections (documents and lexical) and their manifest
        /// as the current generation of `dir`, under the directory's writer lock. Allocates
        /// nothing. Errors: `WriterBusy` when another writer holds the lock,
        /// `std.Io` file errors, and the core's checks of the manifest.
        pub const publishSerialized = internal.lifecycle.publishSerialized;
    };

    /// The synthetic ranking benchmark behind `searchd benchmark` (`benchmark.zig`).
    pub const benchmark = struct {
        /// Rank `query_count` queries over `document_count` synthetic documents
        /// of `dimensions` and print the timings to standard error. Frees all it
        /// allocates from `allocator`. Errors: `OutOfMemory`,
        /// `InvalidDocumentCount`, `InvalidDimensions`, `InvalidQueryCount`, and
        /// the search and index capacity errors.
        pub const run = internal.benchmark.run;
        /// The most documents `run` takes: 100,000.
        pub const max_documents = internal.benchmark.max_documents;
        /// The most vector dimensions `run` takes: 4,096.
        pub const max_dimensions = internal.benchmark.max_dimensions;
        /// The most queries `run` takes: 10,000.
        pub const max_queries = internal.benchmark.max_queries;
    };

    // ------------------------------------------------------ the formats' identities

    /// The Unicode analyzer (`analyzer_v2.zig`).
    pub const analyzer_v2 = struct {
        /// Its id, as a manifest and a report name it: "analyzer-v2".
        pub const analyzer_id = internal.analyzer_v2.analyzer_id;
    };

    /// The word-form groups (`fold.zig`).
    pub const fold = struct {
        /// The query side's fold policy id: "fold-groups-v3".
        pub const policy_id = internal.fold.policy_id;
    };

    /// Misspelling tolerance at query time (`fuzzy.zig`).
    pub const fuzzy = struct {
        /// The fuzzy policy id: "fuzzy-v1".
        pub const policy_id = internal.fuzzy.policy_id;
    };
};

/// This root, through which `api` names each core file (`internal.engine`):
/// inside `api`, `engine` alone would be its own namespace.
const internal = @This();

// The internal part: every core file by name (the module's tests, and the tests in
// zig/src/tests/, reach them here).
pub const analysis = @import("analysis.zig");
pub const analyzer_v2 = @import("analyzer_v2.zig");
pub const apply = @import("apply.zig");
pub const benchmark = @import("benchmark.zig");
pub const bm25_conformance_test = @import("bm25_conformance_test.zig");
pub const both_view_test = @import("both_view_test.zig");
pub const checksum = @import("checksum.zig");
pub const chunker = @import("chunker.zig");
pub const chunker_md = @import("chunker_md.zig");
pub const chunker_md_test = @import("chunker_md_test.zig");
pub const chunker_test = @import("chunker_test.zig");
pub const engine = @import("engine.zig");
pub const filename_complexity_test = @import("filename_complexity_test.zig");
pub const filename_field = @import("filename_field.zig");
pub const filename_field_test = @import("filename_field_test.zig");
pub const find = @import("find.zig");
pub const find_fixture_test = @import("find_fixture_test.zig");
pub const fold = @import("fold.zig");
pub const fold_test = @import("fold_test.zig");
pub const fuzzy = @import("fuzzy.zig");
pub const generation_alloc = @import("generation_alloc.zig");
pub const hybrid = @import("hybrid.zig");
pub const import_analyzer_test = @import("import_analyzer_test.zig");
pub const import_build_timing_test = @import("import_build_timing_test.zig");
pub const importer = @import("importer.zig");
pub const incremental_indexing_test = @import("incremental_indexing_test.zig");
pub const incremental_state = @import("incremental_state.zig");
pub const indexer = @import("indexer.zig");
pub const lexical_build = @import("lexical_build.zig");
pub const lexical_segment = @import("lexical_segment.zig");
pub const lifecycle = @import("lifecycle.zig");
pub const manifest = @import("manifest.zig");
pub const manifest_inplace_test = @import("manifest_inplace_test.zig");
pub const manifest_read_test = @import("manifest_read_test.zig");
pub const nfc = @import("nfc.zig");
pub const nfc_timing_test = @import("nfc_timing_test.zig");
pub const postings = @import("postings.zig");
pub const publication = @import("publication.zig");
pub const query_one_shot_test = @import("query_one_shot_test.zig");
pub const scope = @import("scope.zig");
pub const scoring = @import("scoring.zig");
pub const segment = @import("segment.zig");
pub const segment_v5 = @import("segment_v5.zig");
pub const snapshot_open = @import("snapshot_open.zig");
pub const source = @import("source.zig");
pub const source_v2 = @import("source_v2.zig");
pub const state_section = @import("state_section.zig");
pub const title_field = @import("title_field.zig");
pub const unicode_tables = @import("unicode_tables.zig");
pub const verb_form_groups_test = @import("verb_form_groups_test.zig");
pub const verb_forms = @import("verb_forms.zig");
pub const verb_forms_test = @import("verb_forms_test.zig");

// `zig build test` runs this module's tests in a step of their own (zig/build.zig):
// a test build only collects the tests of its root module's files. The reference
// below is made in a test build only, and adds no test of its own.
comptime {
    if (@import("builtin").is_test) {
        _ = analysis;
        _ = analyzer_v2;
        _ = apply;
        _ = benchmark;
        _ = bm25_conformance_test;
        _ = both_view_test;
        _ = checksum;
        _ = chunker;
        _ = chunker_md;
        _ = chunker_md_test;
        _ = chunker_test;
        _ = engine;
        _ = filename_complexity_test;
        _ = filename_field;
        _ = filename_field_test;
        _ = find;
        _ = find_fixture_test;
        _ = fold;
        _ = fold_test;
        _ = fuzzy;
        _ = generation_alloc;
        _ = hybrid;
        _ = import_analyzer_test;
        _ = import_build_timing_test;
        _ = importer;
        _ = incremental_indexing_test;
        _ = incremental_state;
        _ = indexer;
        _ = lexical_build;
        _ = lexical_segment;
        _ = lifecycle;
        _ = manifest;
        _ = manifest_inplace_test;
        _ = manifest_read_test;
        _ = nfc;
        _ = nfc_timing_test;
        _ = postings;
        _ = publication;
        _ = query_one_shot_test;
        _ = scope;
        _ = scoring;
        _ = segment;
        _ = segment_v5;
        _ = snapshot_open;
        _ = source;
        _ = source_v2;
        _ = state_section;
        _ = title_field;
        _ = unicode_tables;
        _ = verb_form_groups_test;
        _ = verb_forms;
        _ = verb_forms_test;
    }
}

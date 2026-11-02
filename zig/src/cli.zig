//! `searchd index|query|evidence` (S1-T1 acceptance criterion 3): native,
//! Python-free folder indexing and querying on top of `indexer.zig`,
//! `chunker.zig`, and the existing segment/manifest/engine machinery.
//!
//! Query-time analyzer awareness: a plain `Engine.query` call always
//! tokenizes the query text with the ASCII `analysis.zig` scanner, which is
//! correct for an `analyzer-v1` (or legacy `ascii-alnum-v1`) index but wrong
//! for an `analyzer-v2` (Unicode) index -- an ASCII scanner cannot see
//! Tamil, or accented Latin, in the query text at all. `Engine.queryTokenized`
//! (in `engine.zig`) checks `analyzer_id` and dispatches to
//! `analyzer_v2.tokenize` + `lexical_build.scoreQuery` for `analyzer-v2`
//! snapshots; `runQuery`/`runEvidence` below use it, and so does
//! `Service.searchKnowledge` (`service.zig`) -- which means `searchd serve`,
//! stdio and `--http` alike, is analyzer-aware too, not just this CLI path.
const filename_field = @import("filename_field.zig");
const filename_response = @import("filename_response.zig");
const std = @import("std");
const benchmark = @import("benchmark.zig");
const chunker = @import("chunker.zig");
const engine_module = @import("engine.zig");
const generation_alloc = @import("generation_alloc.zig");
const hybrid = @import("hybrid.zig");
const indexer = @import("indexer.zig");
const snapshot_open = @import("snapshot_open.zig");
const find_module = @import("find.zig");
const ops = @import("ops.zig");
const service_module = @import("service.zig");
const source = @import("source.zig");

pub const IndexOptions = struct {
    analyzer: indexer.AnalyzerId = .v2,
    max_chars: usize = chunker.default_max_chars,
    overlap_lines: usize = chunker.default_overlap_lines,
    /// `null` means "pick the next generation not already used in `--out`"
    /// (S1-T3 criterion 5: re-running `index` into an existing directory
    /// re-publishes instead of failing with `PathAlreadyExists`). An
    /// explicit value is used as-is, including a deliberate collision.
    generation: ?u64 = null,
    /// S1-T3 criterion 1: `searchd index --update` runs incremental
    /// indexing (`indexer.indexFolderIncremental`) instead of a full
    /// rebuild -- content hashes, unchanged files skipped, deleted files
    /// tombstoned, same atomic publication path.
    update: bool = false,
    caps: indexer.Caps = .{},
};

/// S1-T8 criterion 3: the usage text. `--help`/`-h`/`help` print it on stdout
/// (exit 0); a bare `searchd` prints it on stderr (exit 2).
pub const usage_text =
        \\searchd — standalone Zig hybrid search engine and indexer
        \\
        \\Commands:
        \\  index <folder> --out <dir> [--analyzer v1|v2] [--max-chars N]
        \\                       [--overlap-lines N] [--generation N]
        \\                       [--update] [--max-file-bytes N]
        \\                       [--max-total-bytes N] [--keep-generations N]
        \\                       chunk and index UTF-8 text/markdown/source
        \\                       files under <folder> (Markdown with
        \\                       md-section-v1, one chunk per heading
        \\                       section; every other file with
        \\                       line-window-v1), natively (no Python), and
        \\                       publish a lexical-only snapshot to <dir>
        \\                       that also keeps each file's original bytes
        \\                       (for read-span and outline). --analyzer
        \\                       selects the tokenizer/analyzer id recorded in
        \\                       the manifest: v1 is ASCII-only (analyzer-v1),
        \\                       v2 is Unicode-aware (analyzer-v2, NFC +
        \\                       case folding + Unicode letter/digit
        \\                       categories; default). Re-running `index`
        \\                       into an existing --out directory publishes
        \\                       the next generation instead of failing.
        \\                       --update runs incremental indexing instead
        \\                       of a full rebuild: per-file content hashes
        \\                       (persisted in <dir>/INDEX-STATE.json) skip
        \\                       unchanged files, deleted files are
        \\                       tombstoned, and a JSON report (added/
        \\                       changed/removed/unchanged/budget_exhausted/
        \\                       too_large/unreadable/too_large_paths/
        \\                       unreadable_paths/documents/terms/postings)
        \\                       is printed. An empty folder, or a folder
        \\                       whose last file was just deleted, publishes
        \\                       an empty generation instead of failing.
        \\                       --max-file-bytes/--max-total-bytes cap,
        \\                       respectively, one file's size (files over
        \\                       the cap are excluded, named in
        \\                       too_large_paths) and the total bytes read
        \\                       in one run (files left over count as
        \\                       budget_exhausted, default 10 MiB /
        \\                       512 MiB); both apply on a full rebuild and
        \\                       on --update alike (S1-T5). Without --update
        \\                       the summary line prints files_indexed/
        \\                       too_large/unreadable/budget_exhausted; only
        \\                       --update also prints the full JSON report
        \\                       above.
        \\  query <dir> "<text>" [--json] [--top-k N]
        \\                       BM25 lexical query against a published
        \\                       snapshot; human-readable by default, or a
        \\                       JSON result list with --json.
        \\  evidence <dir> "<text>" [--top-k N]
        \\                       same query, always emitted as a JSON
        \\                       evidence envelope (citation + content +
        \\                       scores) intended for an LLM tool call.
        \\  find <dir> "<query>" [--mode words|phrase|prefix] [--roots a,b]
        \\                       [--page-size N] [--cursor C] [--json]
        \\                       the search box: every word (words), the
        \\                       exact phrase ("quoted" forces it), or a
        \\                       word start (a trailing * forces prefix);
        \\                       hits with root, path, lines, section and a
        \\                       snippet, per-file counts, a cursor for the
        \\                       next page (page size 1-100, default 20).
        \\  outline <dir> <root_id> <path> [--json]
        \\                       a file's headings and front matter.
        \\  read-span <dir> <root_id> <path> <start> <end> [--context N]
        \\                       [--json]
        \\                       lines start..end (1-based, inclusive) byte
        \\                       for byte, with up to 20 lines of context;
        \\                       at most 400 lines and 256 KiB.
        \\  list-files <dir> [--root R] [--prefix P] [--status indexed|pending]
        \\                       [--page-size N] [--cursor C] [--json]
        \\                       the indexed and pending files, by root and
        \\                       path (page size 1-1000, default 100).
        \\  roots <dir> [--json] the roots and their file counts.
        \\  apply <dir> --changes <file> [--expect-generation N]
        \\                       [--allow-file-reads] [--json]
        \\                       publish one new generation from host-fed
        \\                       changes (docs/folder-knowledge-
        \\                       implementation.md section 6); prints a
        \\                       summary, or the full report with --json.
        \\                       `file` changes are read only with
        \\                       --allow-file-reads.
        \\                       find, outline, read-span, list-files and
        \\                       roots print text, or with --json the same
        \\                       JSON the C ABI and `serve` return.
        \\  serve <dir> [--http 127.0.0.1:<port>] [--roots a,b]
        \\                       [--labels l1,l2] [--allow-write]
        \\                       [--allow-file-reads]
        \\                       serve JSON-RPC 2.0 requests. With no
        \\                       --http, reads requests as newline-delimited
        \\                       JSON on stdin and writes responses to
        \\                       stdout (unchanged). With --http, additionally
        \\                       accepts one JSON-RPC request per HTTP POST
        \\                       body on the given loopback address/port
        \\                       (127.0.0.1 only; refuses any other host).
        \\                       --roots and --labels set the scope of every
        \\                       request (a request may narrow the roots;
        \\                       with --labels it may not state labels).
        \\                       apply_changes exists only with
        \\                       --allow-write.
        \\  mcp <dir> [--roots a,b] [--labels l1,l2] [--baseline]
        \\                       [--allow-write] [--allow-file-reads]
        \\                       serve the index as a Model Context Protocol
        \\                       server on stdin/stdout (docs/mcp-server.md):
        \\                       the eight read tools and the indexed files as
        \\                       resources; --baseline lists only CAP-13's
        \\                       four tools and no resources; apply_changes
        \\                       only with --allow-write (inside --roots).
        \\                       The scope comes from --roots and --labels
        \\                       only, never from a request.
        \\  demo                 run an in-memory cited hybrid query
        \\  benchmark <docs> <dimensions> <queries> <mode>
        \\                       benchmark the real in-memory engine query path
        \\  init-demo <dir>      publish a small persistent demo snapshot
        \\  import-json <dir> <file> [--keep-generations N]
        \\                       import neutral JSON and publish a snapshot
        \\  help, --help, -h     show this message on stdout (exit 0)
        \\
        \\Vector/hybrid RPC requests must provide a query_vector matching the
        \\embedding dimensions recorded by the snapshot. Lexical mode does not.
        \\`index` never produces vectors (embedding_model_id "none"); its
        \\snapshots only support lexical (BM25) queries.
        \\
        \\Exit status: 0 success; 1 the work failed (a missing folder or
        \\snapshot); 2 usage error (unknown command or flag, missing or invalid
        \\argument; one line on stderr). A bare `searchd` prints this text on
        \\stderr and exits 2. An unreadable file inside the folder does not fail
        \\`index`: it exits 0 and counts the file in `unreadable`.
        \\
    ;

/// Exit status of a usage error (S1-T8 criterion 1). A failure of the work
/// itself (a missing folder or snapshot) is not one; it keeps exit status 1.
pub const usage_exit_status: u8 = 2;

pub const UsageError = struct {
    /// Complete stderr text, ending in a newline: one line for every error
    /// except the bare invocation, which is the usage text.
    message: []const u8,
    status: u8 = usage_exit_status,
};

pub const BenchmarkArgs = struct {
    documents: usize,
    dimensions: usize,
    queries: usize,
    mode: hybrid.RetrievalMode,
};
pub const ImportArgs = struct { snapshot: []const u8, file: []const u8, keep_generations: ?usize = null };
pub const ServeArgs = struct {
    path: []const u8,
    http: ?[]const u8 = null,
    /// S3-T4: comma-separated root ids and labels (split by `splitList`).
    roots: ?[]const u8 = null,
    labels: ?[]const u8 = null,
    allow_write: bool = false,
    allow_file_reads: bool = false,
};
/// S3-T6: `searchd mcp` (`mcp.zig`).
pub const McpArgs = struct {
    path: []const u8,
    roots: ?[]const u8 = null,
    labels: ?[]const u8 = null,
    baseline: bool = false,
    allow_write: bool = false,
    allow_file_reads: bool = false,
};
/// S3-T4: the folder-knowledge commands.
pub const FindArgs = struct {
    path: []const u8,
    query: []const u8,
    mode: ?find_module.Mode = null,
    roots: ?[]const u8 = null,
    page_size: ?usize = null,
    cursor: ?[]const u8 = null,
    json: bool = false,
};
pub const OutlineArgs = struct { path: []const u8, root_id: []const u8, file: []const u8, json: bool = false };
pub const ReadSpanArgs = struct { path: []const u8, root_id: []const u8, file: []const u8, start: u32, end: u32, context: u32 = 0, json: bool = false };
pub const ListFilesArgs = struct {
    path: []const u8,
    root: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    status: ?[]const u8 = null,
    page_size: ?usize = null,
    cursor: ?[]const u8 = null,
    json: bool = false,
};
pub const RootsArgs = struct { path: []const u8, json: bool = false };
pub const ApplyArgs = struct { path: []const u8, changes: []const u8, expect_generation: ?u64 = null, allow_file_reads: bool = false, json: bool = false };
pub const IndexArgs = struct { folder: []const u8, out: []const u8, options: IndexOptions };
pub const QueryArgs = struct { path: []const u8, text: []const u8, options: QueryOptions };

pub const Command = union(enum) {
    help,
    demo,
    benchmark: BenchmarkArgs,
    init_demo: []const u8,
    import_json: ImportArgs,
    serve: ServeArgs,
    mcp: McpArgs,
    index: IndexArgs,
    query: QueryArgs,
    evidence: QueryArgs,
    find: FindArgs,
    outline: OutlineArgs,
    read_span: ReadSpanArgs,
    list_files: ListFilesArgs,
    roots: RootsArgs,
    apply: ApplyArgs,
    usage_error: UsageError,
};

/// Numbers on the command line are digits only: `[0-9]+` within the type's
/// range. No sign, underscore, space, prefix or empty string (S1-T8
/// criterion 2). Returns null for anything else, including out of range.
pub fn parseDigits(comptime T: type, value: []const u8) ?T {
    if (value.len == 0) return null;
    for (value) |byte| if (byte < '0' or byte > '9') return null;
    return std.fmt.parseInt(T, value, 10) catch null;
}

const Parser = struct {
    args: []const []const u8,
    index: usize = 0,
    buffer: []u8,
    message: []const u8 = "",

    fn next(self: *Parser) ?[]const u8 {
        if (self.index >= self.args.len) return null;
        defer self.index += 1;
        return self.args[self.index];
    }

    /// One line, built in the caller's buffer. The value is quoted (so an
    /// empty one shows as '') and cut to what the buffer can hold, with the
    /// cut marked, so the line is always one line naming the option.
    fn usage(self: *Parser, comptime what: []const u8, name: []const u8, value: ?[]const u8, comptime tail: []const u8) error{Usage} {
        const prefix = "searchd: " ++ what ++ " ";
        const reserve = prefix.len + " ''... (value truncated)".len + tail.len + 2;
        var writer = std.Io.Writer.fixed(self.buffer);
        const ok = blk: {
            writer.writeAll(prefix) catch break :blk false;
            writer.writeAll(name) catch break :blk false;
            if (value) |v| {
                writer.writeAll(if (name.len == 0) "'" else ": '") catch break :blk false;
                const room = self.buffer.len -| (writer.end + reserve);
                const shown = v[0..@min(v.len, room)];
                for (shown) |byte| {
                    // A control byte would break the one-line promise.
                    writer.writeByte(if (byte < 0x20 or byte == 0x7f) '?' else byte) catch break :blk false;
                }
                writer.writeAll(if (shown.len < v.len) "...' (value truncated)" else "'") catch break :blk false;
            }
            writer.writeAll(tail) catch break :blk false;
            writer.writeByte('\n') catch break :blk false;
            break :blk true;
        };
        if (ok) {
            self.message = writer.buffered();
        } else if (std.fmt.bufPrint(self.buffer, "searchd: {s} {s} (value truncated)\n", .{ what, name })) |short| {
            // The buffer cannot hold even the cut-down line: name the option only.
            self.message = short;
        } else |_| {
            self.message = "searchd: usage error (see searchd --help)\n";
        }
        return error.Usage;
    }

    fn missingValue(self: *Parser, option: []const u8) error{Usage} {
        return self.usage("missing value for", option, null, "");
    }

    fn missingArgument(self: *Parser, command: []const u8, what: []const u8) error{Usage} {
        _ = command;
        return self.usage("missing argument", what, null, " (see searchd --help)");
    }

    fn valueOf(self: *Parser, option: []const u8) error{Usage}![]const u8 {
        return self.next() orelse self.missingValue(option);
    }

    fn positive(self: *Parser, option: []const u8) error{Usage}!usize {
        const value = try self.valueOf(option);
        const parsed = parseDigits(usize, value) orelse
            return self.usage("invalid value for", option, value, " (expected a positive whole number)");
        if (parsed == 0) return self.usage("invalid value for", option, value, " (expected a positive whole number)");
        return parsed;
    }

    fn nonNegative(self: *Parser, option: []const u8) error{Usage}!usize {
        const value = try self.valueOf(option);
        return parseDigits(usize, value) orelse
            self.usage("invalid value for", option, value, " (expected a non-negative whole number)");
    }

    fn byteCount(self: *Parser, option: []const u8) error{Usage}!u64 {
        const value = try self.valueOf(option);
        return parseDigits(u64, value) orelse
            self.usage("invalid value for", option, value, " (expected a non-negative whole number of bytes)");
    }

    /// A comma-separated list of non-empty items (`--roots`, `--labels`).
    fn list(self: *Parser, option: []const u8) error{Usage}![]const u8 {
        const value = try self.valueOf(option);
        var items = std.mem.splitScalar(u8, value, ',');
        while (items.next()) |item| {
            if (item.len == 0) return self.usage("invalid value for", option, value, " (expected a comma-separated list without empty items)");
        }
        return value;
    }

    /// A whole number in `min..max`.
    fn ranged(self: *Parser, option: []const u8, comptime min: usize, comptime max: usize) error{Usage}!usize {
        const value = try self.valueOf(option);
        const parsed = parseDigits(usize, value) orelse
            return self.usage("invalid value for", option, value, std.fmt.comptimePrint(" (expected a whole number {d}-{d})", .{ min, max }));
        if (parsed < min or parsed > max)
            return self.usage("invalid value for", option, value, std.fmt.comptimePrint(" (expected a whole number {d}-{d})", .{ min, max }));
        return parsed;
    }

    fn noMoreArguments(self: *Parser, command: []const u8) error{Usage}!void {
        if (self.next()) |extra| return self.usage("unexpected argument for", command, extra, " (see searchd --help)");
    }
};

fn parseQueryFlags(p: *Parser, command: []const u8) error{Usage}!QueryOptions {
    var options = QueryOptions{};
    while (p.next()) |flag| {
        if (std.mem.eql(u8, flag, "--search-field")) {
            const value = p.next() orelse return p.missingArgument(command, "--search-field");
            options.search_field = std.meta.stringToEnum(filename_field.Field, value) orelse return p.usage("invalid value for", "--search-field", value, " (expected content, filename or both)");
        } else if (std.mem.eql(u8, flag, "--json")) {
            options.json = true;
        } else if (std.mem.eql(u8, flag, "--top-k")) {
            options.top_k = try p.positive("--top-k");
        } else {
            return p.usage("unknown flag for", command, flag, " (see searchd --help)");
        }
    }
    return options;
}

fn parseInner(p: *Parser) error{Usage}!Command {
    const command = p.next() orelse {
        p.message = usage_text;
        return error.Usage;
    };
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "help")) {
        try p.noMoreArguments("help");
        return .help;
    }
    if (std.mem.eql(u8, command, "demo")) {
        try p.noMoreArguments("demo");
        return .demo;
    }
    if (std.mem.eql(u8, command, "benchmark")) {
        const documents = try benchmarkNumber(p, "<docs>", true);
        const dimensions = try benchmarkNumber(p, "<dimensions>", false);
        const queries = try benchmarkNumber(p, "<queries>", true);
        const mode_text = p.next() orelse return p.missingArgument("benchmark", "<mode>");
        const mode = parseRetrievalMode(mode_text) orelse
            return p.usage("invalid value for", "benchmark <mode>", mode_text, " (expected lexical, vector or hybrid)");
        // The limits `benchmark.run` enforces, judged here so nothing starts first.
        if (documents > benchmark.max_documents)
            return p.usage("invalid value for", "benchmark <docs>", null, " (at most 100000)");
        if (dimensions > benchmark.max_dimensions)
            return p.usage("invalid value for", "benchmark <dimensions>", null, " (at most 4096)");
        if (mode != .lexical and dimensions == 0)
            return p.usage("invalid value for", "benchmark <dimensions>", null, " (must be at least 1 for vector and hybrid)");
        if (queries > benchmark.max_queries)
            return p.usage("invalid value for", "benchmark <queries>", null, " (at most 10000)");
        try p.noMoreArguments("benchmark");
        return .{ .benchmark = .{ .documents = documents, .dimensions = dimensions, .queries = queries, .mode = mode } };
    }
    if (std.mem.eql(u8, command, "init-demo")) {
        const path = p.next() orelse return p.missingArgument("init-demo", "<dir>");
        try p.noMoreArguments("init-demo");
        return .{ .init_demo = path };
    }
    if (std.mem.eql(u8, command, "import-json")) {
        const snapshot = p.next() orelse return p.missingArgument("import-json", "<dir>");
        const file = p.next() orelse return p.missingArgument("import-json", "<file>");
        var keep: ?usize = null;
        while (p.next()) |flag| {
            if (std.mem.eql(u8, flag, "--keep-generations")) {
                keep = try p.positive("--keep-generations");
            } else {
                return p.usage("unexpected argument for", "import-json", flag, " (see searchd --help)");
            }
        }
        return .{ .import_json = .{ .snapshot = snapshot, .file = file, .keep_generations = keep } };
    }
    if (std.mem.eql(u8, command, "serve")) {
        const path = p.next() orelse return p.missingArgument("serve", "<dir>");
        var http: ?[]const u8 = null;
        var roots: ?[]const u8 = null;
        var labels: ?[]const u8 = null;
        var allow_write = false;
        var allow_file_reads = false;
        while (p.next()) |flag| {
            if (std.mem.eql(u8, flag, "--http")) {
                const address = try p.valueOf("--http");
                const colon = std.mem.lastIndexOfScalar(u8, address, ':');
                const host = if (colon) |c| address[0..c] else "";
                if (colon == null or parseDigits(u16, address[colon.? + 1 ..]) == null)
                    return p.usage("invalid value for", "--http", address, " (expected 127.0.0.1:<port>)");
                if (!std.mem.eql(u8, host, "127.0.0.1") and !std.mem.eql(u8, host, "localhost"))
                    return p.usage("invalid value for", "--http", address, " (only 127.0.0.1 or localhost are allowed)");
                http = address;
            } else if (std.mem.eql(u8, flag, "--roots")) {
                roots = try p.list("--roots");
            } else if (std.mem.eql(u8, flag, "--labels")) {
                labels = try p.list("--labels");
            } else if (std.mem.eql(u8, flag, "--allow-write")) {
                allow_write = true;
            } else if (std.mem.eql(u8, flag, "--allow-file-reads")) {
                allow_file_reads = true;
            } else {
                return p.usage("unknown flag for", "serve", flag, " (see searchd --help)");
            }
        }
        return .{ .serve = .{ .path = path, .http = http, .roots = roots, .labels = labels, .allow_write = allow_write, .allow_file_reads = allow_file_reads } };
    }
    if (std.mem.eql(u8, command, "mcp")) {
        const path = p.next() orelse return p.missingArgument("mcp", "<dir>");
        var args = McpArgs{ .path = path };
        while (p.next()) |flag| {
            if (std.mem.eql(u8, flag, "--roots")) {
                args.roots = try p.list("--roots");
            } else if (std.mem.eql(u8, flag, "--labels")) {
                args.labels = try p.list("--labels");
            } else if (std.mem.eql(u8, flag, "--baseline")) {
                args.baseline = true;
            } else if (std.mem.eql(u8, flag, "--allow-write")) {
                args.allow_write = true;
            } else if (std.mem.eql(u8, flag, "--allow-file-reads")) {
                args.allow_file_reads = true;
            } else {
                return p.usage("unknown flag for", "mcp", flag, " (see searchd --help)");
            }
        }
        // CAP-13's baseline is read-only; file reads only serve a write.
        if (args.baseline and args.allow_write) return p.usage("invalid value for", "mcp --baseline", null, " (the baseline is read-only: no --allow-write)");
        if (args.allow_file_reads and !args.allow_write) return p.usage("invalid value for", "mcp --allow-file-reads", null, " (needs --allow-write)");
        return .{ .mcp = args };
    }
    if (std.mem.eql(u8, command, "index")) {
        const folder = p.next() orelse return p.missingArgument("index", "<folder>");
        var options = IndexOptions{};
        var out: ?[]const u8 = null;
        while (p.next()) |flag| {
            if (std.mem.eql(u8, flag, "--out")) {
                out = try p.valueOf("--out");
            } else if (std.mem.eql(u8, flag, "--analyzer")) {
                const value = try p.valueOf("--analyzer");
                options.analyzer = indexer.AnalyzerId.parse(value) orelse
                    return p.usage("invalid value for", "--analyzer", value, " (expected v1 or v2)");
            } else if (std.mem.eql(u8, flag, "--max-chars")) {
                options.max_chars = try p.positive("--max-chars");
            } else if (std.mem.eql(u8, flag, "--overlap-lines")) {
                options.overlap_lines = try p.nonNegative("--overlap-lines");
            } else if (std.mem.eql(u8, flag, "--generation")) {
                const value = try p.valueOf("--generation");
                options.generation = parseDigits(u64, value) orelse
                    return p.usage("invalid value for", "--generation", value, " (expected a positive whole number)");
                if (options.generation.? == 0)
                    return p.usage("invalid value for", "--generation", value, " (expected a positive whole number)");
            } else if (std.mem.eql(u8, flag, "--filename-index")) {
                options.caps.filename_index = true;
            } else if (std.mem.eql(u8, flag, "--update")) {
                options.update = true;
            } else if (std.mem.eql(u8, flag, "--max-file-bytes")) {
                options.caps.max_file_bytes = try p.byteCount("--max-file-bytes");
            } else if (std.mem.eql(u8, flag, "--max-total-bytes")) {
                options.caps.max_total_bytes = try p.byteCount("--max-total-bytes");
            } else if (std.mem.eql(u8, flag, "--keep-generations")) {
                options.caps.keep_generations = try p.positive("--keep-generations");
            } else {
                return p.usage("unknown flag for", "index", flag, " (see searchd --help)");
            }
        }
        return .{ .index = .{
            .folder = folder,
            .out = out orelse return p.missingArgument("index", "--out <dir>"),
            .options = options,
        } };
    }
    const is_query = std.mem.eql(u8, command, "query");
    if (is_query or std.mem.eql(u8, command, "evidence")) {
        const name: []const u8 = if (is_query) "query" else "evidence";
        const path = p.next() orelse return p.missingArgument(name, "<dir>");
        const text = p.next() orelse return p.missingArgument(name, "\"<text>\"");
        // S2-T11: invalid UTF-8 is a usage error (exit 2), judged here with the others.
        if (!std.unicode.utf8ValidateSlice(text))
            return p.usage("invalid value for", "query text", null, " (not valid UTF-8)");
        const args = QueryArgs{ .path = path, .text = text, .options = try parseQueryFlags(p, name) };
        return if (is_query) .{ .query = args } else .{ .evidence = args };
    }
    if (std.mem.eql(u8, command, "find")) return parseFind(p);
    if (std.mem.eql(u8, command, "outline")) {
        var args = OutlineArgs{
            .path = p.next() orelse return p.missingArgument("outline", "<dir>"),
            .root_id = p.next() orelse return p.missingArgument("outline", "<root_id>"),
            .file = p.next() orelse return p.missingArgument("outline", "<path>"),
        };
        while (p.next()) |flag| {
            if (std.mem.eql(u8, flag, "--json")) args.json = true else return p.usage("unknown flag for", "outline", flag, " (see searchd --help)");
        }
        return .{ .outline = args };
    }
    if (std.mem.eql(u8, command, "read-span")) return parseReadSpan(p);
    if (std.mem.eql(u8, command, "list-files")) {
        var args = ListFilesArgs{ .path = p.next() orelse return p.missingArgument("list-files", "<dir>") };
        while (p.next()) |flag| {
            if (std.mem.eql(u8, flag, "--json")) {
                args.json = true;
            } else if (std.mem.eql(u8, flag, "--root")) {
                args.root = try p.valueOf("--root");
            } else if (std.mem.eql(u8, flag, "--prefix")) {
                args.prefix = try p.valueOf("--prefix");
            } else if (std.mem.eql(u8, flag, "--status")) {
                const value = try p.valueOf("--status");
                if (!std.mem.eql(u8, value, "indexed") and !std.mem.eql(u8, value, "pending"))
                    return p.usage("invalid value for", "--status", value, " (expected indexed or pending)");
                args.status = value;
            } else if (std.mem.eql(u8, flag, "--page-size")) {
                args.page_size = try p.ranged("--page-size", 1, ops.max_list_page_size);
            } else if (std.mem.eql(u8, flag, "--cursor")) {
                args.cursor = try p.valueOf("--cursor");
            } else return p.usage("unknown flag for", "list-files", flag, " (see searchd --help)");
        }
        return .{ .list_files = args };
    }
    if (std.mem.eql(u8, command, "roots")) {
        var args = RootsArgs{ .path = p.next() orelse return p.missingArgument("roots", "<dir>") };
        while (p.next()) |flag| {
            if (std.mem.eql(u8, flag, "--json")) args.json = true else return p.usage("unknown flag for", "roots", flag, " (see searchd --help)");
        }
        return .{ .roots = args };
    }
    if (std.mem.eql(u8, command, "apply")) {
        const path = p.next() orelse return p.missingArgument("apply", "<dir>");
        var changes: ?[]const u8 = null;
        var args = ApplyArgs{ .path = path, .changes = "" };
        while (p.next()) |flag| {
            if (std.mem.eql(u8, flag, "--changes")) {
                changes = try p.valueOf("--changes");
            } else if (std.mem.eql(u8, flag, "--expect-generation")) {
                const value = try p.valueOf("--expect-generation");
                args.expect_generation = parseDigits(u64, value) orelse
                    return p.usage("invalid value for", "--expect-generation", value, " (expected a non-negative whole number)");
            } else if (std.mem.eql(u8, flag, "--allow-file-reads")) {
                args.allow_file_reads = true;
            } else if (std.mem.eql(u8, flag, "--json")) {
                args.json = true;
            } else return p.usage("unknown flag for", "apply", flag, " (see searchd --help)");
        }
        args.changes = changes orelse return p.missingArgument("apply", "--changes <file>");
        return .{ .apply = args };
    }
    return p.usage("unknown command", "", command, "; try searchd --help");
}

fn parseFind(p: *Parser) error{Usage}!Command {
    const path = p.next() orelse return p.missingArgument("find", "<dir>");
    const query = p.next() orelse return p.missingArgument("find", "\"<query>\"");
    if (!std.unicode.utf8ValidateSlice(query))
        return p.usage("invalid value for", "query text", null, " (not valid UTF-8)");
    var args = FindArgs{ .path = path, .query = query };
    while (p.next()) |flag| {
        if (std.mem.eql(u8, flag, "--json")) {
            args.json = true;
        } else if (std.mem.eql(u8, flag, "--mode")) {
            const value = try p.valueOf("--mode");
            args.mode = find_module.Mode.parse(value) orelse
                return p.usage("invalid value for", "--mode", value, " (expected words, phrase or prefix)");
        } else if (std.mem.eql(u8, flag, "--roots")) {
            args.roots = try p.list("--roots");
        } else if (std.mem.eql(u8, flag, "--page-size")) {
            args.page_size = try p.ranged("--page-size", 1, find_module.max_page_size);
        } else if (std.mem.eql(u8, flag, "--cursor")) {
            args.cursor = try p.valueOf("--cursor");
        } else return p.usage("unknown flag for", "find", flag, " (see searchd --help)");
    }
    return .{ .find = args };
}

fn parseReadSpan(p: *Parser) error{Usage}!Command {
    const path = p.next() orelse return p.missingArgument("read-span", "<dir>");
    const root_id = p.next() orelse return p.missingArgument("read-span", "<root_id>");
    const file = p.next() orelse return p.missingArgument("read-span", "<path>");
    const start = try lineArgument(p, "<start>");
    const end = try lineArgument(p, "<end>");
    if (end < start) return p.usage("invalid value for", "read-span <end>", null, " (must be at least <start>)");
    var args = ReadSpanArgs{ .path = path, .root_id = root_id, .file = file, .start = start, .end = end };
    while (p.next()) |flag| {
        if (std.mem.eql(u8, flag, "--json")) {
            args.json = true;
        } else if (std.mem.eql(u8, flag, "--context")) {
            args.context = @intCast(try p.ranged("--context", 0, source.max_context_lines));
        } else return p.usage("unknown flag for", "read-span", flag, " (see searchd --help)");
    }
    return .{ .read_span = args };
}

fn lineArgument(p: *Parser, comptime what: []const u8) error{Usage}!u32 {
    const value = p.next() orelse return p.missingArgument("read-span", what);
    const parsed = parseDigits(u32, value) orelse
        return p.usage("invalid value for", "read-span " ++ what, value, " (expected a line number, 1 or more)");
    if (parsed == 0) return p.usage("invalid value for", "read-span " ++ what, value, " (expected a line number, 1 or more)");
    return parsed;
}

fn benchmarkNumber(p: *Parser, comptime what: []const u8, comptime positive: bool) error{Usage}!usize {
    const value = p.next() orelse return p.missingArgument("benchmark", what);
    const parsed = parseDigits(usize, value) orelse
        return p.usage("invalid value for", "benchmark " ++ what, value, if (positive) " (expected a positive whole number)" else " (expected a non-negative whole number)");
    if (positive and parsed == 0) return p.usage("invalid value for", "benchmark " ++ what, value, " (expected a positive whole number)");
    return parsed;
}

fn parseRetrievalMode(value: []const u8) ?hybrid.RetrievalMode {
    if (std.mem.eql(u8, value, "lexical")) return .lexical;
    if (std.mem.eql(u8, value, "vector")) return .vector;
    if (std.mem.eql(u8, value, "hybrid")) return .hybrid;
    return null;
}

/// S1-T8 criterion 1: the one place that decides what is a usage error, and
/// the line it prints. `args` excludes the program name. A usage error is
/// returned as `.usage_error` (message and status); `message` may point into
/// `buffer`. `main.zig` only prints it and exits.
pub fn parseArgs(args: []const []const u8, buffer: []u8) Command {
    var parser = Parser{ .args = args, .buffer = buffer };
    return parseInner(&parser) catch .{ .usage_error = .{ .message = parser.message } };
}

pub fn runIndex(
    io: std.Io,
    allocator: std.mem.Allocator,
    folder_path: []const u8,
    out_path: []const u8,
    options: IndexOptions,
    output: *std.Io.Writer,
) !void {
    var root = try std.Io.Dir.cwd().openDir(io, folder_path, .{ .iterate = true });
    defer root.close(io);
    var out_dir = try std.Io.Dir.cwd().createDirPathOpen(io, out_path, .{ .open_options = .{ .iterate = true } });
    defer out_dir.close(io);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (options.update) {
        const report = try indexer.indexFolderIncremental(
            arena,
            io,
            root,
            out_dir,
            options.analyzer,
            options.max_chars,
            options.overlap_lines,
            options.caps,
        );
        var json = std.json.Stringify{ .writer = output };
        try json.beginObject();
        try json.objectField("generation");
        try json.write(report.generation);
        try json.objectField("analyzer_id");
        try json.write(report.analyzer_id);
        try json.objectField("added");
        try json.write(report.added);
        try json.objectField("changed");
        try json.write(report.changed);
        try json.objectField("removed");
        try json.write(report.removed);
        try json.objectField("unchanged");
        try json.write(report.unchanged);
        try json.objectField("budget_exhausted");
        try json.write(report.budget_exhausted);
        try json.objectField("too_large");
        try json.write(report.too_large);
        try json.objectField("unreadable");
        try json.write(report.unreadable);
        try json.objectField("too_large_paths");
        try json.beginArray();
        for (report.too_large_paths) |path| try json.write(path);
        try json.endArray();
        try json.objectField("unreadable_paths");
        try json.beginArray();
        for (report.unreadable_paths) |path| try json.write(path);
        try json.endArray();
        try json.objectField("documents");
        try json.write(report.documents);
        try json.objectField("terms");
        try json.write(report.terms);
        try json.objectField("postings");
        try json.write(report.postings);
        if (report.recovered) |why| {
            try json.objectField("recovered");
            try json.write(why);
        }
        if (options.caps.keep_generations != null) {
            try json.objectField("pruned_files");
            try json.write(report.pruned_files);
            try json.objectField("prune_failures");
            try json.write(report.prune_failures);
        }
        try json.endObject();
        try output.writeByte('\n');
        return;
    }

    const generation = options.generation orelse try generation_alloc.nextFreeGeneration(arena, io, out_dir);
    const report = try indexer.indexFolder(
        arena,
        io,
        root,
        out_dir,
        options.analyzer,
        generation,
        options.max_chars,
        options.overlap_lines,
        options.caps,
    );

    // S1-T5 criterion 1 (round-E rework): `too_large` and `unreadable` used
    // to be folded into one `files_skipped` count on this (non-`--update`)
    // path, which meant an operator could not tell "over a size cap" from
    // "could not be read at all" on a full rebuild -- the exact distinction
    // S1-T4 criterion 3 already gave `--update`.
    try output.print(
        "indexed {s}: analyzer={s} generation={d} files_indexed={d} too_large={d} unreadable={d} budget_exhausted={d} documents={d} terms={d} postings={d}",
        .{ folder_path, report.analyzer_id, report.generation, report.added, report.too_large, report.unreadable, report.budget_exhausted, report.documents, report.terms, report.postings },
    );
    if (options.caps.keep_generations != null) {
        try output.print(" pruned_files={d} prune_failures={d}", .{ report.pruned_files, report.prune_failures });
    }
    try output.writeByte('\n');
}

pub const QueryOptions = struct {
    search_field: filename_field.Field = .content,
    top_k: usize = 10,
    json: bool = false,
};

fn runSearch(
    allocator: std.mem.Allocator,
    engine: engine_module.Engine,
    query_text: []const u8,
    top_k: usize,
) ![]hybrid.Result {
    const result_output = try allocator.alloc(hybrid.Result, engine.documents.len);
    const options = hybrid.SearchOptions{ .top_k = top_k, .candidate_k = @max(top_k, engine.documents.len), .retrieval_mode = .lexical };
    return engine.queryTokenized(allocator, query_text, &.{}, result_output, options);
}

pub fn runQuery(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    query_text: []const u8,
    options: QueryOptions,
    output: *std.Io.Writer,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    const engine = if (options.search_field != .content) (try snapshot_open.openScoped(arena, io, dir)).engine else try snapshot_open.open(arena, io, dir);
    if (options.search_field != .content) {
        const query_options = hybrid.SearchOptions{ .top_k = options.top_k, .candidate_k = @max(options.top_k, 100), .retrieval_mode = .lexical };
        const hits = try engine.queryFields(arena, query_text, options.search_field, query_options);
        try filename_response.writeEvidence(output, arena, engine, query_text, options.search_field, query_options, hits, !options.json);
        try output.writeByte('\n');
        return;
    }
    const results = try runSearch(arena, engine, query_text, options.top_k);

    if (options.json) {
        var json = std.json.Stringify{ .writer = output };
        try json.beginObject();
        try json.objectField("query");
        try json.write(query_text);
        try json.objectField("analyzer_id");
        try json.write(engine.analyzer_id);
        try json.objectField("results");
        try json.beginArray();
        for (results) |result| {
            const evidence = engine.evidence(result);
            try json.beginObject();
            try json.objectField("chunk_id");
            try json.write(evidence.chunk_id);
            try json.objectField("path");
            try json.write(evidence.path);
            try json.objectField("start_line");
            try json.write(evidence.start_line);
            try json.objectField("end_line");
            try json.write(evidence.end_line);
            try json.objectField("score");
            try json.write(evidence.fused_score);
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
        try output.writeByte('\n');
        return;
    }

    try output.print("query: {s} (analyzer={s})\n", .{ query_text, engine.analyzer_id });
    for (results, 0..) |result, index| {
        try output.print("{d}. {s}:{d}-{d} score={d:.6}\n", .{ index + 1, result.path, result.start_line, result.end_line, result.fused_score });
    }
}

pub fn runEvidence(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    query_text: []const u8,
    options: QueryOptions,
    output: *std.Io.Writer,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    const engine = if (options.search_field != .content) (try snapshot_open.openScoped(arena, io, dir)).engine else try snapshot_open.open(arena, io, dir);
    if (options.search_field != .content) {
        const query_options = hybrid.SearchOptions{ .top_k = options.top_k, .candidate_k = @max(options.top_k, 100), .retrieval_mode = .lexical };
        const hits = try engine.queryFields(arena, query_text, options.search_field, query_options);
        try filename_response.writeEvidence(output, arena, engine, query_text, options.search_field, query_options, hits, false);
        try output.writeByte('\n');
        return;
    }
    const results = try runSearch(arena, engine, query_text, options.top_k);

    var json = std.json.Stringify{ .writer = output };
    try json.beginObject();
    try json.objectField("query");
    try json.write(query_text);
    try json.objectField("analyzer_id");
    try json.write(engine.analyzer_id);
    try json.objectField("evidence");
    try json.beginArray();
    for (results) |result| {
        const evidence = engine.evidence(result);
        try json.beginObject();
        try json.objectField("chunk_id");
        try json.write(evidence.chunk_id);
        try json.objectField("path");
        try json.write(evidence.path);
        try json.objectField("start_line");
        try json.write(evidence.start_line);
        try json.objectField("end_line");
        try json.write(evidence.end_line);
        try json.objectField("content");
        try json.write(evidence.content);
        try json.objectField("fused_score");
        try json.write(evidence.fused_score);
        try json.objectField("lexical_score");
        try json.write(evidence.lexical_score);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try output.writeByte('\n');
}

// === S3-T4: find, outline, read-span, list-files, roots, apply ==============
//
// Each command opens the index with its scope data (`snapshot_open.openScoped`),
// builds the same request object the C ABI and the RPC server take, and runs
// the same `ops.zig` function, so `--json` prints exactly their JSON. The CLI
// runs as the index's owner: every root, no principal labels (the default
// scope of `ss_query`); `find --roots` narrows it. A refusal from the core
// (`INVALID_ARGUMENT`, `NOT_FOUND`, `CAPACITY`) prints one line on stderr and
// exits 1, like any other failure of the work; usage errors stay exit 2.

/// The CLI's scope: every root, no labels.
pub const cli_caller = ops.Caller{};

const Params = struct {
    arena: std.mem.Allocator,
    map: std.json.ObjectMap = .empty,

    fn string(params: *Params, name: []const u8, value: ?[]const u8) !void {
        if (value) |text| try params.map.put(params.arena, name, .{ .string = text });
    }

    fn integer(params: *Params, name: []const u8, value: anytype) !void {
        const present: ?u64 = value;
        if (present) |number| try params.map.put(params.arena, name, .{ .integer = @intCast(number) });
    }

    fn list(params: *Params, name: []const u8, comma_separated: ?[]const u8) !void {
        const text = comma_separated orelse return;
        var array = std.json.Array.init(params.arena);
        var items = std.mem.splitScalar(u8, text, ',');
        while (items.next()) |item| try array.append(.{ .string = item });
        try params.map.put(params.arena, name, .{ .array = array });
    }
};

/// The index at `path`, opened for the scoped operations (owned by `arena`).
pub fn openService(arena: std.mem.Allocator, io: std.Io, path: []const u8) !service_module.Service {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    const opened = try snapshot_open.openScoped(arena, io, dir);
    return .{ .engine = opened.engine, .folder = opened.folder };
}

/// Print `result`: its JSON (with `json`) or `human`'s text; a refusal is one
/// stderr line and status 1.
fn finish(arena: std.mem.Allocator, result: ops.Result, json: bool, output: *std.Io.Writer, errors: *std.Io.Writer, comptime human: anytype) !u8 {
    switch (result) {
        .failed => |failure| {
            try errors.print("searchd: {s}: {s}\n", .{ failure.code.ssName(), oneLine(failure.message) });
            return 1;
        },
        .ok => |text| {
            if (json) {
                try output.writeAll(text);
                try output.writeByte('\n');
                return 0;
            }
            const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
            try human(output, value);
            return 0;
        },
    }
}

fn oneLine(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfAny(u8, text, "\r\n") orelse text.len];
}

fn field(value: std.json.Value, name: []const u8) std.json.Value {
    return value.object.get(name) orelse .null;
}

fn jsonText(value: std.json.Value) []const u8 {
    return switch (value) {
        .string => |s| s,
        else => "",
    };
}

fn jsonInt(value: std.json.Value) i64 {
    return switch (value) {
        .integer => |n| n,
        else => 0,
    };
}

fn jsonFloat(value: std.json.Value) f64 {
    return switch (value) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => 0,
    };
}

pub fn runFind(io: std.Io, allocator: std.mem.Allocator, args: FindArgs, output: *std.Io.Writer, errors: *std.Io.Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const service = try openService(arena, io, args.path);
    var params = Params{ .arena = arena };
    try params.string("query", args.query);
    if (args.mode) |mode| try params.string("mode", mode.label());
    try params.list("roots", args.roots);
    try params.integer("page_size", args.page_size);
    try params.string("cursor", args.cursor);
    return finish(arena, try ops.find(arena, service, params.map, cli_caller), args.json, output, errors, printFind);
}

fn printFind(output: *std.Io.Writer, value: std.json.Value) !void {
    const request = field(value, "request");
    const hits = field(value, "hits").array.items;
    var total: i64 = 0;
    for (field(value, "files").array.items) |file| total += jsonInt(field(file, "hits"));
    try output.print("find: {s} (mode {s}, generation {d}): {d} hits in {d} files", .{
        jsonText(field(request, "query")), jsonText(field(request, "mode")), jsonInt(field(value, "generation")), total, field(value, "files").array.items.len,
    });
    if (field(value, "exact_match") == .bool) try output.print(", exact match {s}", .{if (field(value, "exact_match").bool) "yes" else "no"});
    try output.writeByte('\n');
    const offset: i64 = if (field(request, "cursor") == .string) blk: {
        const cursor = jsonText(field(request, "cursor"));
        const colon = std.mem.indexOfScalar(u8, cursor, ':') orelse break :blk 0;
        break :blk std.fmt.parseInt(i64, cursor[colon + 1 ..], 10) catch 0;
    } else 0;
    for (hits, 0..) |hit, index| {
        try output.print("{d}. {s}/{s}:{d}-{d} score={d:.3}", .{
            offset + @as(i64, @intCast(index)) + 1, jsonText(field(hit, "root_id")), jsonText(field(hit, "path")), jsonInt(field(hit, "start_line")), jsonInt(field(hit, "end_line")), jsonFloat(field(hit, "score")),
        });
        const sections = field(hit, "section_path").array.items;
        if (sections.len > 0) {
            try output.writeAll(" [");
            for (sections, 0..) |part, at| {
                if (at > 0) try output.writeAll(" > ");
                try output.writeAll(jsonText(part));
            }
            try output.writeAll("]");
        }
        try output.writeAll("\n   ");
        for (jsonText(field(hit, "snippet"))) |byte| try output.writeByte(if (byte == '\n' or byte == '\r') ' ' else byte);
        try output.writeByte('\n');
    }
    if (field(value, "next_cursor") == .string) try output.print("next page: --cursor {s}\n", .{jsonText(field(value, "next_cursor"))});
    const pending = jsonInt(field(value, "pending_files"));
    if (pending > 0) try output.print("pending files: {d} (not indexed yet; the answer may be incomplete)\n", .{pending});
    if (field(value, "truncated") == .bool and field(value, "truncated").bool) try output.writeAll("truncated: a file in scope was not indexed in full\n");
}

pub fn runOutline(io: std.Io, allocator: std.mem.Allocator, args: OutlineArgs, output: *std.Io.Writer, errors: *std.Io.Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const service = try openService(arena, io, args.path);
    var params = Params{ .arena = arena };
    try params.string("root_id", args.root_id);
    try params.string("path", args.file);
    return finish(arena, try ops.outline(arena, service, params.map, cli_caller), args.json, output, errors, printOutline);
}

fn printOutline(output: *std.Io.Writer, value: std.json.Value) !void {
    const request = field(value, "request");
    try output.print("{s}/{s}: {d} lines, {s}\n", .{ jsonText(field(request, "root_id")), jsonText(field(request, "path")), jsonInt(field(value, "lines")), jsonText(field(value, "chunker")) });
    const front = field(value, "front_matter");
    if (front == .object) {
        try output.print("front matter: lines {d}-{d}", .{ jsonInt(field(front, "start_line")), jsonInt(field(front, "end_line")) });
        var fields = field(front, "fields").object.iterator();
        var first = true;
        while (fields.next()) |entry| {
            try output.print("{s}{s}: {s}", .{ if (first) " (" else ", ", entry.key_ptr.*, jsonText(entry.value_ptr.*) });
            first = false;
        }
        try output.writeAll(if (first) "\n" else ")\n");
    }
    for (field(value, "headings").array.items) |heading| {
        const level: usize = @intCast(@max(1, jsonInt(field(heading, "level"))));
        try output.splatByteAll(' ', 2 * (level - 1));
        try output.splatByteAll('#', level);
        try output.print(" {s} (lines {d}-{d})\n", .{ jsonText(field(heading, "text")), jsonInt(field(heading, "line")), jsonInt(field(heading, "end_line")) });
    }
}

pub fn runReadSpan(io: std.Io, allocator: std.mem.Allocator, args: ReadSpanArgs, output: *std.Io.Writer, errors: *std.Io.Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const service = try openService(arena, io, args.path);
    var params = Params{ .arena = arena };
    try params.string("root_id", args.root_id);
    try params.string("path", args.file);
    try params.integer("start_line", args.start);
    try params.integer("end_line", args.end);
    try params.integer("context_lines", args.context);
    return finish(arena, try ops.readSpan(arena, service, params.map, cli_caller), args.json, output, errors, printReadSpan);
}

/// The lines exactly as stored (context included when asked for).
fn printReadSpan(output: *std.Io.Writer, value: std.json.Value) !void {
    try output.writeAll(jsonText(field(value, "context_before")));
    try output.writeAll(jsonText(field(value, "text")));
    try output.writeAll(jsonText(field(value, "context_after")));
}

pub fn runListFiles(io: std.Io, allocator: std.mem.Allocator, args: ListFilesArgs, output: *std.Io.Writer, errors: *std.Io.Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const service = try openService(arena, io, args.path);
    var params = Params{ .arena = arena };
    try params.string("root_id", args.root);
    try params.string("path_prefix", args.prefix);
    try params.string("status", args.status);
    try params.integer("page_size", args.page_size);
    try params.string("cursor", args.cursor);
    return finish(arena, try ops.listFiles(arena, service, params.map, cli_caller), args.json, output, errors, printListFiles);
}

fn printListFiles(output: *std.Io.Writer, value: std.json.Value) !void {
    for (field(value, "files").array.items) |file| {
        try output.print("{s}/{s}  {s}  chunks={d}", .{ jsonText(field(file, "root_id")), jsonText(field(file, "path")), jsonText(field(file, "status")), jsonInt(field(file, "chunks")) });
        if (field(file, "chunker") == .string) try output.print("  {s}", .{jsonText(field(file, "chunker"))});
        if (field(file, "size") == .integer) try output.print("  {d} bytes", .{jsonInt(field(file, "size"))});
        try output.writeByte('\n');
    }
    try output.print("{d} files\n", .{jsonInt(field(value, "total"))});
    if (field(value, "next_cursor") == .string) try output.print("next page: --cursor {s}\n", .{jsonText(field(value, "next_cursor"))});
}

pub fn runRoots(io: std.Io, allocator: std.mem.Allocator, args: RootsArgs, output: *std.Io.Writer, errors: *std.Io.Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const service = try openService(arena, io, args.path);
    return finish(arena, try ops.visibleRoots(arena, service, .empty, cli_caller), args.json, output, errors, printRoots);
}

fn printRoots(output: *std.Io.Writer, value: std.json.Value) !void {
    for (field(value, "roots").array.items) |root| {
        try output.print("{s}  {s}  {s}  files={d} documents={d} pending={d}\n", .{
            jsonText(field(root, "root_id")), jsonText(field(root, "label")), jsonText(field(root, "kind")), jsonInt(field(root, "files")), jsonInt(field(root, "documents")), jsonInt(field(root, "pending")),
        });
    }
}

pub fn runApply(io: std.Io, allocator: std.mem.Allocator, args: ApplyArgs, output: *std.Io.Writer, errors: *std.Io.Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = std.Io.Dir.cwd();
    const stat = try cwd.statFile(io, args.changes, .{});
    const size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    var request_json = try cwd.readFile(io, args.changes, try arena.alloc(u8, size));
    if (args.expect_generation) |wanted| {
        // The flag sets the request's `expect_generation`; a request that
        // already states another one is refused rather than overridden.
        switch (try ops.parseObject(arena, request_json)) {
            .failed => |failure| return finish(arena, .{ .failed = failure }, args.json, output, errors, printApply),
            .ok => |object| {
                var copy = object;
                if (copy.get("expect_generation")) |stated| {
                    if (stated != .integer or stated.integer != @as(i64, @intCast(wanted))) {
                        try errors.print("searchd: SS_ERR_INVALID_ARGUMENT: --expect-generation {d} differs from the request's expect_generation\n", .{wanted});
                        return 1;
                    }
                }
                try copy.put(arena, "expect_generation", .{ .integer = @intCast(wanted) });
                request_json = try std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = copy }, .{});
            },
        }
    }
    var dir = try cwd.createDirPathOpen(io, args.path, .{ .open_options = .{ .iterate = true } });
    defer dir.close(io);
    const result = try ops.applyChanges(arena, io, dir, request_json, .{ .allow_file_reads = args.allow_file_reads });
    return finish(arena, result, args.json, output, errors, printApply);
}

fn printApply(output: *std.Io.Writer, value: std.json.Value) !void {
    try output.print("applied: generation={d}", .{jsonInt(field(value, "generation"))});
    for ([_][]const u8{ "added", "changed", "removed", "moved", "pending", "unchanged", "too_large", "unreadable", "budget_exhausted", "roots_removed" }) |name| {
        try output.print(" {s}={d}", .{ name, jsonInt(field(value, name)) });
    }
    try output.print(" rejected={d} conflicts={d}", .{ field(value, "rejected").array.items.len, field(value, "conflicts").array.items.len });
    if (field(value, "recovered") == .string) try output.print(" recovered={s}", .{jsonText(field(value, "recovered"))});
    try output.writeByte('\n');
}

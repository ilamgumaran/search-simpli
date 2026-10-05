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
const std = @import("std");
const chunker = @import("chunker.zig");
const engine_module = @import("engine.zig");
const generation_alloc = @import("generation_alloc.zig");
const hybrid = @import("hybrid.zig");
const indexer = @import("indexer.zig");
const snapshot_open = @import("snapshot_open.zig");

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
        \\                       [--max-total-bytes N]
        \\                       chunk (line-window-v1) and index UTF-8
        \\                       text/markdown/source files under <folder>,
        \\                       natively (no Python), and publish a
        \\                       lexical-only snapshot to <dir>. --analyzer
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
        \\  serve <dir> [--http 127.0.0.1:<port>]
        \\                       serve JSON-RPC 2.0 requests. With no
        \\                       --http, reads requests as newline-delimited
        \\                       JSON on stdin and writes responses to
        \\                       stdout (unchanged). With --http, additionally
        \\                       accepts one JSON-RPC request per HTTP POST
        \\                       body on the given loopback address/port
        \\                       (127.0.0.1 only; refuses any other host).
        \\  demo                 run an in-memory cited hybrid query
        \\  benchmark <docs> <dimensions> <queries> <mode>
        \\                       benchmark the real in-memory engine query path
        \\  init-demo <dir>      publish a small persistent demo snapshot
        \\  import-json <dir> <file>
        \\                       import neutral JSON and publish a snapshot
        \\  help, --help, -h     show this message on stdout (exit 0)
        \\
        \\Vector/hybrid RPC requests must provide a query_vector matching the
        \\embedding dimensions recorded by the snapshot. Lexical mode does not.
        \\`index` never produces vectors (embedding_model_id "none"); its
        \\snapshots only support lexical (BM25) queries.
        \\
        \\Exit status: 0 success; 1 the work failed (a missing folder or
        \\snapshot, an unreadable file); 2 usage error (unknown command or flag,
        \\missing or invalid argument; one line on stderr). A bare `searchd`
        \\prints this text on stderr and exits 2.
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
pub const ImportArgs = struct { snapshot: []const u8, file: []const u8 };
pub const ServeArgs = struct { path: []const u8, http: ?[]const u8 = null };
pub const IndexArgs = struct { folder: []const u8, out: []const u8, options: IndexOptions };
pub const QueryArgs = struct { path: []const u8, text: []const u8, options: QueryOptions };

pub const Command = union(enum) {
    help,
    demo,
    benchmark: BenchmarkArgs,
    init_demo: []const u8,
    import_json: ImportArgs,
    serve: ServeArgs,
    index: IndexArgs,
    query: QueryArgs,
    evidence: QueryArgs,
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

    fn noMoreArguments(self: *Parser, command: []const u8) error{Usage}!void {
        if (self.next()) |extra| return self.usage("unexpected argument for", command, extra, " (see searchd --help)");
    }
};

fn parseQueryFlags(p: *Parser, command: []const u8) error{Usage}!QueryOptions {
    var options = QueryOptions{};
    while (p.next()) |flag| {
        if (std.mem.eql(u8, flag, "--json")) {
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
        try p.noMoreArguments("import-json");
        return .{ .import_json = .{ .snapshot = snapshot, .file = file } };
    }
    if (std.mem.eql(u8, command, "serve")) {
        const path = p.next() orelse return p.missingArgument("serve", "<dir>");
        var http: ?[]const u8 = null;
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
            } else {
                return p.usage("unknown flag for", "serve", flag, " (see searchd --help)");
            }
        }
        return .{ .serve = .{ .path = path, .http = http } };
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
                    return p.usage("invalid value for", "--generation", value, " (expected a non-negative whole number)");
            } else if (std.mem.eql(u8, flag, "--update")) {
                options.update = true;
            } else if (std.mem.eql(u8, flag, "--max-file-bytes")) {
                options.caps.max_file_bytes = try p.byteCount("--max-file-bytes");
            } else if (std.mem.eql(u8, flag, "--max-total-bytes")) {
                options.caps.max_total_bytes = try p.byteCount("--max-total-bytes");
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
        const args = QueryArgs{ .path = path, .text = text, .options = try parseQueryFlags(p, name) };
        return if (is_query) .{ .query = args } else .{ .evidence = args };
    }
    return p.usage("unknown command", "", command, "; try searchd --help");
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
        "indexed {s}: analyzer={s} generation={d} files_indexed={d} too_large={d} unreadable={d} budget_exhausted={d} documents={d} terms={d} postings={d}\n",
        .{ folder_path, report.analyzer_id, report.generation, report.added, report.too_large, report.unreadable, report.budget_exhausted, report.documents, report.terms, report.postings },
    );
}

pub const QueryOptions = struct {
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
    const score_output = try allocator.alloc(f32, engine.documents.len);
    const options = hybrid.SearchOptions{ .top_k = top_k, .candidate_k = @max(top_k, engine.documents.len), .retrieval_mode = .lexical };
    return engine.queryTokenized(allocator, query_text, &.{}, score_output, result_output, options);
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
    const engine = try snapshot_open.open(arena, io, dir);
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
    const engine = try snapshot_open.open(arena, io, dir);
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

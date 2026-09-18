const engine_module = @import("engine.zig");
const benchmark = @import("benchmark.zig");
const chunker = @import("chunker.zig");
const cli = @import("cli.zig");
const hybrid = @import("hybrid.zig");
const importer = @import("importer.zig");
const indexer = @import("indexer.zig");
const lexical_segment = @import("lexical_segment.zig");
const lifecycle = @import("lifecycle.zig");
const manifest = @import("manifest.zig");
const postings = @import("postings.zig");
const publication = @import("publication.zig");
const rpc = @import("rpc.zig");
const segment = @import("segment.zig");
const service_module = @import("service.zig");
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    const command = arguments.next() orelse "help";
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "help")) {
        printHelp();
        return;
    }
    if (std.mem.eql(u8, command, "demo")) {
        try runDemo();
        return;
    }
    if (std.mem.eql(u8, command, "benchmark")) {
        const document_count = try parsePositiveUsize(arguments.next() orelse return error.MissingDocumentCount);
        const dimensions = try parseUsize(arguments.next() orelse return error.MissingDimensions);
        const query_count = try parsePositiveUsize(arguments.next() orelse return error.MissingQueryCount);
        const mode = parseRetrievalMode(arguments.next() orelse return error.MissingRetrievalMode) orelse
            return error.InvalidRetrievalMode;
        try benchmark.run(init.io, init.gpa, document_count, dimensions, query_count, mode);
        return;
    }
    if (std.mem.eql(u8, command, "init-demo")) {
        const path = arguments.next() orelse return error.MissingSnapshotDirectory;
        try initDemoSnapshot(init.io, path);
        return;
    }
    if (std.mem.eql(u8, command, "import-json")) {
        const snapshot_path = arguments.next() orelse return error.MissingSnapshotDirectory;
        const interchange_path = arguments.next() orelse return error.MissingInterchangeFile;
        try importSnapshot(init.io, init.gpa, snapshot_path, interchange_path);
        return;
    }
    if (std.mem.eql(u8, command, "serve")) {
        const path = arguments.next() orelse return error.MissingSnapshotDirectory;
        var http_address: ?[]const u8 = null;
        while (arguments.next()) |flag| {
            if (std.mem.eql(u8, flag, "--http")) {
                http_address = arguments.next() orelse return error.MissingHttpAddress;
            } else {
                std.debug.print("unknown serve flag: {s}\n", .{flag});
                return error.InvalidArgument;
            }
        }
        if (http_address) |address| {
            try serveHttp(init.io, init.gpa, path, address);
        } else {
            try serveSnapshot(init.io, init.gpa, path);
        }
        return;
    }
    if (std.mem.eql(u8, command, "index")) {
        try runIndexCommand(init.io, init.gpa, &arguments);
        return;
    }
    if (std.mem.eql(u8, command, "query")) {
        try runQueryCommand(init.io, init.gpa, &arguments);
        return;
    }
    if (std.mem.eql(u8, command, "evidence")) {
        try runEvidenceCommand(init.io, init.gpa, &arguments);
        return;
    }
    std.debug.print("unknown command: {s}\n", .{command});
    printHelp();
}

fn runIndexCommand(io: std.Io, allocator: std.mem.Allocator, arguments: *std.process.Args.Iterator) !void {
    const folder = arguments.next() orelse return error.MissingFolder;
    var options = cli.IndexOptions{};
    var out_path: ?[]const u8 = null;
    while (arguments.next()) |flag| {
        if (std.mem.eql(u8, flag, "--out")) {
            out_path = arguments.next() orelse return error.MissingOutDirectory;
        } else if (std.mem.eql(u8, flag, "--analyzer")) {
            const value = arguments.next() orelse return error.MissingAnalyzer;
            options.analyzer = indexer.AnalyzerId.parse(value) orelse return error.InvalidAnalyzer;
        } else if (std.mem.eql(u8, flag, "--max-chars")) {
            options.max_chars = try parsePositiveUsize(arguments.next() orelse return error.MissingMaxChars);
        } else if (std.mem.eql(u8, flag, "--overlap-lines")) {
            options.overlap_lines = try parseUsize(arguments.next() orelse return error.MissingOverlapLines);
        } else if (std.mem.eql(u8, flag, "--generation")) {
            options.generation = try std.fmt.parseInt(u64, arguments.next() orelse return error.MissingGeneration, 10);
        } else if (std.mem.eql(u8, flag, "--update")) {
            options.update = true;
        } else if (std.mem.eql(u8, flag, "--max-file-bytes")) {
            options.caps.max_file_bytes = try std.fmt.parseInt(u64, arguments.next() orelse return error.MissingMaxFileBytes, 10);
        } else if (std.mem.eql(u8, flag, "--max-total-bytes")) {
            options.caps.max_total_bytes = try std.fmt.parseInt(u64, arguments.next() orelse return error.MissingMaxTotalBytes, 10);
        } else {
            std.debug.print("unknown index flag: {s}\n", .{flag});
            return error.InvalidArgument;
        }
    }
    const out = out_path orelse return error.MissingOutDirectory;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try cli.runIndex(io, allocator, folder, out, options, &stdout_writer.interface);
    try stdout_writer.flush();
}

fn parseQueryFlags(arguments: *std.process.Args.Iterator) !cli.QueryOptions {
    var options = cli.QueryOptions{};
    while (arguments.next()) |flag| {
        if (std.mem.eql(u8, flag, "--json")) {
            options.json = true;
        } else if (std.mem.eql(u8, flag, "--top-k")) {
            options.top_k = try parsePositiveUsize(arguments.next() orelse return error.MissingTopK);
        } else {
            std.debug.print("unknown query flag: {s}\n", .{flag});
            return error.InvalidArgument;
        }
    }
    return options;
}

fn runQueryCommand(io: std.Io, allocator: std.mem.Allocator, arguments: *std.process.Args.Iterator) !void {
    const path = arguments.next() orelse return error.MissingSnapshotDirectory;
    const query_text = arguments.next() orelse return error.MissingQueryText;
    const options = try parseQueryFlags(arguments);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try cli.runQuery(io, allocator, path, query_text, options, &stdout_writer.interface);
    try stdout_writer.flush();
}

fn runEvidenceCommand(io: std.Io, allocator: std.mem.Allocator, arguments: *std.process.Args.Iterator) !void {
    const path = arguments.next() orelse return error.MissingSnapshotDirectory;
    const query_text = arguments.next() orelse return error.MissingQueryText;
    const options = try parseQueryFlags(arguments);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try cli.runEvidence(io, allocator, path, query_text, options, &stdout_writer.interface);
    try stdout_writer.flush();
}

fn printHelp() void {
    std.debug.print(
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
        \\                       the cap are tombstoned, named in
        \\                       too_large_paths) and the total bytes read
        \\                       in one --update run (files left over count
        \\                       as budget_exhausted, default 10 MiB /
        \\                       512 MiB).
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
        \\  help                 show this message
        \\
        \\Vector/hybrid RPC requests must provide a query_vector matching the
        \\embedding dimensions recorded by the snapshot. Lexical mode does not.
        \\`index` never produces vectors (embedding_model_id "none"); its
        \\snapshots only support lexical (BM25) queries.
        \\
    , .{});
}

fn parseUsize(value: []const u8) !usize {
    return std.fmt.parseInt(usize, value, 10) catch error.InvalidInteger;
}

fn parsePositiveUsize(value: []const u8) !usize {
    const parsed = try parseUsize(value);
    if (parsed == 0) return error.InvalidInteger;
    return parsed;
}

fn parseRetrievalMode(value: []const u8) ?hybrid.RetrievalMode {
    if (std.mem.eql(u8, value, "lexical")) return .lexical;
    if (std.mem.eql(u8, value, "vector")) return .vector;
    if (std.mem.eql(u8, value, "hybrid")) return .hybrid;
    return null;
}

fn importSnapshot(
    io: std.Io,
    allocator: std.mem.Allocator,
    snapshot_path: []const u8,
    interchange_path: []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    var source_file = try cwd.openFile(io, interchange_path, .{});
    const source_stat = try source_file.stat(io);
    source_file.close(io);
    const source_size = std.math.cast(usize, source_stat.size) orelse return error.IndexTooLarge;
    const source_buffer = try allocator.alloc(u8, source_size);
    defer allocator.free(source_buffer);
    const source = try cwd.readFile(io, interchange_path, source_buffer);

    var snapshot_dir = try cwd.createDirPathOpen(io, snapshot_path, .{});
    defer snapshot_dir.close(io);
    const report = try importer.importJson(snapshot_dir, io, allocator, source);
    std.debug.print(
        "imported generation {d}: documents={d} terms={d} postings={d} vector_dimensions={d}\n",
        .{ report.generation, report.documents, report.terms, report.postings, report.vector_dimensions },
    );
}

fn runDemo() !void {
    const documents = demoDocuments();
    var workspace: [documents.len]hybrid.Result = undefined;
    const results = try hybrid.search("hybrid ranking", &.{ 1, 0 }, &documents, &workspace, .{ .top_k = 3, .candidate_k = 2 });

    std.debug.print("query: hybrid ranking\n", .{});
    for (results, 0..) |result, index| {
        std.debug.print("{d}. {s} fused={d:.6}\n", .{ index + 1, result.document_id, result.fused_score });
        std.debug.print("   citation={s}:{d}-{d}\n", .{ result.path, result.start_line, result.end_line });
        if (result.lexical_rank) |rank| {
            std.debug.print("   lexical rank={d} score={d:.6}\n", .{ rank, result.lexical_score });
        }
        if (result.semantic_rank) |rank| {
            std.debug.print("   semantic rank={d} score={d:.6}\n", .{ rank, result.semantic_score });
        }
    }
}

fn initDemoSnapshot(io: std.Io, path: []const u8) !void {
    const documents = demoDocuments();
    var document_storage: [2048]u8 = undefined;
    const documents_encoded = try segment.encode(&documents, &document_storage);
    var terms: [64]postings.TermEntry = undefined;
    var posting_storage: [128]postings.Posting = undefined;
    var lengths: [documents.len]u32 = undefined;
    var fills: [64]usize = undefined;
    const lexical_index = try postings.build(&documents, &terms, &posting_storage, &lengths, &fills);
    var lexical_storage: [4096]u8 = undefined;
    const lexical_encoded = try lexical_segment.encode(lexical_index, &lexical_storage);
    const metadata = try manifest.create(
        1,
        "ascii-alnum-v1",
        "manual-demo-vectors-v1",
        "documents-1.hybseg",
        "lexical-1.hyblex",
        documents_encoded,
        lexical_encoded,
    );
    var manifest_storage: [512]u8 = undefined;
    const manifest_encoded = try manifest.encode(metadata, &manifest_storage);

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{});
    defer dir.close(io);
    try lifecycle.publishSerialized(dir, io, manifest_encoded, documents_encoded, lexical_encoded);
    std.debug.print("published demo generation 1 to {s}\n", .{path});
}

const ServeContext = struct {
    service: service_module.Service,
    workspaces: rpc.Workspaces,
};

fn openServeContext(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !ServeContext {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);

    var manifest_file = try dir.openFile(io, publication.current_manifest_file, .{});
    const manifest_stat = try manifest_file.stat(io);
    manifest_file.close(io);
    const manifest_size = std.math.cast(usize, manifest_stat.size) orelse return error.IndexTooLarge;
    const manifest_buffer = try allocator.alloc(u8, manifest_size);
    const manifest_encoded = try dir.readFile(io, publication.current_manifest_file, manifest_buffer);
    const metadata = try manifest.decode(manifest_encoded);

    const documents_buffer = try allocator.alloc(u8, metadata.documents_bytes);
    const lexical_buffer = try allocator.alloc(u8, metadata.lexical_bytes);
    const snapshot = try publication.loadCurrent(dir, io, manifest_buffer, documents_buffer, lexical_buffer);

    const documents = try allocator.alloc(hybrid.Document, metadata.document_count);
    const vector_count = std.math.mul(usize, metadata.document_count, metadata.vector_dimensions) catch
        return error.IndexTooLarge;
    const vectors = try allocator.alloc(f32, vector_count);
    const terms = try allocator.alloc(postings.TermEntry, metadata.term_count);
    const posting_storage = try allocator.alloc(postings.Posting, metadata.posting_count);
    const document_lengths = try allocator.alloc(u32, metadata.document_count);
    const opened = try engine_module.Engine.open(
        snapshot,
        documents,
        vectors,
        terms,
        posting_storage,
        document_lengths,
    );
    const service = service_module.Service{ .engine = opened };

    const query_vector = try allocator.alloc(f32, metadata.vector_dimensions);
    const lexical_scores = try allocator.alloc(f32, metadata.document_count);
    const results = try allocator.alloc(hybrid.Result, metadata.document_count);
    const evidence = try allocator.alloc(engine_module.Evidence, metadata.document_count);
    const sources = try allocator.alloc(service_module.Source, metadata.document_count);
    const workspaces = rpc.Workspaces{
        .query_vector = query_vector,
        .lexical_scores = lexical_scores,
        .results = results,
        .evidence = evidence,
        .sources = sources,
    };
    return .{ .service = service, .workspaces = workspaces };
}

fn serveSnapshot(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const context = try openServeContext(io, arena_state.allocator(), path);

    const request_buffer = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(request_buffer);
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, request_buffer);
    const response_buffer = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(response_buffer);
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, response_buffer);

    while (try stdin_reader.interface.takeDelimiter('\n')) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        try rpc.handleLine(context.service, line, arena.allocator(), context.workspaces, &stdout_writer.interface);
        try stdout_writer.interface.writeByte('\n');
        try stdout_writer.flush();
    }
}

/// `serve <dir> --http 127.0.0.1:<port>`: a minimal, loopback-only HTTP
/// front end over the same JSON-RPC handler as stdio `serve`. One
/// connection at a time (accept, read exactly one request, write exactly
/// one response, close); enough to let a local tool or browser issue a
/// request without opening a stdio pipe, without taking on a concurrent
/// server's complexity for a task about indexing, not serving. Only
/// 127.0.0.1 is accepted (an explicit host check, not just bind-address
/// discipline), matching the task's "local only" requirement.
fn serveHttp(io: std.Io, allocator: std.mem.Allocator, path: []const u8, address_text: []const u8) !void {
    const colon = std.mem.lastIndexOfScalar(u8, address_text, ':') orelse return error.InvalidHttpAddress;
    const host = address_text[0..colon];
    if (!std.mem.eql(u8, host, "127.0.0.1") and !std.mem.eql(u8, host, "localhost")) {
        std.debug.print("refusing non-loopback --http host: {s} (only 127.0.0.1/localhost are allowed)\n", .{host});
        return error.NonLoopbackHttpHost;
    }
    const port = try std.fmt.parseInt(u16, address_text[colon + 1 ..], 10);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const context = try openServeContext(io, arena_state.allocator(), path);

    var loopback = std.Io.net.IpAddress.fromIp6(std.Io.net.Ip6Address.fromIp4(std.Io.net.Ip4Address.loopback(port)));
    var server = try loopback.listen(io, .{});
    defer server.deinit(io);
    std.debug.print("serving http://127.0.0.1:{d} (POST a JSON-RPC request body to any path)\n", .{port});

    while (true) {
        var stream = server.accept(io) catch |err| {
            std.debug.print("accept failed: {t}\n", .{err});
            continue;
        };
        defer stream.close(io);
        handleHttpConnection(io, allocator, context, stream) catch |err| {
            std.debug.print("http connection error: {t}\n", .{err});
        };
    }
}

fn handleHttpConnection(
    io: std.Io,
    allocator: std.mem.Allocator,
    context: ServeContext,
    stream: std.Io.net.Stream,
) !void {
    var read_buffer: [64 * 1024]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buffer);
    var write_buffer: [64 * 1024]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buffer);

    // Minimal request parse: read the header block, pull Content-Length,
    // then read exactly that many body bytes. No keep-alive, no chunked
    // transfer encoding, no routing by path -- any method/path with a
    // JSON-RPC body works, matching this server's single purpose.
    const header_end = try stream_reader.interface.takeDelimiterInclusive('\n');
    _ = header_end; // request line, ignored (method/path/version not inspected)
    var content_length: usize = 0;
    while (true) {
        const header_line = stream_reader.interface.takeDelimiterInclusive('\n') catch break;
        const trimmed = std.mem.trim(u8, header_line, " \t\r\n");
        if (trimmed.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
            const value = std.mem.trim(u8, trimmed["content-length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, value, 10) catch 0;
        }
    }

    var response_storage: [64 * 1024]u8 = undefined;
    var response_writer = std.Io.Writer.fixed(&response_storage);
    if (content_length == 0 or content_length > read_buffer.len) {
        try response_writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}");
    } else {
        const body = try allocator.alloc(u8, content_length);
        defer allocator.free(body);
        try stream_reader.interface.readSliceAll(body);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        try rpc.handleLine(context.service, body, arena.allocator(), context.workspaces, &response_writer);
    }
    const body_written = response_writer.buffered();

    try stream_writer.interface.print(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{body_written.len},
    );
    try stream_writer.interface.writeAll(body_written);
    try stream_writer.interface.flush();
}

fn demoDocuments() [3]hybrid.Document {
    return .{
        .{ .id = "hybrid-guide", .text = "hybrid retrieval combines lexical and semantic ranks with reciprocal rank fusion", .vector = &.{ 0.9, 0.1 }, .path = "guides/hybrid.md", .start_line = 1, .end_line = 6 },
        .{ .id = "lexical-guide", .text = "BM25 is an exact lexical ranking function", .vector = &.{ 0.1, 0.9 }, .path = "guides/lexical.md", .start_line = 10, .end_line = 12 },
        .{ .id = "semantic-guide", .text = "meaning based retrieval finds paraphrases", .vector = &.{ 1, 0 }, .path = "guides/semantic.md", .start_line = 20, .end_line = 22 },
    };
}

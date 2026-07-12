const engine_module = @import("engine.zig");
const benchmark = @import("benchmark.zig");
const hybrid = @import("hybrid.zig");
const importer = @import("importer.zig");
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
        try serveSnapshot(init.io, init.gpa, path);
        return;
    }
    std.debug.print("unknown command: {s}\n", .{command});
    printHelp();
}

fn printHelp() void {
    std.debug.print(
        \\searchd — Zig hybrid search engine
        \\
        \\Commands:
        \\  demo                 run an in-memory cited hybrid query
        \\  benchmark <docs> <dimensions> <queries> <mode>
        \\                       benchmark the real in-memory engine query path
        \\  init-demo <dir>      publish a small persistent demo snapshot
        \\  import-json <dir> <file>
        \\                       import neutral JSON and publish a snapshot
        \\  serve <dir>          serve JSON-RPC 2.0 requests on stdin/stdout
        \\  help                 show this message
        \\
        \\Vector/hybrid RPC requests must provide a query_vector matching the
        \\embedding dimensions recorded by the snapshot. Lexical mode does not.
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

fn serveSnapshot(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);

    var manifest_file = try dir.openFile(io, publication.current_manifest_file, .{});
    const manifest_stat = try manifest_file.stat(io);
    manifest_file.close(io);
    const manifest_size = std.math.cast(usize, manifest_stat.size) orelse return error.IndexTooLarge;
    const manifest_buffer = try allocator.alloc(u8, manifest_size);
    defer allocator.free(manifest_buffer);
    const manifest_encoded = try dir.readFile(io, publication.current_manifest_file, manifest_buffer);
    const metadata = try manifest.decode(manifest_encoded);

    const documents_buffer = try allocator.alloc(u8, metadata.documents_bytes);
    defer allocator.free(documents_buffer);
    const lexical_buffer = try allocator.alloc(u8, metadata.lexical_bytes);
    defer allocator.free(lexical_buffer);
    const snapshot = try publication.loadCurrent(dir, io, manifest_buffer, documents_buffer, lexical_buffer);

    const documents = try allocator.alloc(hybrid.Document, metadata.document_count);
    defer allocator.free(documents);
    const vector_count = std.math.mul(usize, metadata.document_count, metadata.vector_dimensions) catch
        return error.IndexTooLarge;
    const vectors = try allocator.alloc(f32, vector_count);
    defer allocator.free(vectors);
    const terms = try allocator.alloc(postings.TermEntry, metadata.term_count);
    defer allocator.free(terms);
    const posting_storage = try allocator.alloc(postings.Posting, metadata.posting_count);
    defer allocator.free(posting_storage);
    const document_lengths = try allocator.alloc(u32, metadata.document_count);
    defer allocator.free(document_lengths);
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
    defer allocator.free(query_vector);
    const lexical_scores = try allocator.alloc(f32, metadata.document_count);
    defer allocator.free(lexical_scores);
    const results = try allocator.alloc(hybrid.Result, metadata.document_count);
    defer allocator.free(results);
    const evidence = try allocator.alloc(engine_module.Evidence, metadata.document_count);
    defer allocator.free(evidence);
    const sources = try allocator.alloc(service_module.Source, metadata.document_count);
    defer allocator.free(sources);
    const workspaces = rpc.Workspaces{
        .query_vector = query_vector,
        .lexical_scores = lexical_scores,
        .results = results,
        .evidence = evidence,
        .sources = sources,
    };

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
        try rpc.handleLine(service, line, arena.allocator(), workspaces, &stdout_writer.interface);
        try stdout_writer.interface.writeByte('\n');
        try stdout_writer.flush();
    }
}

fn demoDocuments() [3]hybrid.Document {
    return .{
        .{ .id = "hybrid-guide", .text = "hybrid retrieval combines lexical and semantic ranks with reciprocal rank fusion", .vector = &.{ 0.9, 0.1 }, .path = "guides/hybrid.md", .start_line = 1, .end_line = 6 },
        .{ .id = "lexical-guide", .text = "BM25 is an exact lexical ranking function", .vector = &.{ 0.1, 0.9 }, .path = "guides/lexical.md", .start_line = 10, .end_line = 12 },
        .{ .id = "semantic-guide", .text = "meaning based retrieval finds paraphrases", .vector = &.{ 1, 0 }, .path = "guides/semantic.md", .start_line = 20, .end_line = 22 },
    };
}

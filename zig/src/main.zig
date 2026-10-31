const generation_alloc = @import("generation_alloc.zig");
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
    // Every argument is judged by `cli.parseArgs` (S1-T8 criterion 1); this
    // function only prints what it returns and exits.
    var collected: std.ArrayList([]const u8) = .empty;
    defer collected.deinit(init.gpa);
    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    while (arguments.next()) |argument| try collected.append(init.gpa, argument);

    var message_buffer: [512]u8 = undefined;
    switch (cli.parseArgs(collected.items, &message_buffer)) {
        .usage_error => |usage| {
            std.debug.print("{s}", .{usage.message});
            std.process.exit(usage.status);
        },
        .help => try printHelp(init.io),
        .demo => try runDemo(),
        .benchmark => |b| try benchmark.run(init.io, init.gpa, b.documents, b.dimensions, b.queries, b.mode),
        .init_demo => |path| try initDemoSnapshot(init.io, path),
        .import_json => |i| try importSnapshot(init.io, init.gpa, i.snapshot, i.file, i.keep_generations),
        .serve => |s| if (s.http) |address|
            try serveHttp(init.io, init.gpa, s, address)
        else
            try serveSnapshot(init.io, init.gpa, s),
        .index => |i| {
            var stdout_buffer: [4096]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
            cli.runIndex(init.io, init.gpa, i.folder, i.out, i.options, &stdout_writer.interface) catch |err| {
                if (err == error.NoFreeGeneration) {
                    var line_buffer: [384]u8 = undefined;
                    std.debug.print("error: {s}\n", .{generation_alloc.describeNoFreeGeneration(&line_buffer)});
                    std.process.exit(1);
                }
                return err;
            };
            try stdout_writer.flush();
        },
        .query => |q| {
            var stdout_buffer: [8192]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
            try cli.runQuery(init.io, init.gpa, q.path, q.text, q.options, &stdout_writer.interface);
            try stdout_writer.flush();
        },
        .evidence => |q| {
            var stdout_buffer: [8192]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
            try cli.runEvidence(init.io, init.gpa, q.path, q.text, q.options, &stdout_writer.interface);
            try stdout_writer.flush();
        },
        // S3-T4: the folder-knowledge commands; 1 after a refusal's stderr line.
        .find => |a| try runFolderCommand(init, a, cli.runFind),
        .outline => |a| try runFolderCommand(init, a, cli.runOutline),
        .read_span => |a| try runFolderCommand(init, a, cli.runReadSpan),
        .list_files => |a| try runFolderCommand(init, a, cli.runListFiles),
        .roots => |a| try runFolderCommand(init, a, cli.runRoots),
        .apply => |a| try runFolderCommand(init, a, cli.runApply),
    }
}

fn runFolderCommand(init: std.process.Init, args: anytype, comptime run: anytype) !void {
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);
    const status = try run(init.io, init.gpa, args, &stdout_writer.interface, &stderr_writer.interface);
    try stdout_writer.flush();
    try stderr_writer.flush();
    if (status != 0) std.process.exit(status);
}

/// `--help` goes to stdout and exits 0 (S1-T8 criterion 3).
fn printHelp(io: std.Io) !void {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    try writer.interface.writeAll(cli.usage_text);
    try writer.flush();
}

fn importSnapshot(
    io: std.Io,
    allocator: std.mem.Allocator,
    snapshot_path: []const u8,
    interchange_path: []const u8,
    keep_generations: ?usize,
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
    const report = try importer.importJsonKeeping(snapshot_dir, io, allocator, source, keep_generations);
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

/// S3-T4: the served generation with its scope data (roots, statistics,
/// source section; a lost source section does not fail it), from `allocator`.
fn openServeContext(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !ServeContext {
    const service = try cli.openService(allocator, io, path);
    const document_count = service.engine.documents.len;
    const workspaces = rpc.Workspaces{
        .query_vector = try allocator.alloc(f32, service.engine.vector_dimensions),
        .results = try allocator.alloc(hybrid.Result, document_count),
        .evidence = try allocator.alloc(engine_module.Evidence, document_count),
        .sources = try allocator.alloc(service_module.Source, document_count),
    };
    return .{ .service = service, .workspaces = workspaces };
}

/// The server's scope and permissions from the command line (S3-T4).
fn serverOf(io: std.Io, allocator: std.mem.Allocator, args: cli.ServeArgs) !rpc.Server {
    var server = rpc.Server{
        .allow_write = args.allow_write,
        .allow_file_reads = args.allow_file_reads,
        .dir_path = args.path,
        .io = io,
    };
    if (args.roots) |text| server.caller.roots = try splitList(allocator, text);
    if (args.labels) |text| {
        server.caller.labels = try splitList(allocator, text);
        server.caller.request_labels = false;
    }
    return server;
}

fn splitList(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var items = std.ArrayList([]const u8).empty;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |part| try items.append(allocator, part);
    return items.items;
}

/// Answers one request, then reopens the index after a successful
/// `apply_changes` so the next request reads the new generation.
const Served = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    server: rpc.Server,
    arena: std.heap.ArenaAllocator,
    context: ServeContext,

    /// In place: the context is allocated from `served.arena`, which must
    /// not move afterwards.
    fn init(served: *Served, io: std.Io, allocator: std.mem.Allocator, args: cli.ServeArgs, scope_arena: std.mem.Allocator) !void {
        served.io = io;
        served.allocator = allocator;
        served.path = args.path;
        served.server = try serverOf(io, scope_arena, args);
        served.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer served.arena.deinit();
        served.context = try openServeContext(io, served.arena.allocator(), args.path);
    }

    fn handle(served: *Served, line: []const u8, output: *std.Io.Writer) !void {
        var request_arena = std.heap.ArenaAllocator.init(served.allocator);
        defer request_arena.deinit();
        served.server.reopen = false;
        try rpc.handleLineWith(served.context.service, &served.server, line, request_arena.allocator(), served.context.workspaces, output);
        if (served.server.reopen) {
            // The old generation stays served until the new one is open.
            const next = try served.allocator.create(std.heap.ArenaAllocator);
            defer served.allocator.destroy(next);
            next.* = std.heap.ArenaAllocator.init(served.allocator);
            const context = openServeContext(served.io, next.allocator(), served.path) catch |err| {
                next.deinit();
                return err;
            };
            served.arena.deinit();
            // Every allocation of `next` is done: moving its state is safe.
            served.arena = next.*;
            served.context = context;
        }
    }

    fn deinit(served: *Served) void {
        served.arena.deinit();
    }
};

fn serveSnapshot(io: std.Io, allocator: std.mem.Allocator, args: cli.ServeArgs) !void {
    var scope_arena = std.heap.ArenaAllocator.init(allocator);
    defer scope_arena.deinit();
    var served: Served = undefined;
    try served.init(io, allocator, args, scope_arena.allocator());
    defer served.deinit();

    const request_buffer = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(request_buffer);
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, request_buffer);
    const response_buffer = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(response_buffer);
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, response_buffer);

    while (try stdin_reader.interface.takeDelimiter('\n')) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        try served.handle(line, &stdout_writer.interface);
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
fn serveHttp(io: std.Io, allocator: std.mem.Allocator, args: cli.ServeArgs, address_text: []const u8) !void {
    // `cli.parseArgs` already judged the address (loopback host, numeric port).
    const colon = std.mem.lastIndexOfScalar(u8, address_text, ':').?;
    const port = cli.parseDigits(u16, address_text[colon + 1 ..]).?;

    var scope_arena = std.heap.ArenaAllocator.init(allocator);
    defer scope_arena.deinit();
    var served: Served = undefined;
    try served.init(io, allocator, args, scope_arena.allocator());
    defer served.deinit();

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
        handleHttpConnection(io, allocator, &served, stream) catch |err| {
            std.debug.print("http connection error: {t}\n", .{err});
        };
    }
}

fn handleHttpConnection(
    io: std.Io,
    allocator: std.mem.Allocator,
    served: *Served,
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

    // S3-T4: a read_span answer can hold 256 KiB of text, so the response
    // grows as needed instead of a fixed 64 KiB buffer.
    var response: std.Io.Writer.Allocating = .init(allocator);
    defer response.deinit();
    const response_writer = &response.writer;
    if (content_length == 0 or content_length > read_buffer.len) {
        try response_writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}");
    } else {
        const body = try allocator.alloc(u8, content_length);
        defer allocator.free(body);
        try stream_reader.interface.readSliceAll(body);
        try served.handle(body, response_writer);
    }
    const body_written = response.written();

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

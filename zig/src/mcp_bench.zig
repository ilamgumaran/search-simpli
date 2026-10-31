//! S3-T6 timing tool (section 13 profile): the direct Zig call that the MCP
//! adapter's overhead is measured against.
//!
//!     zig run -OReleaseSmall zig/src/mcp_bench.zig -- INDEX_DIR REQUESTS ROUNDS
//!
//! REQUESTS is a file of JSON lines `{"tool": "find" | "search_knowledge",
//! "arguments": {…}}` (written by `scripts/mcp_overhead.py`). The index is
//! opened as `searchd mcp` opens it (`snapshot_open.openScoped`, the default
//! scope); each request's arguments are parsed once, then every round calls
//! `ops.find` / `ops.searchKnowledge` (request object → canonical JSON, the
//! work the MCP server hands to the same functions) in an arena reset
//! between calls. 5 warm-up rounds, then ROUNDS timed rounds; prints one
//! line per timed call, `<round> <request> <nanoseconds>`. Not part of any
//! library or the build graph.
const std = @import("std");
const engine_module = @import("engine.zig");
const hybrid = @import("hybrid.zig");
const ops = @import("ops.zig");
const service_module = @import("service.zig");
const snapshot_open = @import("snapshot_open.zig");

const warmups = 5;

const Request = struct { tool: []const u8, arguments: std.json.ObjectMap };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const dir_path = args.next() orelse return error.MissingIndexDir;
    const requests_path = args.next() orelse return error.MissingRequests;
    const rounds = try std.fmt.parseInt(usize, args.next() orelse return error.MissingRounds, 10);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    const opened = try snapshot_open.openScoped(arena, io, dir);
    const service = service_module.Service{ .engine = opened.engine, .folder = opened.folder };
    const count = service.engine.documents.len;
    const workspaces = ops.Workspaces{
        .query_vector = try arena.alloc(f32, service.engine.vector_dimensions),
        .results = try arena.alloc(hybrid.Result, count),
        .evidence = try arena.alloc(engine_module.Evidence, count),
        .sources = try arena.alloc(service_module.Source, count),
    };

    const text = try std.Io.Dir.cwd().readFileAlloc(io, requests_path, arena, .limited(64 * 1024 * 1024));
    var requests = std.ArrayList(Request).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
        try requests.append(arena, .{ .tool = value.object.get("tool").?.string, .arguments = value.object.get("arguments").?.object });
    }

    var call_arena = std.heap.ArenaAllocator.init(gpa);
    defer call_arena.deinit();
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    for (0..warmups + rounds) |round| {
        for (requests.items, 0..) |request, index| {
            _ = call_arena.reset(.retain_capacity);
            const a = call_arena.allocator();
            const start = std.Io.Clock.awake.now(io).nanoseconds;
            const result = if (std.mem.eql(u8, request.tool, "find"))
                try ops.find(a, service, request.arguments, .{})
            else
                try ops.searchKnowledge(a, service, request.arguments, .{}, workspaces);
            const elapsed = std.Io.Clock.awake.now(io).nanoseconds - start;
            if (result != .ok) return error.RequestRefused;
            if (round >= warmups) try stdout.interface.print("{d} {d} {d}\n", .{ round - warmups, index, elapsed });
        }
    }
    try stdout.interface.flush();
}

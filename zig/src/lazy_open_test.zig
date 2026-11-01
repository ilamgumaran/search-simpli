//! S4-T1 ruling 1: a lazy scoped open. `snapshot_open.openScoped` (and so
//! `ss_open`, `searchd serve`/`mcp` and the CLI's scoped commands) loads
//! what `index_status` needs; the source section, the statistics groups and
//! the position tables load at first use, once per opened generation, and
//! a second caller during a load waits for it.
const std = @import("std");
const chunker = @import("chunker.zig");
const find_module = @import("find.zig");
const indexer = @import("indexer.zig");
const scope = @import("scope.zig");
const service_module = @import("service.zig");
const snapshot_open = @import("snapshot_open.zig");
const source = @import("source.zig");

const io = std.testing.io;

const Indexed = struct {
    arena_state: std.heap.ArenaAllocator,
    folder_tmp: std.testing.TmpDir,
    out_tmp: std.testing.TmpDir,

    fn init() !Indexed {
        var indexed = Indexed{
            .arena_state = std.heap.ArenaAllocator.init(std.testing.allocator),
            .folder_tmp = std.testing.tmpDir(.{ .iterate = true }),
            .out_tmp = std.testing.tmpDir(.{ .iterate = true }),
        };
        errdefer indexed.deinit();
        try indexed.folder_tmp.dir.writeFile(io, .{ .sub_path = "week.md", .data = "# Week\n\nThe tide table for the harbour walk.\n\n## Friday\n\nBring the blue folder.\n" });
        try indexed.folder_tmp.dir.writeFile(io, .{ .sub_path = "list.txt", .data = "flour\neggs\nthe blue folder\n" });
        _ = try indexer.indexFolderIncremental(indexed.arena(), io, indexed.folder_tmp.dir, indexed.out_tmp.dir, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{});
        return indexed;
    }

    fn deinit(indexed: *Indexed) void {
        indexed.out_tmp.cleanup();
        indexed.folder_tmp.cleanup();
        indexed.arena_state.deinit();
    }

    fn arena(indexed: *Indexed) std.mem.Allocator {
        return indexed.arena_state.allocator();
    }
};

test "S4-T1: the scoped open defers the source, the statistics and the position tables to their first use" {
    var indexed = try Indexed.init();
    defer indexed.deinit();
    const a = indexed.arena();
    const opened = try snapshot_open.openScoped(a, io, indexed.out_tmp.dir);
    defer opened.folder.close();
    const loads = opened.folder.loads;
    const scoped = service_module.ScopedService{ .service = .{ .engine = opened.engine, .folder = opened.folder } };

    // After the open: nothing loaded, and index_status loads nothing.
    try std.testing.expectEqual(scope.SourceState.unverified, opened.folder.sourceState());
    try std.testing.expect(opened.folder.loadedStatistics() == null);
    try std.testing.expect(opened.engine.statistics == null and opened.engine.position_tables == null);
    const status = try scoped.indexStatus(a, .{});
    try std.testing.expectEqualStrings("unverified", status.source);
    try std.testing.expect(status.has_source);
    try std.testing.expectEqual(@as(usize, 2), status.files);
    try std.testing.expectEqual(@as(u32, 0), loads.source_loads + loads.statistics_loads + loads.positions_loads);

    // The first find builds the statistics and the position tables, not the source.
    switch (try scoped.find(a, .{ .query = "blue folder", .mode = .phrase }, .{})) {
        .ok => |answer| try std.testing.expectEqual(@as(usize, 2), answer.hits.len),
        .failed => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(u32, 1), loads.statistics_loads);
    try std.testing.expectEqual(@as(u32, 1), loads.positions_loads);
    try std.testing.expectEqual(@as(u32, 0), loads.source_loads);
    try std.testing.expectEqual(scope.SourceState.unverified, opened.folder.sourceState());

    // The first read_span loads and verifies the source; later calls reuse everything.
    const span = (try scoped.readSpan(a, .{}, "r-legacy", "week.md", 3, 3, 0)).ok;
    try std.testing.expectEqualStrings("The tide table for the harbour walk.\n", span.text);
    try std.testing.expectEqual(scope.SourceState.verified, opened.folder.sourceState());
    try std.testing.expectEqualStrings("verified", (try scoped.indexStatus(a, .{})).source);
    _ = try scoped.outline(a, .{}, "r-legacy", "week.md");
    _ = try scoped.find(a, .{ .query = "tide" }, .{});
    _ = try scoped.searchKnowledge(a, "harbour", &.{}, .{ .retrieval_mode = .lexical }, .{}, try a.alloc(@import("hybrid.zig").Result, 4), try a.alloc(@import("engine.zig").Evidence, 4), null);
    try std.testing.expectEqual(@as(u32, 1), loads.source_loads);
    try std.testing.expectEqual(@as(u32, 1), loads.statistics_loads);
    try std.testing.expectEqual(@as(u32, 1), loads.positions_loads);
}

test "S4-T1: the lazy open answers every operation exactly as the eager open did" {
    var indexed = try Indexed.init();
    defer indexed.deinit();
    const a = indexed.arena();
    const lazy = try snapshot_open.openScoped(a, io, indexed.out_tmp.dir);
    defer lazy.folder.close();
    const eager_engine = try snapshot_open.open(a, io, indexed.out_tmp.dir);
    const scoped = service_module.ScopedService{ .service = .{ .engine = lazy.engine, .folder = lazy.folder } };
    // `find` over the lazy service equals `find` over the eagerly opened
    // engine (positions validated and tables built at open).
    for ([_]find_module.Mode{ .words, .phrase, .prefix }) |mode| {
        const query: []const u8 = if (mode == .prefix) "fold*" else "blue folder";
        const from_lazy = (try scoped.find(a, .{ .query = query, .mode = mode }, .{})).ok;
        const from_eager = (try find_module.find(a, eager_engine, .{ .query = query, .mode = mode })).ok;
        try std.testing.expectEqual(from_eager.hits.len, from_lazy.hits.len);
        for (from_eager.hits, from_lazy.hits) |e, l| {
            try std.testing.expectEqualStrings(e.chunk_id, l.chunk_id);
            try std.testing.expectEqual(e.score, l.score);
            try std.testing.expectEqualStrings(e.snippet, l.snippet);
        }
    }
    const section = (try snapshot_open.openSource(a, io, indexed.out_tmp.dir)).source.?;
    const lazy_section = (try lazy.folder.sourceSection()).?;
    try std.testing.expectEqualSlices(u8, section.encoded, lazy_section.encoded);
}

const Racer = struct {
    folder: *const scope.Folder,
    sections: [*]?source.Section,
    statistics: [*]*const scope.Statistics,
    failed: *std.atomic.Value(bool),

    fn run(racer: Racer, slot: usize) void {
        racer.sections[slot] = racer.folder.sourceSection() catch return racer.failed.store(true, .release);
        racer.statistics[slot] = racer.folder.statistics() catch return racer.failed.store(true, .release);
        _ = racer.folder.positionTables() catch return racer.failed.store(true, .release);
    }
};

test "S4-T1: concurrent first uses load each table once and see the same tables" {
    var indexed = try Indexed.init();
    defer indexed.deinit();
    const a = indexed.arena();
    const opened = try snapshot_open.openScoped(a, io, indexed.out_tmp.dir);
    defer opened.folder.close();
    const thread_count = 8;
    var sections: [thread_count]?source.Section = undefined;
    var statistics: [thread_count]*const scope.Statistics = undefined;
    var failed = std.atomic.Value(bool).init(false);
    const racer = Racer{ .folder = opened.folder, .sections = &sections, .statistics = &statistics, .failed = &failed };
    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, slot| thread.* = try std.Thread.spawn(.{}, Racer.run, .{ racer, slot });
    for (threads) |thread| thread.join();
    try std.testing.expect(!failed.load(.acquire));
    const loads = opened.folder.loads;
    try std.testing.expectEqual(@as(u32, 1), loads.source_loads);
    try std.testing.expectEqual(@as(u32, 1), loads.statistics_loads);
    try std.testing.expectEqual(@as(u32, 1), loads.positions_loads);
    for (sections, statistics) |section, stats| {
        try std.testing.expectEqual(sections[0].?.encoded.ptr, section.?.encoded.ptr);
        try std.testing.expectEqual(statistics[0], stats);
    }
}

//! Deterministic S4-T2 follow-up: filename queries use decoded anchors,
//! not a scan of the body records. Guard actual memory access, not timing.
const std = @import("std");
const builtin = @import("builtin");
const field = @import("filename_field.zig");
const hybrid = @import("hybrid.zig");
const lexical_build = @import("lexical_build.zig");
const analyzer = @import("analyzer_v2.zig");

const Fixture = struct {
    body: []hybrid.Document,
    index: @import("postings.zig").Index,
    decoded: field.Decoded,
    roots: []u16,

    fn init(a: std.mem.Allocator, files: usize, labelled: bool) !Fixture {
        const body = try a.alloc(hybrid.Document, files * 2);
        const roots = try a.alloc(u16, body.len);
        const tokens = try a.alloc([][]const u8, body.len);
        for (0..files) |i| {
            // Reverse body order so catalog ordinals cannot stand in for
            // body ordinals. Two chunks per file exercise best-chunk grouping.
            const file = files - i - 1;
            const private = file % 3 == 0;
            const path = try std.fmt.allocPrint(a, "{s}/common_file_{d:0>5}.md", .{ if (private) @as([]const u8, "private") else "public", file });
            for (0..2) |chunk| {
                const slot = i * 2 + chunk;
                body[slot] = .{
                    .id = try std.fmt.allocPrint(a, "id-{d}-{d}", .{ file, chunk }),
                    .path = path,
                    .text = if (chunk == 0) "common body evidence" else "common common body evidence",
                    .start_line = @intCast(1 + chunk * 10),
                    .end_line = @intCast(3 + chunk * 10),
                    .required_labels = if (private and labelled) "family" else "",
                };
                roots[slot] = if (private) 1 else 0;
                tokens[slot] = try analyzer.tokenize(a, body[slot].text);
            }
        }
        const index = try lexical_build.build(a, body, tokens);
        const built = try field.build(a, body, analyzer.analyzer_id);
        var decoded = try field.decode(a, body, index, built.catalog, built.lexical);
        decoded.max_document_root = 1;
        try field.validateDecoded(a, decoded, analyzer.analyzer_id);
        return .{ .body = body, .index = index, .decoded = decoded, .roots = roots };
    }
};

fn scopes(f: Fixture) [5]hybrid.SearchOptions {
    const base = hybrid.SearchOptions{ .retrieval_mode = .lexical, .top_k = 17, .candidate_k = 31 };
    var all_labels = base;
    all_labels.principal_labels = &.{"family"};
    var root_only = all_labels;
    root_only.visible_roots = .{ .document_roots = f.roots, .allowed = &.{ true, false } };
    var prefix = all_labels;
    prefix.path_prefix = "private/";
    var all_roots = all_labels;
    all_roots.visible_roots = .{ .document_roots = f.roots, .allowed = &.{ true, true } };
    return .{ base, all_labels, root_only, prefix, all_roots };
}

fn checkResults(f: Fixture, hits: []const field.Hit, mode: field.Field, options: hybrid.SearchOptions) !void {
    try std.testing.expectEqual(options.top_k, hits.len);
    for (hits, 0..) |hit, i| {
        try std.testing.expect(hybrid.inScope(f.body[hit.document_index], hit.document_index, options));
        try std.testing.expect(hit.filename_rank != null);
        try std.testing.expect(hit.filename_rank.? <= options.candidate_k);
        if (mode == .both) {
            try std.testing.expect(hit.body_rank != null);
            try std.testing.expect(hit.body_rank.? <= options.candidate_k);
        } else try std.testing.expect(hit.body_rank == null);
        for (hits[0..i]) |previous| try std.testing.expect(!std.mem.eql(u8, f.body[previous.document_index].path, f.body[hit.document_index].path));
    }
}

test "filename query complexity: decoded anchors need zero body-record reads at 1k and 10k" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    for ([_]usize{ 1_000, 10_000 }) |files| for ([_]bool{ false, true }) |labelled| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const f = try Fixture.init(a, files, labelled);
        const size = std.mem.alignForward(usize, f.body.len * @sizeOf(hybrid.Document), std.heap.pageSize());
        const memory = try std.posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        defer std.posix.munmap(memory);
        const guarded = @as([*]hybrid.Document, @ptrCast(@alignCast(memory.ptr)))[0..f.body.len];
        @memcpy(guarded, f.body);
        // Any actual body-array scan now fails at its first read. The decoded
        // catalog, anchors, term dictionary and root-mask table remain readable.
        try std.testing.expectEqual(@as(c_int, 0), std.c.mprotect(@ptrCast(@alignCast(memory.ptr)), memory.len, .{}));
        for (scopes(f)) |options| {
            const expected = try field.queryDecoded(a, f.body, f.index, f.decoded, analyzer.analyzer_id, "common common", .filename, options);
            const actual = try field.queryDecoded(a, guarded, f.index, f.decoded, analyzer.analyzer_id, "common common", .filename, options);
            try checkResults(f, actual, .filename, options);
            try std.testing.expectEqualSlices(field.Hit, expected, actual);
        }
    };
}

test "filename query complexity: broad filename and both queries keep linear scratch at 1k and 10k" {
    for ([_]usize{ 1_000, 10_000 }) |files| for ([_]bool{ false, true }) |labelled| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const f = try Fixture.init(a, files, labelled);
        // A generous linear envelope covers score/visibility arrays, touched
        // lists, candidates and fixed top-k fusion. It is not an RSS budget.
        const scratch = try a.alloc(u8, files * 1024 + 64 * 1024);
        for ([_]field.Field{ .filename, .both }) |mode| for (scopes(f)) |options| {
            var bounded = std.heap.FixedBufferAllocator.init(scratch);
            const hits = try field.queryDecoded(bounded.allocator(), f.body, f.index, f.decoded, analyzer.analyzer_id, "common common", mode, options);
            try checkResults(f, hits, mode, options);
        };
    };
}

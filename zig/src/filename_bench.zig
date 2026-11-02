//! Bounded, opt-in filename scaling diagnostic; no wall-clock CI gate.
//! zig run -lc -OReleaseSmall zig/src/filename_bench.zig -- INDEX [QUERY] [CAP_MIB]
//! Use the same generated corpus at 1k/10k/15k/20k; report failures too.
const std = @import("std");
const snapshot = @import("snapshot_open.zig");
const field = @import("filename_field.zig");
const Capped = @import("nfr13_arena_test.zig").Capped;

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const path = args.next() orelse return error.MissingIndex;
    const query = args.next() orelse "doc";
    const cap_mib = try std.fmt.parseInt(usize, args.next() orelse "64", 10);
    const cap = try std.math.mul(usize, cap_mib, 1024 * 1024);
    var bounded = Capped{ .parent = init.gpa, .cap = cap };
    var arena = std.heap.ArenaAllocator.init(bounded.allocator());
    defer arena.deinit();
    var dir = try std.Io.Dir.cwd().openDir(init.io, path, .{});
    defer dir.close(init.io);
    const start = std.Io.Clock.awake.now(init.io).nanoseconds;
    const opened = snapshot.openScoped(arena.allocator(), init.io, dir) catch |err| {
        std.debug.print("{{\"stage\":\"open\",\"error\":\"{s}\",\"cap_bytes\":{d},\"peak_bytes\":{d}}}\n", .{ @errorName(err), cap, bounded.peak });
        return err;
    };
    defer opened.folder.close();
    if (!opened.engine.filename_index_enabled) return error.FilenameIndexUnavailable;
    const open_ns = std.Io.Clock.awake.now(init.io).nanoseconds - start;
    for ([_]field.Field{ .filename, .both }) |mode| {
        var samples: [20]u64 = undefined;
        bounded.peak = bounded.live;
        for (0..25) |i| {
            var request = std.heap.ArenaAllocator.init(bounded.allocator());
            defer request.deinit();
            const before = std.Io.Clock.awake.now(init.io).nanoseconds;
            const hits = opened.engine.queryFields(request.allocator(), query, mode, .{ .retrieval_mode = .lexical, .top_k = 10, .candidate_k = 100 }) catch |err| {
                std.debug.print("{{\"stage\":\"{s}\",\"error\":\"{s}\",\"cap_bytes\":{d},\"peak_bytes\":{d}}}\n", .{ @tagName(mode), @errorName(err), cap, bounded.peak });
                return err;
            };
            if (hits.len == 0) return error.NoMatches;
            if (i >= 5) samples[i - 5] = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds - before);
        }
        std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
        std.debug.print("{{\"field\":\"{s}\",\"files\":{d},\"open_ns\":{d},\"p50_ns\":{d},\"p95_ns\":{d},\"peak_bytes\":{d},\"cap_bytes\":{d}}}\n", .{ @tagName(mode), (try opened.folder.filenameDecoded()).catalog.len, open_ns, samples[9], samples[18], bounded.peak, cap });
    }
}

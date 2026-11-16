//! S6-T3 codec probe: the in-tree LZ4 decoder over the Python-written blocks,
//! checked byte for byte; best of five rounds.
const std = @import("std");
const common = @import("common.zig");
const lz4 = @import("lz4.zig");

pub fn main(init: std.process.Init) !void {
    const input = try common.load(init);
    const out = try init.gpa.alloc(u8, 65536);
    var best: i96 = std.math.maxInt(i96);
    var blocks: usize = 0;
    for (0..5) |_| {
        var pos: usize = 0;
        var at: usize = 0;
        blocks = 0;
        const start = common.now(init.io);
        while (common.next(input.blob, &pos)) |block| {
            const n = try lz4.decode(block.lz4, out);
            if (n != block.plain_len or !std.mem.eql(u8, out[0..n], input.plain[at..][0..n])) return error.Mismatch;
            at += n;
            blocks += 1;
        }
        best = @min(best, common.now(init.io) - start);
    }
    std.debug.print("lz4_decode blocks={d} plain={d} best_ns={d} ns_per_block={d}\n", .{ blocks, input.plain.len, best, @divTrunc(best, @as(i96, @intCast(blocks))) });
}

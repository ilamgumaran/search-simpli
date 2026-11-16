//! S6-T3 codec probe: std.compress.flate raw decode of every block, checked
//! byte for byte against the plain text; best of five rounds.
const std = @import("std");
const common = @import("common.zig");
const flate = std.compress.flate;

pub fn main(init: std.process.Init) !void {
    const input = try common.load(init);
    const out = try init.gpa.alloc(u8, 65536);
    var window: [flate.max_window_len]u8 = undefined;
    var best: i96 = std.math.maxInt(i96);
    var blocks: usize = 0;
    for (0..5) |_| {
        var pos: usize = 0;
        var at: usize = 0;
        blocks = 0;
        const start = common.now(init.io);
        while (common.next(input.blob, &pos)) |block| {
            var in: std.Io.Reader = .fixed(block.deflate);
            var d: flate.Decompress = .init(&in, .raw, &window);
            var w: std.Io.Writer = .fixed(out);
            const n = try d.reader.streamRemaining(&w);
            if (n != block.plain_len or !std.mem.eql(u8, out[0..n], input.plain[at..][0..n])) return error.Mismatch;
            at += n;
            blocks += 1;
        }
        best = @min(best, common.now(init.io) - start);
    }
    std.debug.print("flate_decode blocks={d} plain={d} best_ns={d} ns_per_block={d}\n", .{ blocks, input.plain.len, best, @divTrunc(best, @as(i96, @intCast(blocks))) });
}

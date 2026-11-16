//! S6-T3 codec probe, baseline: loads the blocks and walks them, decoding
//! nothing. Its ReleaseSmall size is the base the other probes are compared to.
const std = @import("std");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    const input = try common.load(init);
    var pos: usize = 0;
    var total: usize = 0;
    var blocks: usize = 0;
    while (common.next(input.blob, &pos)) |block| {
        total += block.plain_len;
        blocks += 1;
    }
    if (total != input.plain.len) return error.Mismatch;
    std.debug.print("base blocks={d} plain={d}\n", .{ blocks, total });
}

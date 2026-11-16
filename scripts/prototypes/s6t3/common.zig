//! S6-T3 codec probe: shared loading for the probe programs. Not part of the
//! engine (it sits under scripts/prototypes, outside zig/src and the native digest).
//! Input: a directory written by `scripts/index_size_budget.py codec-blocks`:
//! `plain.bin` (a source section's text area) and `blocks.bin` (per 64 KiB
//! block: u32 plain length, u32 deflate length, u32 LZ4 length, the raw
//! deflate bytes, the LZ4 bytes).
const std = @import("std");

pub const Input = struct { plain: []u8, blob: []u8 };

pub const Block = struct { plain_len: usize, deflate: []const u8, lz4: []const u8 };

pub fn load(init: std.process.Init) !Input {
    var it = init.minimal.args.iterate();
    _ = it.next();
    const dir = it.next() orelse return error.Usage;
    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;
    const plain = try std.Io.Dir.cwd().readFileAlloc(init.io, try std.fmt.bufPrint(&a, "{s}/plain.bin", .{dir}), init.gpa, .unlimited);
    const blob = try std.Io.Dir.cwd().readFileAlloc(init.io, try std.fmt.bufPrint(&b, "{s}/blocks.bin", .{dir}), init.gpa, .unlimited);
    return .{ .plain = plain, .blob = blob };
}

pub fn next(blob: []const u8, pos: *usize) ?Block {
    if (pos.* >= blob.len) return null;
    const p = pos.*;
    const plain_len = std.mem.readInt(u32, blob[p..][0..4], .little);
    const dl = std.mem.readInt(u32, blob[p + 4 ..][0..4], .little);
    const ll = std.mem.readInt(u32, blob[p + 8 ..][0..4], .little);
    const d = blob[p + 12 ..][0..dl];
    const l = blob[p + 12 + dl ..][0..ll];
    pos.* = p + 12 + dl + ll;
    return .{ .plain_len = plain_len, .deflate = d, .lz4 = l };
}

pub fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

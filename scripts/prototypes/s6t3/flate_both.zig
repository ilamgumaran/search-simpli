//! S6-T3 codec probe: std.compress.flate raw encode of the plain text in 64 KiB
//! blocks (level 6, the default), then decode and compare; reports the size
//! the Zig encoder reaches and both times.
const std = @import("std");
const common = @import("common.zig");
const flate = std.compress.flate;

pub fn main(init: std.process.Init) !void {
    const input = try common.load(init);
    const gpa = init.gpa;
    var packed_blocks: std.ArrayList([]u8) = .empty;
    var compressed: usize = 0;
    const enc_start = common.now(init.io);
    var at: usize = 0;
    while (at < input.plain.len) {
        const piece = input.plain[at..@min(at + 65536, input.plain.len)];
        var aw: std.Io.Writer.Allocating = .init(gpa);
        const buffer = try gpa.alloc(u8, flate.max_window_len);
        var c = try flate.Compress.init(&aw.writer, buffer, .raw, .default);
        try c.writer.writeAll(piece);
        try c.finish();
        const bytes = try aw.toOwnedSlice();
        compressed += bytes.len;
        try packed_blocks.append(gpa, bytes);
        gpa.free(buffer);
        at += piece.len;
    }
    const enc_ns = common.now(init.io) - enc_start;
    const out = try gpa.alloc(u8, 65536);
    var window: [flate.max_window_len]u8 = undefined;
    const dec_start = common.now(init.io);
    at = 0;
    for (packed_blocks.items) |bytes| {
        var in: std.Io.Reader = .fixed(bytes);
        var d: flate.Decompress = .init(&in, .raw, &window);
        var w: std.Io.Writer = .fixed(out);
        const n = try d.reader.streamRemaining(&w);
        if (!std.mem.eql(u8, out[0..n], input.plain[at..][0..n])) return error.Mismatch;
        at += n;
    }
    const dec_ns = common.now(init.io) - dec_start;
    if (at != input.plain.len) return error.Mismatch;
    std.debug.print("flate_both blocks={d} plain={d} zig_compressed={d} encode_ns={d} decode_ns={d}\n", .{ packed_blocks.items.len, input.plain.len, compressed, enc_ns, dec_ns });
}

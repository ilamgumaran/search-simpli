//! S6-T3 codec probe: the in-tree LZ4 encoder over the plain text in 64 KiB
//! blocks, then the decoder, compared byte for byte.
const std = @import("std");
const common = @import("common.zig");
const lz4 = @import("lz4.zig");

pub fn main(init: std.process.Init) !void {
    const input = try common.load(init);
    const gpa = init.gpa;
    const table = try gpa.create([1 << 14]u32);
    const packed_all = try gpa.alloc(u8, input.plain.len + input.plain.len / 255 + 16 * (input.plain.len / 65536 + 1));
    var ends: std.ArrayList(usize) = .empty;
    var o: usize = 0;
    const enc_start = common.now(init.io);
    var at: usize = 0;
    while (at < input.plain.len) {
        const piece = input.plain[at..@min(at + 65536, input.plain.len)];
        o += lz4.encode(piece, packed_all[o..], table);
        try ends.append(gpa, o);
        at += piece.len;
    }
    const enc_ns = common.now(init.io) - enc_start;
    const out = try gpa.alloc(u8, 65536);
    const dec_start = common.now(init.io);
    var from: usize = 0;
    at = 0;
    for (ends.items) |end| {
        const n = try lz4.decode(packed_all[from..end], out);
        if (!std.mem.eql(u8, out[0..n], input.plain[at..][0..n])) return error.Mismatch;
        at += n;
        from = end;
    }
    const dec_ns = common.now(init.io) - dec_start;
    if (at != input.plain.len) return error.Mismatch;
    std.debug.print("lz4_both blocks={d} plain={d} zig_compressed={d} encode_ns={d} decode_ns={d}\n", .{ ends.items.len, input.plain.len, o, enc_ns, dec_ns });
}

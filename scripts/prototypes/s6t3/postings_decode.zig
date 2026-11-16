//! S6-T3 probe: the open's posting decode, today's fixed 8-byte postings
//! (`lexical_segment.decodeWith`: two u32 reads, a range check and tf > 0)
//! against candidate C2b (per term, a gap varint with tf == 1 folded into its
//! low bit, then a tf varint when tf > 1), each into the same Posting array,
//! compared element for element; best of seven rounds each. Input:
//! `postings.bin` from `scripts/index_size_budget.py codec-blocks`.
const std = @import("std");

const Posting = struct { document_index: u32, term_frequency: u32 };

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn decodeFixed(bytes: []const u8, out: []Posting, documents: u32) !void {
    for (out, 0..) |*p, i| {
        p.* = .{
            .document_index = std.mem.readInt(u32, bytes[i * 8 ..][0..4], .little),
            .term_frequency = std.mem.readInt(u32, bytes[i * 8 + 4 ..][0..4], .little),
        };
        if (p.document_index >= documents or p.term_frequency == 0) return error.InvalidPosting;
    }
}

fn varint(bytes: []const u8, at: *usize) !u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        if (at.* >= bytes.len) return error.Truncated;
        const b = bytes[at.*];
        at.* += 1;
        result |= @as(u32, b & 0x7f) << shift;
        if (b < 0x80) return result;
        if (shift >= 28) return error.Overflow;
        shift += 7;
    }
}

fn decodeFolded(bytes: []const u8, dfs: []const u32, out: []Posting, documents: u32) !void {
    var at: usize = 0;
    var i: usize = 0;
    for (dfs) |df| {
        var next_doc: u32 = 0;
        for (0..df) |_| {
            const v = try varint(bytes, &at);
            const doc = next_doc + (v >> 1);
            const tf: u32 = if (v & 1 == 1) 1 else try varint(bytes, &at);
            if (doc >= documents or tf == 0) return error.InvalidPosting;
            out[i] = .{ .document_index = doc, .term_frequency = tf };
            next_doc = doc + 1;
            i += 1;
        }
    }
    if (at != bytes.len or i != out.len) return error.InvalidSectionLength;
}

pub fn main(init: std.process.Init) !void {
    var it = init.minimal.args.iterate();
    _ = it.next();
    const dir = it.next() orelse return error.Usage;
    var path: [4096]u8 = undefined;
    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, try std.fmt.bufPrint(&path, "{s}/postings.bin", .{dir}), init.gpa, .unlimited);
    const terms = std.mem.readInt(u32, data[0..4], .little);
    const count = std.mem.readInt(u32, data[4..8], .little);
    const documents = std.mem.readInt(u32, data[8..12], .little);
    const dfs = try init.gpa.alloc(u32, terms);
    for (dfs, 0..) |*df, i| df.* = std.mem.readInt(u32, data[12 + 4 * i ..][0..4], .little);
    const fixed = data[12 + 4 * terms ..][0 .. 8 * @as(usize, count)];
    const folded = data[12 + 4 * terms + 8 * @as(usize, count) ..];
    const a = try init.gpa.alloc(Posting, count);
    const b = try init.gpa.alloc(Posting, count);
    var best_fixed: i96 = std.math.maxInt(i96);
    var best_folded: i96 = std.math.maxInt(i96);
    for (0..7) |_| {
        const t0 = now(init.io);
        try decodeFixed(fixed, a, documents);
        const t1 = now(init.io);
        try decodeFolded(folded, dfs, b, documents);
        const t2 = now(init.io);
        best_fixed = @min(best_fixed, t1 - t0);
        best_folded = @min(best_folded, t2 - t1);
    }
    for (a, b) |x, y| if (x.document_index != y.document_index or x.term_frequency != y.term_frequency) return error.Mismatch;
    std.debug.print("postings={d} fixed_bytes={d} folded_bytes={d} fixed_best_ns={d} folded_best_ns={d}\n", .{ count, fixed.len, folded.len, best_fixed, best_folded });
}

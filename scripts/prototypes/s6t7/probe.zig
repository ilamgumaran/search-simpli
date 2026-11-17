//! S6-T7 Phase 1 probe: what the open and the source's first use and a
//! file's read cost with documents record v5 and source v2 against `main`'s
//! v4 and v1, measured in memory (no file I/O, no engine change).
//!
//! Input: an index written by `main` (its `documents-1.hybseg`,
//! `source-1.hybsrc`) and the prototype's `documents-v5.bin`,
//! `source-v2.bin` for the same files (`text_once.py encode`).
//!
//!   zig build-exe -O ReleaseSmall --dep search -Mroot=scripts/prototypes/s6t7/probe.zig \
//!       -Msearch=zig/src/root.zig -femit-bin=OUT/probe
//!   OUT/probe INDEX_DIR PROTO_DIR
//!
//! Measured, best of `rounds` (each a fresh decode into the same arrays):
//! - `open_v4`: `segment.inspect` (the XXH3-64 checksum) and
//!   `segment.decodeInspected` of the v4 section, as `Engine.openWith` runs them;
//! - `open_v5`: XXH3-64 over the v5 section and a v5 decode written from
//!   `docs/source-and-documents-format-v1.md` (file table front-decoded into
//!   one path block, records into the same `hybrid.Document` array, raw ids
//!   expanded to hex into one block); every field compared with the v4 decode;
//! - `first_use_v1`: XXH3-64 over the v1 section, `source.inspect` and `source.openTable` (the
//!   table walk, every map bounded) of the v1 section: the CPU work of the
//!   streamed open (`openStreamed`), without its reads;
//! - `first_use_v2`: XXH3-64 over the v2 section, the file table walked again
//!   into a per-file array, every source record walked (recipes, residual
//!   lengths), every map bounded with `source.varintsEnd`;
//! - `file_v1` / `file_v2` for the smallest, median and largest retained
//!   file: the file's bytes into a buffer (v1: copied from the text area, as
//!   the positioned read leaves them; v2: rebuilt from its chunks and its
//!   residual bytes) and their SHA-256, the part of `read_span`/`outline`
//!   that changes. Every rebuilt file is compared with v1's bytes.
//! The checksum in the prototype's sections is zero, so v5/v2 compute the
//! XXH3 over the same bytes and do not compare it.
const std = @import("std");
const search = @import("search");
const segment = search.segment;
const source = search.source;
const hybrid = search.hybrid;
const Document = hybrid.Document;

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

const Cursor = struct {
    bytes: []const u8,
    at: usize,
    fn varint(c: *Cursor) !u32 {
        var value: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            if (c.at >= c.bytes.len or shift > 28) return error.Damaged;
            const b = c.bytes[c.at];
            c.at += 1;
            value |= @as(u64, b & 0x7f) << shift;
            if (b & 0x80 == 0) break;
            shift += 7;
        }
        if (value > std.math.maxInt(u32)) return error.Damaged;
        return @intCast(value);
    }
    fn take(c: *Cursor, n: usize) ![]const u8 {
        if (n > c.bytes.len - c.at) return error.Damaged;
        defer c.at += n;
        return c.bytes[c.at..][0..n];
    }
};

const FileRow = struct { path: []const u8, first: u32, chunks: u32, retained: bool };

const V5 = struct {
    path_block: []u8,
    id_block: []u8,
    files: []FileRow,
};

fn rd32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}
fn rd64(b: []const u8, at: usize) usize {
    return @intCast(std.mem.readInt(u64, b[at..][0..8], .little));
}

/// The v5 decode the open would run: header, file table (paths into one
/// block), records into `docs`. `files` is filled only when `want_files`.
fn decodeV5(bytes: []const u8, docs: []Document, vectors: []f32, path_block: []u8, id_block: []u8, files: []FileRow, want_files: bool) !void {
    if (!std.mem.eql(u8, bytes[0..8], "HYBSEG01") or std.mem.readInt(u16, bytes[8..10], .little) != 5) return error.Damaged;
    const doc_count = rd32(bytes, 12);
    const dims = rd32(bytes, 16);
    const file_count = rd32(bytes, 20);
    const table_bytes = rd64(bytes, 24);
    const rec_bytes = rd64(bytes, 32);
    const path_text = rd64(bytes, 40);
    if (56 + table_bytes + rec_bytes != bytes.len or path_block.len < path_text or docs.len < doc_count) return error.Damaged;
    var c = Cursor{ .bytes = bytes[0 .. 56 + table_bytes], .at = 56 };
    var used: usize = 0;
    var prev: []const u8 = "";
    var doc: usize = 0;
    var retained: u32 = 0;
    var i: usize = 0;
    while (i < file_count) : (i += 1) {
        const shared = try c.varint();
        if (shared > 255 or shared > prev.len) return error.Damaged;
        const suffix_len = try c.varint();
        if (suffix_len == 0) return error.Damaged;
        const suffix = try c.take(suffix_len);
        if (i > 0 and shared < prev.len and shared < 255 and suffix[0] <= prev[shared]) return error.Damaged;
        const length = shared + suffix_len;
        if (used + length > path_text) return error.Damaged;
        const path = path_block[used..][0..length];
        std.mem.copyForwards(u8, path[0..shared], prev[0..shared]);
        @memcpy(path[shared..], suffix);
        used += length;
        const cr = try c.varint();
        const chunks = cr >> 1;
        const is_retained = cr & 1 == 1;
        if (chunks == 0 and !is_retained) return error.Damaged;
        if (doc + chunks > doc_count) return error.Damaged;
        const sdi: u32 = if (is_retained) retained else hybrid.no_source_doc;
        for (docs[doc..][0..chunks]) |*d| d.* = .{ .id = "", .text = "", .path = path, .source_doc_index = sdi };
        if (want_files) files[i] = .{ .path = path, .first = @intCast(doc), .chunks = chunks, .retained = is_retained };
        doc += chunks;
        if (is_retained) retained += 1;
        prev = path;
    }
    if (c.at != c.bytes.len or used != path_text or doc != doc_count) return error.Damaged;
    var r = Cursor{ .bytes = bytes, .at = 56 + table_bytes };
    var ids: usize = 0;
    var vec_at: usize = 0;
    for (docs[0..doc_count]) |*d| {
        const flags = try r.varint();
        if (flags & ~@as(u32, 7) != 0) return error.Damaged;
        if (flags & 1 != 0) {
            d.id = try r.take(try r.varint());
        } else {
            const raw = try r.take(10);
            const hex = id_block[ids..][0..20];
            const digits = "0123456789abcdef";
            for (raw, 0..) |byte, k| {
                hex[2 * k] = digits[byte >> 4];
                hex[2 * k + 1] = digits[byte & 15];
            }
            d.id = hex;
            ids += 20;
        }
        const text_len = try r.varint();
        const start = try r.varint();
        const span = try r.varint();
        const chunker = try r.varint();
        const depth = try r.varint();
        const back = try r.varint();
        if (start == 0 or chunker > 0xffff or depth > 0xffff or back > start or @as(u64, start) + span > std.math.maxInt(u32)) return error.Damaged;
        const sp_len: u32 = if (depth > 0) try r.varint() else 0;
        if (flags & 4 != 0) d.required_labels = try r.take(try r.varint());
        if (flags & 2 != 0) {
            if (dims == 0) return error.Damaged;
            const raw = try r.take(4 * @as(usize, dims));
            for (vectors[vec_at..][0..dims], 0..) |*v, k| v.* = @bitCast(rd32(raw, 4 * k));
            d.vector = vectors[vec_at..][0..dims];
            vec_at += dims;
        }
        d.text = try r.take(text_len);
        d.section_path = try r.take(sp_len);
        d.start_line = start;
        d.end_line = start + span;
        d.chunker_index = @intCast(chunker);
        d.section_depth = @intCast(depth);
        d.heading_line = if (back == 0) 0 else start - back + 1;
        if (depth != 0 and (std.mem.count(u8, d.section_path, "\x1f") + 1 != depth or d.heading_line == 0)) return error.Damaged;
    }
    if (r.at != bytes.len) return error.Damaged;
}

const SourceRow = struct { sha: []const u8, whole: bool, length: u32, lines: u32, recipe: []const u8, residual: usize, residual_len: usize, map: usize };

/// The v2 source's first use: every record walked against the documents'
/// files, residual lengths summed, every map bounded.
fn firstUseV2(bytes: []const u8, docs: []const Document, files: []const FileRow, rows: []SourceRow) !void {
    if (!std.mem.eql(u8, bytes[0..8], "HYBSRC02")) return error.Damaged;
    const file_count = rd32(bytes, 12);
    const rec_bytes = rd64(bytes, 16);
    const map_bytes = rd64(bytes, 24);
    const res_bytes = rd64(bytes, 32);
    if (48 + rec_bytes + map_bytes + res_bytes != bytes.len) return error.Damaged;
    var c = Cursor{ .bytes = bytes[0 .. 48 + rec_bytes], .at = 48 };
    const maps = bytes[48 + rec_bytes ..][0..map_bytes];
    var map_at: usize = 0;
    var res_at: usize = 0;
    var row: usize = 0;
    for (files) |f| {
        if (!f.retained) continue;
        const sha = try c.take(32);
        const flags = try c.varint();
        if (flags & ~@as(u32, 3) != 0) return error.Damaged;
        const length = try c.varint();
        const lines = try c.varint();
        const whole = flags & 2 != 0;
        var residual_len: usize = length;
        var recipe: []const u8 = "";
        if (!whole) {
            if (try c.varint() != f.chunks) return error.Damaged;
            const recipe_start = c.at;
            var pos: usize = 0;
            var gaps: usize = 0;
            for (docs[f.first..][0..f.chunks]) |d| {
                const v = try c.varint();
                if (v & 1 == 0) {
                    pos += v / 2 + d.text.len;
                    gaps += v / 2;
                } else {
                    const k = (v + 1) / 2;
                    if (k > pos) return error.Damaged;
                    if (k < d.text.len) pos += d.text.len - k;
                }
                if (pos > length) return error.Damaged;
            }
            recipe = c.bytes[recipe_start..c.at];
            residual_len = gaps + (length - pos);
        } else if (f.chunks == 0 and !whole) return error.Damaged;
        const map_end = source.varintsEnd(maps, map_at, @as(usize, lines) + 1) orelse return error.Damaged;
        rows[row] = .{ .sha = sha, .whole = whole, .length = length, .lines = lines, .recipe = recipe, .residual = res_at, .residual_len = residual_len, .map = map_at };
        row += 1;
        map_at = map_end;
        res_at += residual_len;
        if (res_at > res_bytes) return error.Damaged;
    }
    if (row != file_count or c.at != c.bytes.len or map_at != map_bytes or res_at != res_bytes) return error.Damaged;
}

fn rebuild(out: []u8, residual_area: []const u8, docs: []const Document, f: FileRow, s: SourceRow) ![]u8 {
    const res = residual_area[s.residual..][0..s.residual_len];
    if (s.whole) {
        @memcpy(out[0..res.len], res);
        return out[0..res.len];
    }
    var c = Cursor{ .bytes = s.recipe, .at = 0 };
    var at: usize = 0;
    var n: usize = 0;
    for (docs[f.first..][0..f.chunks]) |d| {
        const v = try c.varint();
        if (v & 1 == 0) {
            const g = v / 2;
            @memcpy(out[n..][0..g], res[at..][0..g]);
            at += g;
            n += g;
            @memcpy(out[n..][0..d.text.len], d.text);
            n += d.text.len;
        } else {
            const k = (v + 1) / 2;
            if (k < d.text.len) {
                @memcpy(out[n..][0 .. d.text.len - k], d.text[k..]);
                n += d.text.len - k;
            }
        }
    }
    @memcpy(out[n..][0 .. res.len - at], res[at..]);
    n += res.len - at;
    if (n != s.length) return error.Damaged;
    return out[0..n];
}

fn xxh3(bytes: []const u8) u64 {
    return std.hash.XxHash3.hash(0, bytes);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var it = init.minimal.args.iterate();
    _ = it.next();
    const index_dir = it.next() orelse return error.Usage;
    const proto_dir = it.next() orelse return error.Usage;
    const rounds: usize = 15;
    var buf: [4096]u8 = undefined;
    const cwd = std.Io.Dir.cwd();
    const v4 = try cwd.readFileAlloc(io, try std.fmt.bufPrint(&buf, "{s}/documents-1.hybseg", .{index_dir}), gpa, .unlimited);
    const v1 = try cwd.readFileAlloc(io, try std.fmt.bufPrint(&buf, "{s}/source-1.hybsrc", .{index_dir}), gpa, .unlimited);
    const v5 = try cwd.readFileAlloc(io, try std.fmt.bufPrint(&buf, "{s}/documents-v5.bin", .{proto_dir}), gpa, .unlimited);
    const v2 = try cwd.readFileAlloc(io, try std.fmt.bufPrint(&buf, "{s}/source-v2.bin", .{proto_dir}), gpa, .unlimited);

    const header4 = try segment.inspect(v4);
    const n = header4.document_count;
    const docs4 = try gpa.alloc(Document, n);
    const docs5 = try gpa.alloc(Document, n);
    const vec4 = try gpa.alloc(f32, n * header4.vector_dimensions);
    const vec5 = try gpa.alloc(f32, n * header4.vector_dimensions);
    const path_text = rd64(v5, 40);
    const file_count = rd32(v5, 20);
    const path_block = try gpa.alloc(u8, path_text);
    const id_block = try gpa.alloc(u8, 20 * n);
    const files = try gpa.alloc(FileRow, file_count);

    var best = [_]i96{std.math.maxInt(i96)} ** 6;
    var sink: u64 = 0;
    for (0..rounds) |_| {
        const t0 = now(io);
        const h = try segment.inspect(v4);
        _ = try segment.decodeInspected(v4, h, docs4, vec4);
        const t1 = now(io);
        sink +%= xxh3(v5);
        try decodeV5(v5, docs5, vec5, path_block, id_block, files, false);
        const t2 = now(io);
        best[0] = @min(best[0], t1 - t0);
        best[1] = @min(best[1], t2 - t1);
    }
    // Every field the v5 decode gives back equals v4's.
    for (docs4, docs5) |a, b| {
        if (!std.mem.eql(u8, a.id, b.id) or !std.mem.eql(u8, a.text, b.text) or !std.mem.eql(u8, a.path, b.path) or
            a.start_line != b.start_line or a.end_line != b.end_line or !std.mem.eql(u8, a.required_labels, b.required_labels) or
            a.chunker_index != b.chunker_index or a.section_depth != b.section_depth or a.heading_line != b.heading_line or
            a.source_doc_index != b.source_doc_index or !std.mem.eql(u8, a.section_path, b.section_path) or
            !std.mem.eql(f32, a.vector, b.vector)) return error.RecordMismatch;
    }

    // Source first use.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const rows = try gpa.alloc(SourceRow, rd32(v2, 12));
    var section1: source.Section = undefined;
    for (0..rounds) |_| {
        _ = arena_state.reset(.retain_capacity);
        const t0 = now(io);
        sink +%= xxh3(v1); // the streamed open checksums the whole section
        const h1 = try source.inspect(v1);
        section1 = try source.openTable(arena_state.allocator(), v1, h1);
        const t1 = now(io);
        try decodeV5(v5, docs5, vec5, path_block, id_block, files, true);
        const t1b = now(io);
        sink +%= xxh3(v2); // the first use checksums the whole v2 section
        try firstUseV2(v2, docs5, files, rows);
        const t2 = now(io);
        best[2] = @min(best[2], t1 - t0);
        // `best[4]` is a whole v5 decode again (filling the per-file array
        // the open would keep); the first use proper is `best[3]`.
        best[3] = @min(best[3], t2 - t1b);
        best[4] = @min(best[4], t1b - t1);
    }

    // Every retained file rebuilt and compared with v1's bytes.
    const v2_res = v2[48 + rd64(v2, 16) + rd64(v2, 24) ..];
    var max_len: usize = 0;
    for (rows) |s| max_len = @max(max_len, s.length);
    const out = try gpa.alloc(u8, max_len);
    const copy = try gpa.alloc(u8, max_len);
    var by_length = try gpa.alloc(usize, rows.len);
    var row: usize = 0;
    var retained_files = try gpa.alloc(FileRow, rows.len);
    for (files) |f| if (f.retained) {
        retained_files[row] = f;
        by_length[row] = row;
        row += 1;
    };
    for (rows, retained_files, 0..) |s, f, k| {
        const entry = section1.file(k);
        if (!std.mem.eql(u8, entry.path, f.path)) return error.PathMismatch;
        const got = try rebuild(out, v2_res, docs5, f, s);
        if (!std.mem.eql(u8, got, entry.bytes)) return error.RebuildMismatch;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(got, &digest, .{});
        if (!std.mem.eql(u8, &digest, s.sha)) return error.ShaMismatch;
    }
    const Less = struct {
        fn lt(r: []const SourceRow, a: usize, b: usize) bool {
            return r[a].length < r[b].length;
        }
    };
    std.mem.sort(usize, by_length, @as([]const SourceRow, rows), Less.lt);
    std.debug.print("documents v4={d} v5={d} records={d} files={d} open_v4_ns={d} open_v5_ns={d}\n", .{ v4.len, v5.len, n, file_count, best[0], best[1] });
    std.debug.print("source v1={d} v2={d} first_use_v1_ns={d} first_use_v2_ns={d} v5_decode_keeping_files_ns={d}\n", .{ v1.len, v2.len, best[2], best[3], best[4] });
    const picks = [_]struct { name: []const u8, at: usize }{
        .{ .name = "smallest", .at = 0 },
        .{ .name = "median", .at = rows.len / 2 },
        .{ .name = "largest", .at = rows.len - 1 },
    };
    for (picks) |pick| {
        const k = by_length[pick.at];
        const s = rows[k];
        const f = retained_files[k];
        const entry = section1.file(k);
        const reps: usize = if (s.length > 100_000) 200 else 2000;
        var b1: i96 = std.math.maxInt(i96);
        var b2: i96 = std.math.maxInt(i96);
        for (0..rounds) |_| {
            const t0 = now(io);
            for (0..reps) |_| {
                @memcpy(copy[0..entry.bytes.len], entry.bytes);
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(copy[0..entry.bytes.len], &digest, .{});
                sink +%= digest[0];
            }
            const t1 = now(io);
            for (0..reps) |_| {
                const got = try rebuild(out, v2_res, docs5, f, s);
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(got, &digest, .{});
                sink +%= digest[0];
            }
            const t2 = now(io);
            b1 = @min(b1, @divTrunc(t1 - t0, @as(i96, @intCast(reps))));
            b2 = @min(b2, @divTrunc(t2 - t1, @as(i96, @intCast(reps))));
        }
        std.debug.print("file {s} bytes={d} chunks={d} whole={} residual={d} file_v1_ns={d} file_v2_ns={d}\n", .{ pick.name, s.length, f.chunks, s.whole, s.residual_len, b1, b2 });
    }
    std.debug.print("rebuilt={d} all equal to v1 bytes and sha256; sink={d}\n", .{ rows.len, sink });
}

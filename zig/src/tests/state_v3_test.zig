//! S6-T9: the recovery-state section `HYBSTA03`
//! (`docs/state-section-format-v3.md`): a retained file's record refers to
//! its source record instead of repeating SHA-256, path and size.
//!
//! - The payload against a list source table (`SourceTable.list`): the
//!   worked example byte for byte; `decode(encode(state)) == state` for every
//!   kind of entry the writer may meet; each rule S1 to S5 refused with its
//!   own error at the first, a middle and the last record, and every numeric
//!   bound at the bound and one either side.
//! - Through a real generation: the writer's state is `HYBSTA03` with every
//!   retained file referenced; each rule refused at the next write (a
//!   carrying write: an update that carries every unchanged file) and at the
//!   pointer's resolution, the files byte-identical, readers still answering
//!   (an open never reads the state).
const std = @import("std");
const apply = @import("core").apply;
const checksum = @import("core").checksum;
const incremental_state = @import("core").incremental_state;
const manifest = @import("core").manifest;
const publication = @import("core").publication;
const snapshot_open = @import("core").snapshot_open;
const state_section = @import("core").state_section;

const io = std.testing.io;
const Entry = incremental_state.Entry;
const SourceRef = incremental_state.SourceRef;

fn digest(text: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &out, .{});
    return out;
}

const roots = [_]incremental_state.Root{
    .{ .root_id = "home", .label = "home", .kind = "host", .retain_source = true, .origin = "host" },
    .{ .root_id = "school", .label = "school", .kind = "host", .retain_source = true, .origin = "host" },
};
const texts = [_][]const u8{ "alpha\n", "bravo two\n", "charlie\n", "delta four\n", "echo five five\n" };
const record_paths = [_][]const u8{ "home/a.md", "home/b.md", "home/c.md", "school/d.md", "school/e.md" };

/// Five files in record-path order, every one retained: the list table
/// and the state whose entries match it.
const Sample = struct {
    table: [5]SourceRef,
    hexes: [5][64]u8,
    files: [5]Entry,

    fn init(sample: *Sample) void {
        for (&sample.table, &sample.hexes, &sample.files, record_paths, texts, 0..) |*ref, *hex, *entry, path, text, i| {
            ref.* = .{ .ordinal = @intCast(i), .path = path, .sha256 = digest(text), .length = text.len };
            hex.* = std.fmt.bytesToHex(ref.sha256, .lower);
            const slash = std.mem.indexOfScalar(u8, path, '/').?;
            entry.* = .{
                .root_id = path[0..slash],
                .path = path[slash + 1 ..],
                .hash = hex,
                .size = text.len,
                .chunker = "md-section-v1",
                .chunks = 1,
                .mtime_ms = if (i == 1) 1234 else null,
                .moved_from = if (i == 2) "old/c.md" else null,
            };
        }
    }

    fn state(sample: *const Sample) incremental_state.State {
        return .{ .generation = 9, .analyzer_id = "analyzer-v2", .roots = &roots, .files = &sample.files };
    }

    fn refs(sample: *const Sample) [5]?SourceRef {
        var out: [5]?SourceRef = undefined;
        for (&out, sample.table) |*slot, ref| slot.* = ref;
        return out;
    }

    fn sourceTable(sample: *const Sample) incremental_state.SourceTable {
        return .{ .list = &sample.table };
    }
};

fn expectSameState(want: incremental_state.State, got: incremental_state.State) !void {
    try std.testing.expectEqual(want.generation, got.generation);
    try std.testing.expectEqualStrings(want.analyzer_id, got.analyzer_id);
    try std.testing.expectEqual(want.files.len, got.files.len);
    for (want.files, got.files) |w, g| {
        try std.testing.expectEqualStrings(w.root_id, g.root_id);
        try std.testing.expectEqualStrings(w.path, g.path);
        try std.testing.expectEqualStrings(w.hash, g.hash);
        try std.testing.expectEqual(w.size, g.size);
        try std.testing.expectEqual(w.mtime_ms, g.mtime_ms);
        try std.testing.expectEqual(w.status, g.status);
        try std.testing.expectEqual(w.chunks, g.chunks);
        try std.testing.expectEqual(w.chunker == null, g.chunker == null);
        if (w.chunker) |c| try std.testing.expectEqualStrings(c, g.chunker.?);
        try std.testing.expectEqual(w.moved_from == null, g.moved_from == null);
        if (w.moved_from) |m| try std.testing.expectEqualStrings(m, g.moved_from.?);
        try std.testing.expectEqual(w.required_labels.len, g.required_labels.len);
        for (w.required_labels, g.required_labels) |x, y| try std.testing.expectEqualStrings(x, y);
    }
}

/// The offset of file record `k` in a `HYBSTA03` payload.
fn recordOffset(payload: []const u8, k: usize) usize {
    const string_count = std.mem.readInt(u32, payload[20..24], .little);
    const root_count = std.mem.readInt(u32, payload[24..28], .little);
    var at: usize = incremental_state.binary_header_length;
    var text: usize = 0;
    for (0..string_count) |i| text += std.mem.readInt(u32, payload[at + 4 * i ..][0..4], .little);
    at += 4 * string_count + text + incremental_state.binary_root_length * root_count;
    for (0..k) |_| {
        const flags = std.mem.readInt(u32, payload[at + 4 ..][0..4], .little);
        at += if (flags & (1 << 6) != 0) incremental_state.binary_ref_length else incremental_state.binary_file_length;
    }
    return at;
}

fn put32(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}

fn get32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

const positions = [_]usize{ 0, 2, 4 };

test "S6-T9 state v3: the worked example of the format document, byte for byte" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const content = "# Plan\n\nThe plan.\n";
    const ref = SourceRef{ .ordinal = 0, .path = "home/notes/plan.md", .sha256 = digest(content), .length = content.len };
    const hex = std.fmt.bytesToHex(ref.sha256, .lower);
    const root = [_]incremental_state.Root{.{ .root_id = "home", .label = "home", .kind = "host", .retain_source = true, .origin = "host" }};
    const files = [_]Entry{
        .{ .root_id = "home", .path = "inbox/todo.txt", .hash = "", .size = 12, .status = .pending },
        .{ .root_id = "home", .path = "notes/plan.md", .hash = &hex, .size = content.len, .chunker = "md-section-v1", .chunks = 2 },
    };
    const state = incremental_state.State{ .generation = 3, .analyzer_id = "analyzer-v2", .roots = &root, .files = &files };
    const refs = [_]?SourceRef{ null, ref };
    const payload = try incremental_state.encodeBinaryRefs(a, state, &refs);
    try std.testing.expectEqual(@as(usize, 238), payload.len);
    try std.testing.expectEqual(@as(usize, 291), (try incremental_state.encodeBinary(a, state)).len);
    const expected_head = [_]u32{ 2, 0, 3, 0, 0, 4, 1, 2, 0, 0, 11, 4, 4, 13 };
    for (expected_head, 0..) |value, i| try std.testing.expectEqual(value, get32(payload, 4 * i));
    try std.testing.expectEqualStrings("analyzer-v2homehostmd-section-v1", payload[56..88]);
    for ([_]u32{ 1, 1, 2, 2, 1, 0 }, 0..) |value, i| try std.testing.expectEqual(value, get32(payload, 88 + 4 * i));
    // File 0, the full record.
    try std.testing.expectEqual(@as(u32, 1), get32(payload, 112));
    try std.testing.expectEqual(@as(u32, 9), get32(payload, 116));
    try std.testing.expectEqual(@as(u64, 12), std.mem.readInt(u64, payload[120..128], .little));
    try std.testing.expectEqual(@as(u32, 14), get32(payload, 148));
    try std.testing.expect(std.mem.allEqual(u8, payload[156..188], 0));
    // File 1, the referenced record.
    for ([_]u32{ 1, 0x60, 0, 0, 2, 3, 0, 0, 0 }, 0..) |value, i| try std.testing.expectEqual(value, get32(payload, 188 + 4 * i));
    try std.testing.expectEqualStrings("inbox/todo.txt", payload[224..238]);
    const back = try incremental_state.decodeBinaryWith(a, payload, true, .{ .list = &.{ref} });
    try expectSameState(state, back);
    // Through the section: magic HYBSTA03, version 3.
    const section = try incremental_state.encodeSectionRefs(a, state, &refs);
    try std.testing.expectEqualStrings("HYBSTA03", section[0..8]);
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, section[8..10], .little));
    try std.testing.expectEqual(state_section.Form.binary_v3, (try state_section.inspect(section)).form);
    try expectSameState(state, try incremental_state.decodeSectionWith(a, section, .{ .list = &.{ref} }));
}

test "S6-T9 state v3: decode(encode(state)) is the state, references taken exactly when the entry matches its record" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sample: Sample = undefined;
    sample.init();
    const refs = sample.refs();
    const all = try incremental_state.encodeBinaryRefs(a, sample.state(), &refs);
    try std.testing.expectEqual((try incremental_state.encodeBinary(a, sample.state())).len - 5 * 40 - 5 * 4, all.len);
    try expectSameState(sample.state(), try incremental_state.decodeBinaryWith(a, all, true, sample.sourceTable()));
    // Each way an entry can differ from its record keeps the full record,
    // and the state still decodes to itself.
    const upper = try std.ascii.allocUpperString(a, &sample.hexes[0]);
    const Case = struct { name: []const u8, k: usize, entry: Entry };
    var cases = [_]Case{
        .{ .name = "hash in upper case", .k = 0, .entry = sample.files[0] },
        .{ .name = "another hash", .k = 1, .entry = sample.files[1] },
        .{ .name = "no hash", .k = 1, .entry = sample.files[1] },
        .{ .name = "size one more", .k = 2, .entry = sample.files[2] },
        .{ .name = "size one less", .k = 2, .entry = sample.files[2] },
        .{ .name = "no size", .k = 2, .entry = sample.files[2] },
        .{ .name = "another path", .k = 3, .entry = sample.files[3] },
        .{ .name = "another root", .k = 3, .entry = sample.files[3] },
        .{ .name = "pending", .k = 4, .entry = sample.files[4] },
    };
    cases[0].entry.hash = upper;
    cases[1].entry.hash = &sample.hexes[0];
    cases[2].entry.hash = "";
    cases[3].entry.size = sample.files[2].size.? + 1;
    cases[4].entry.size = sample.files[2].size.? - 1;
    cases[5].entry.size = null;
    cases[6].entry.path = "d.mdx";
    cases[7].entry.root_id = "home";
    cases[8].entry.status = .pending;
    for (cases) |case| {
        var files = sample.files;
        files[case.k] = case.entry;
        var state = sample.state();
        state.files = &files;
        const payload = try incremental_state.encodeBinaryRefs(a, state, &refs);
        const at = recordOffset(payload, case.k);
        if (get32(payload, at + 4) & (1 << 6) != 0) {
            std.debug.print("{s}: referenced\n", .{case.name});
            return error.TestUnexpectedResult;
        }
        var want = state;
        var want_files = files;
        if (std.mem.eql(u8, case.name, "hash in upper case")) want_files[0].hash = &sample.hexes[0];
        want.files = &want_files;
        try expectSameState(want, try incremental_state.decodeBinaryWith(a, payload, true, sample.sourceTable()));
    }
    // A record offered out of order keeps its full record.
    var swapped = refs;
    swapped[1] = sample.table[0];
    const payload = try incremental_state.encodeBinaryRefs(a, sample.state(), &swapped);
    try std.testing.expectEqual(@as(u32, 0), get32(payload, recordOffset(payload, 1) + 4) & (1 << 6));
    // No offers: every record full, the v2 records under the v3 magic.
    const none = try incremental_state.encodeBinaryRefs(a, sample.state(), &.{});
    try std.testing.expectEqualSlices(u8, try incremental_state.encodeBinary(a, sample.state()), none);
    try expectSameState(sample.state(), try incremental_state.decodeBinaryWith(a, none, true, null));
    // A list of the wrong length is refused.
    try std.testing.expectError(error.InvalidState, incremental_state.encodeBinaryRefs(a, sample.state(), refs[0..4]));
}

/// The sample with only record `k` referenced (the others full).
fn onlyReferenced(a: std.mem.Allocator, sample: *const Sample, k: usize) ![]u8 {
    var refs = [_]?SourceRef{null} ** 5;
    refs[k] = sample.table[k];
    return incremental_state.encodeBinaryRefs(a, sample.state(), &refs);
}

test "S6-T9 state v3 S1: a referenced record with bit 0, 2 or 3 set is StateReferenceFlags, first, middle and last record" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sample: Sample = undefined;
    sample.init();
    const refs = sample.refs();
    const payload = try incremental_state.encodeBinaryRefs(a, sample.state(), &refs);
    for (positions) |k| for ([_]u32{ 1, 4, 8 }) |bit| {
        const copy = try a.dupe(u8, payload);
        const at = recordOffset(copy, k);
        put32(copy, at + 4, get32(copy, at + 4) | bit);
        try std.testing.expectError(error.StateReferenceFlags, incremental_state.decodeBinaryWith(a, copy, true, sample.sourceTable()));
    };
    // Bits 1, 4 and 5 are the record's own (with their fields zero they are
    // v2's rule, InvalidState); bit 7 and above are unknown (InvalidState).
    for (positions) |k| for ([_]u32{ 1 << 7, 1 << 31 }) |bit| {
        const copy = try a.dupe(u8, payload);
        const at = recordOffset(copy, k);
        put32(copy, at + 4, get32(copy, at + 4) | bit);
        try std.testing.expectError(error.InvalidState, incremental_state.decodeBinaryWith(a, copy, true, sample.sourceTable()));
    };
}

test "S6-T9 state v3: a referenced record's absent fields hold zero (v2's rule, InvalidState), first, middle and last record" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sample: Sample = undefined;
    sample.init();
    for (&sample.files) |*entry| {
        entry.mtime_ms = null;
        entry.chunker = null;
        entry.moved_from = null;
    }
    const refs = sample.refs();
    const payload = try incremental_state.encodeBinaryRefs(a, sample.state(), &refs);
    _ = try incremental_state.decodeBinaryWith(a, payload, true, sample.sourceTable());
    for (positions) |k| for ([_]usize{ 8, 12, 20, 32 }) |field| {
        const copy = try a.dupe(u8, payload);
        copy[recordOffset(copy, k) + field] = 1;
        try std.testing.expectError(error.InvalidState, incremental_state.decodeBinaryWith(a, copy, true, sample.sourceTable()));
    };
    // A v2 decoder refuses bit 6.
    try std.testing.expectError(error.InvalidState, incremental_state.decodeBinary(a, payload));
}

test "S6-T9 state v3 S2: a reference without a source table is StateReferenceWithoutSource, first, middle and last record" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sample: Sample = undefined;
    sample.init();
    for (positions) |k| {
        const payload = try onlyReferenced(a, &sample, k);
        try std.testing.expectError(error.StateReferenceWithoutSource, incremental_state.decodeBinaryWith(a, payload, true, null));
        _ = try incremental_state.decodeBinaryWith(a, payload, true, sample.sourceTable());
    }
}

test "S6-T9 state v3 S3: a source record at or past the source's count is StateReferenceOutOfRange; one less is read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sample: Sample = undefined;
    sample.init();
    for (positions) |k| {
        const payload = try onlyReferenced(a, &sample, k);
        const at = recordOffset(payload, k) + 28;
        for ([_]u32{ 5, 6, std.math.maxInt(u32) }) |ordinal| {
            const copy = try a.dupe(u8, payload);
            put32(copy, at, ordinal);
            try std.testing.expectError(error.StateReferenceOutOfRange, incremental_state.decodeBinaryWith(a, copy, true, sample.sourceTable()));
        }
    }
    // The bound and one either side, at the last record (whose own record is
    // the last): count - 1 is read, count and count + 1 are refused; and a
    // table one record shorter refuses the same record.
    const payload = try onlyReferenced(a, &sample, 4);
    try std.testing.expectEqual(@as(u32, 4), get32(payload, recordOffset(payload, 4) + 28));
    _ = try incremental_state.decodeBinaryWith(a, payload, true, sample.sourceTable());
    try std.testing.expectError(error.StateReferenceOutOfRange, incremental_state.decodeBinaryWith(a, payload, true, .{ .list = sample.table[0..4] }));
    _ = try incremental_state.decodeBinaryWith(a, payload, true, .{ .list = &sample.table });
}

test "S6-T9 state v3 S4: a source record not above the previous reference's is StateReferenceOrder, first, middle and last record" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sample: Sample = undefined;
    sample.init();
    const refs = sample.refs();
    const payload = try incremental_state.encodeBinaryRefs(a, sample.state(), &refs);
    // The middle and the last record: equal to the previous (the bound),
    // one less; the first: its successor made equal to it.
    for ([_]usize{ 2, 4 }) |k| for ([_]u32{ 0, 1 }) |below| {
        const copy = try a.dupe(u8, payload);
        put32(copy, recordOffset(copy, k) + 28, @intCast(k - 1 - below));
        try std.testing.expectError(error.StateReferenceOrder, incremental_state.decodeBinaryWith(a, copy, true, sample.sourceTable()));
    };
    {
        const copy = try a.dupe(u8, payload);
        put32(copy, recordOffset(copy, 0) + 28, 1);
        try std.testing.expectError(error.StateReferenceOrder, incremental_state.decodeBinaryWith(a, copy, true, sample.sourceTable()));
    }
    // One above the previous is read (every record of the sample is).
    _ = try incremental_state.decodeBinaryWith(a, payload, true, sample.sourceTable());
    // A gap (records skipped) is allowed: record 2 referring to 3 when 3 is
    // not referred to again would pass S4 (its path then fails S5 here).
    const only = try onlyReferenced(a, &sample, 2);
    const copy = try a.dupe(u8, only);
    put32(copy, recordOffset(copy, 2) + 28, 3);
    try std.testing.expectError(error.StateReferencePath, incremental_state.decodeBinaryWith(a, copy, true, sample.sourceTable()));
}

test "S6-T9 state v3 S5: a table path outside the record's root is StateReferencePath, first, middle and last record" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sample: Sample = undefined;
    sample.init();
    const refs = sample.refs();
    const payload = try incremental_state.encodeBinaryRefs(a, sample.state(), &refs);
    // The record's root swapped for the other root's string (both strings
    // are in the table: 1 `home`, 4 `school`... found by value).
    const home = stringIndex(payload, "home");
    const school = stringIndex(payload, "school");
    for (positions) |k| {
        const copy = try a.dupe(u8, payload);
        const at = recordOffset(copy, k);
        put32(copy, at, if (get32(copy, at) == home) school else home);
        try std.testing.expectError(error.StateReferencePath, incremental_state.decodeBinaryWith(a, copy, true, sample.sourceTable()));
    }
    // The legacy root takes the whole path, under any prefix.
    var legacy = sample;
    for (&legacy.files, record_paths) |*entry, path| {
        entry.root_id = "r-legacy";
        entry.path = path;
    }
    const legacy_roots = [_]incremental_state.Root{.{ .root_id = "r-legacy", .label = "folder", .kind = "local", .retain_source = true, .origin = "folder" }};
    var state = legacy.state();
    state.roots = &legacy_roots;
    const legacy_payload = try incremental_state.encodeBinaryRefs(a, state, &refs);
    try std.testing.expectEqual(@as(u32, 1 << 6), get32(legacy_payload, recordOffset(legacy_payload, 4) + 4) & (1 << 6));
    try expectSameState(state, try incremental_state.decodeBinaryWith(a, legacy_payload, true, legacy.sourceTable()));
}

fn stringIndex(payload: []const u8, text: []const u8) u32 {
    const count = get32(payload, 20);
    var at: usize = incremental_state.binary_header_length + 4 * count;
    for (0..count) |i| {
        const length = get32(payload, incremental_state.binary_header_length + 4 * i);
        if (std.mem.eql(u8, payload[at..][0..length], text)) return @intCast(i);
        at += length;
    }
    unreachable;
}

test "S6-T9 state v3 S5 bound: the root prefix needs one byte after its slash" {
    try std.testing.expectEqualStrings("x", incremental_state.relativeOf("home", "home/x").?);
    try std.testing.expectEqualStrings("xy", incremental_state.relativeOf("home", "home/xy").?);
    try std.testing.expectEqual(@as(?[]const u8, null), incremental_state.relativeOf("home", "home/"));
    try std.testing.expectEqual(@as(?[]const u8, null), incremental_state.relativeOf("home", "home"));
    try std.testing.expectEqual(@as(?[]const u8, null), incremental_state.relativeOf("home", "homex"));
    try std.testing.expectEqual(@as(?[]const u8, null), incremental_state.relativeOf("home", "homework/x"));
    try std.testing.expectEqual(@as(?[]const u8, null), incremental_state.relativeOf("home", "hom/x"));
    try std.testing.expectEqualStrings("home/", incremental_state.relativeOf("r-legacy", "home/").?);
}

test "S6-T9 state v3: counts, record lengths and truncation are refused (InvalidState), never read past the payload" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sample: Sample = undefined;
    sample.init();
    const refs = sample.refs();
    for ([_][]const ?SourceRef{ &refs, &.{} }) |offered| {
        const payload = try incremental_state.encodeBinaryRefs(a, sample.state(), offered);
        for (0..payload.len) |cut| {
            if (incremental_state.decodeBinaryWith(a, payload[0..cut], true, sample.sourceTable())) |_| return error.TestUnexpectedResult else |_| {}
        }
        try std.testing.expectError(error.InvalidState, incremental_state.decodeBinaryWith(a, try std.mem.concat(a, u8, &.{ payload, "x" }), true, sample.sourceTable()));
    }
    // The file count's bound, 36 bytes a record: the bytes after the
    // header must hold the string lengths, the roots, 36 bytes per file and
    // the label references (the string text and the paths are not counted).
    // With a 40-byte moved_from the room holds more than the five records:
    // a count at the bound passes it (and is refused when its records run
    // into the text), one more is refused at the bound, before anything is
    // allocated.
    var long = sample;
    long.files[2].moved_from = "old/a-much-longer-name-for-the-file.md!!";
    const payload = try incremental_state.encodeBinaryRefs(a, long.state(), &refs);
    const string_count = get32(payload, 20);
    const room = payload.len - incremental_state.binary_header_length - 4 * string_count - incremental_state.binary_root_length * get32(payload, 24) - 4 * get32(payload, 32);
    const bound: u32 = @intCast(room / incremental_state.binary_ref_length);
    try std.testing.expect(bound > 5);
    _ = try incremental_state.decodeBinaryWith(a, payload, true, long.sourceTable());
    for ([_]u32{ bound, bound + 1, std.math.maxInt(u32) }) |count| {
        const copy = try a.dupe(u8, payload);
        put32(copy, 28, count);
        try std.testing.expectError(error.InvalidState, incremental_state.decodeBinaryWith(a, copy, true, long.sourceTable()));
    }
}

// ------------------------------------------------- through a generation ---

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    out: std.Io.Dir,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDir(io, "out", .default_dir);
        const out = try tmp.dir.openDir(io, "out", .{ .iterate = true });
        return .{ .arena_state = std.heap.ArenaAllocator.init(std.testing.allocator), .tmp = tmp, .out = out };
    }

    fn deinit(f: *Fixture) void {
        f.out.close(io);
        f.tmp.cleanup();
        f.arena_state.deinit();
    }

    fn arena(f: *Fixture) std.mem.Allocator {
        return f.arena_state.allocator();
    }

    fn apply_(f: *Fixture, request: []const u8) !apply.Outcome {
        return apply.applyChanges(f.arena(), io, f.out, request, .{});
    }

    fn listing(f: *Fixture) ![]const u8 {
        var names = std.ArrayList([]const u8).empty;
        var it = f.out.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or std.mem.eql(u8, entry.name, "WRITER.LOCK")) continue;
            try names.append(f.arena(), try f.arena().dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.less);
        var out = std.ArrayList(u8).empty;
        for (names.items) |name| {
            const bytes = try f.out.readFileAlloc(io, name, f.arena(), .unlimited);
            var d: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
            try out.print(f.arena(), "{s} {x}\n", .{ name, d });
        }
        return out.items;
    }
};

fn b64(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const out = try a.alloc(u8, std.base64.standard.Encoder.calcSize(text.len));
    return std.base64.standard.Encoder.encode(out, text);
}

const generation_roots =
    \\[{"root_id":"home","kind":"host"},{"root_id":"school","kind":"host"}]
;
const generation_files = [_][2][]const u8{
    .{ "home", "a.md" },   .{ "home", "b.md" },     .{ "home", "c.md" },
    .{ "school", "d.md" }, .{ "school", "e.md" },
};

/// Generation 1: five retained files over two host roots and a pending one
/// (`home/p.txt`, between the retained ones in record-path order).
fn initGeneration(f: *Fixture, roots_json: []const u8) !void {
    const a = f.arena();
    var changes = std.ArrayList([]const u8).empty;
    for (generation_files, 0..) |file, i| {
        try changes.append(a, try std.fmt.allocPrint(a, "{{\"op\":\"add\",\"root_id\":\"{s}\",\"path\":\"{s}\",\"content_base64\":\"{s}\"}}", .{ file[0], file[1], try b64(a, try std.fmt.allocPrint(a, "# File {d}\n\nharbour lantern number {d}\n", .{ i, i })) }));
    }
    try changes.append(a, "{\"op\":\"pending\",\"root_id\":\"home\",\"path\":\"p.txt\",\"size\":9}");
    const request = try std.fmt.allocPrint(a, "{{\"roots\":{s},\"changes\":[{s}]}}", .{ roots_json, try std.mem.join(a, ",", changes.items) });
    switch (try f.apply_(request)) {
        .ok => {},
        .failed => return error.TestUnexpectedResult,
    }
}

const carrying_write =
    \\{"changes":[{"op":"add","root_id":"home","path":"z.md","content_base64":"IyBaCgpuZXcgZmlsZQo="}]}
;

fn currentManifest(f: *Fixture) !manifest.Manifest {
    return manifest.decode(try f.out.readFileAlloc(io, publication.current_manifest_file, f.arena(), .unlimited));
}

/// The bound state section, its payload passed to `mutate`, resealed (its
/// XXH3-64 over header and payload) and re-bound by the manifest.
fn rewriteState(f: *Fixture, context: anytype, comptime mutate: fn (@TypeOf(context), []u8) anyerror!void) !void {
    const a = f.arena();
    var metadata = try currentManifest(f);
    const name = metadata.state.?.file;
    const bytes = try f.out.readFileAlloc(io, name, a, .unlimited);
    try mutate(context, bytes[state_section.header_length..]);
    std.mem.writeInt(u64, bytes[24..32], checksum.compute(.xxh3_64, bytes[0..24], bytes[state_section.header_length..]), .little);
    try f.out.writeFile(io, .{ .sub_path = name, .data = bytes });
    metadata = try manifest.withState(metadata, name, bytes);
    const buffer = try a.alloc(u8, try manifest.encodedLength(metadata));
    try publication.writeAtomicFile(f.out, io, publication.current_manifest_file, try manifest.encode(metadata, buffer), true);
}

/// The record index (in file order) of the `n`-th referenced record.
fn referencedRecord(payload: []const u8, n: usize) usize {
    var seen: usize = 0;
    var k: usize = 0;
    while (true) : (k += 1) {
        if (get32(payload, recordOffset(payload, k) + 4) & (1 << 6) != 0) {
            if (seen == n) return k;
            seen += 1;
        }
    }
}

const Damage = struct {
    which: usize, // 0 first, 2 middle, 4 last referenced record
    rule: enum { flags_size, flags_sha, flags_pending, out_of_range, order, path },

    fn apply_(d: Damage, payload: []u8) anyerror!void {
        const k = referencedRecord(payload, d.which);
        const at = recordOffset(payload, k);
        switch (d.rule) {
            .flags_size => put32(payload, at + 4, get32(payload, at + 4) | 1),
            .flags_sha => put32(payload, at + 4, get32(payload, at + 4) | 4),
            .flags_pending => put32(payload, at + 4, get32(payload, at + 4) | 8),
            .out_of_range => put32(payload, at + 28, 5),
            .order => {
                // The first: its successor's ordinal; the others: their
                // predecessor's.
                if (d.which == 0) {
                    put32(payload, at + 28, get32(payload, recordOffset(payload, referencedRecord(payload, 1)) + 28));
                } else {
                    put32(payload, at + 28, get32(payload, recordOffset(payload, referencedRecord(payload, d.which - 1)) + 28));
                }
            },
            .path => {
                const home = stringIndex(payload, "home");
                const school = stringIndex(payload, "school");
                put32(payload, at, if (get32(payload, at) == home) school else home);
            },
        }
    }

    fn expected(d: Damage) anyerror {
        return switch (d.rule) {
            .flags_size, .flags_sha, .flags_pending => error.StateReferenceFlags,
            .out_of_range => error.StateReferenceOutOfRange,
            .order => error.StateReferenceOrder,
            .path => error.StateReferencePath,
        };
    }
};

fn damageApply(d: Damage, payload: []u8) anyerror!void {
    return d.apply_(payload);
}

test "S6-T9 state v3: the writer's state is HYBSTA03, every retained file referenced, the pending one full; it decodes to the files" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena();
    try initGeneration(&f, generation_roots);
    const metadata = try currentManifest(&f);
    try std.testing.expect(metadata.state_v3);
    const section = try f.out.readFileAlloc(io, metadata.state.?.file, a, .unlimited);
    try std.testing.expectEqualStrings("HYBSTA03", section[0..8]);
    const payload = section[state_section.header_length..];
    try std.testing.expectEqual(@as(u32, 6), get32(payload, 28));
    var referenced: usize = 0;
    for (0..6) |k| {
        if (get32(payload, recordOffset(payload, k) + 4) & (1 << 6) != 0) referenced += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), referenced);
    const state = (try incremental_state.load(a, io, f.out)).?;
    try std.testing.expectEqual(@as(usize, 6), state.files.len);
    for (state.files) |entry| {
        if (entry.status == .pending) {
            try std.testing.expectEqualStrings("p.txt", entry.path);
            continue;
        }
        for (generation_files, 0..) |file, i| {
            if (!std.mem.eql(u8, file[0], entry.root_id) or !std.mem.eql(u8, file[1], entry.path)) continue;
            const text = try std.fmt.allocPrint(a, "# File {d}\n\nharbour lantern number {d}\n", .{ i, i });
            try std.testing.expectEqualStrings(&std.fmt.bytesToHex(digest(text), .lower), entry.hash);
            try std.testing.expectEqual(@as(?u64, text.len), entry.size);
            break;
        } else return error.TestUnexpectedResult;
    }
}

test "S6-T9 state v3: each rule is refused at the next write (a carrying write) and at the pointer, first, middle and last record; files untouched, readers answer" {
    for ([_]usize{ 0, 2, 4 }) |which| {
        for ([_]@TypeOf(@as(Damage, undefined).rule){ .flags_size, .flags_sha, .flags_pending, .out_of_range, .order, .path }) |rule| {
            var f = try Fixture.init();
            defer f.deinit();
            const a = f.arena();
            try initGeneration(&f, generation_roots);
            const damage = Damage{ .which = which, .rule = rule };
            try rewriteState(&f, damage, damageApply);
            const before = try f.listing();
            if (f.apply_(carrying_write)) |_| {
                std.debug.print("{s} at {d}: the write was not refused\n", .{ @tagName(rule), which });
                return error.TestUnexpectedResult;
            } else |err| {
                if (err != damage.expected()) {
                    std.debug.print("{s} at {d}: {s}\n", .{ @tagName(rule), which, @errorName(err) });
                    return error.TestUnexpectedResult;
                }
            }
            try std.testing.expectEqualStrings(before, try f.listing());
            try std.testing.expectError(damage.expected(), incremental_state.load(a, io, f.out));
            try std.testing.expectError(damage.expected(), incremental_state.loadBound(a, io, f.out));
            // An open never reads the state: the generation still answers.
            const engine = try snapshot_open.open(a, io, f.out);
            try std.testing.expectEqual(@as(u64, 1), engine.generation);
        }
    }
}

test "S6-T9 state v3 S2: references in a generation with no source section are refused at the next write and at the pointer, first, middle and last record" {
    const unretained =
        \\[{"root_id":"home","kind":"host","retain_source":false},{"root_id":"school","kind":"host","retain_source":false}]
    ;
    for ([_]usize{ 0, 2, 5 }) |k| {
        var f = try Fixture.init();
        defer f.deinit();
        const a = f.arena();
        try initGeneration(&f, unretained);
        var metadata = try currentManifest(&f);
        try std.testing.expect(!metadata.hasSource());
        // The writer referenced nothing (no source records); a reference
        // crafted for file k (its own hash, size and record path).
        const state = (try incremental_state.loadBound(a, io, f.out)).?;
        const refs = try a.alloc(?SourceRef, state.files.len);
        @memset(refs, null);
        const entry = state.files[k];
        try std.testing.expect(entry.status == .indexed);
        var raw: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&raw, entry.hash);
        refs[k] = .{ .ordinal = 0, .path = try std.fmt.allocPrint(a, "{s}/{s}", .{ entry.root_id, entry.path }), .sha256 = raw, .length = entry.size.? };
        const section = try incremental_state.encodeSectionRefs(a, state, refs);
        try f.out.writeFile(io, .{ .sub_path = metadata.state.?.file, .data = section });
        metadata = try manifest.withState(metadata, metadata.state.?.file, section);
        const buffer = try a.alloc(u8, try manifest.encodedLength(metadata));
        try publication.writeAtomicFile(f.out, io, publication.current_manifest_file, try manifest.encode(metadata, buffer), true);
        const before = try f.listing();
        try std.testing.expectError(error.StateReferenceWithoutSource, f.apply_(carrying_write));
        try std.testing.expectEqualStrings(before, try f.listing());
        try std.testing.expectError(error.StateReferenceWithoutSource, incremental_state.load(a, io, f.out));
        _ = try snapshot_open.open(a, io, f.out);
    }
}

test "S6-T9 state v3: the section version against flag bit 8 (M3) is refused at the next write; a HYBSTA02 section under a manifest without it is read" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena();
    try initGeneration(&f, generation_roots);
    var metadata = try currentManifest(&f);
    const name = metadata.state.?.file;
    const original = try f.out.readFileAlloc(io, name, a, .unlimited);
    const state = (try incremental_state.loadBound(a, io, f.out)).?;
    const v2 = try incremental_state.encodeSection(a, state);
    // HYBSTA02 under bit 8.
    try f.out.writeFile(io, .{ .sub_path = name, .data = v2 });
    var forced = try manifest.withState(metadata, name, v2);
    forced.state_v3 = true;
    var buffer = try a.alloc(u8, try manifest.encodedLength(forced));
    try publication.writeAtomicFile(f.out, io, publication.current_manifest_file, try manifest.encode(forced, buffer), true);
    try std.testing.expectError(error.StateSectionVersionMismatch, f.apply_(carrying_write));
    // HYBSTA03 without bit 8.
    try f.out.writeFile(io, .{ .sub_path = name, .data = original });
    forced = try manifest.withState(metadata, name, original);
    forced.state_v3 = false;
    buffer = try a.alloc(u8, try manifest.encodedLength(forced));
    try publication.writeAtomicFile(f.out, io, publication.current_manifest_file, try manifest.encode(forced, buffer), true);
    try std.testing.expectError(error.StateSectionVersionMismatch, f.apply_(carrying_write));
    // HYBSTA02 without bit 8 (a v2.5 generation's state): read, and the
    // write publishes HYBSTA03.
    try f.out.writeFile(io, .{ .sub_path = name, .data = v2 });
    metadata = try manifest.withState(metadata, name, v2);
    try std.testing.expect(!metadata.state_v3);
    buffer = try a.alloc(u8, try manifest.encodedLength(metadata));
    try publication.writeAtomicFile(f.out, io, publication.current_manifest_file, try manifest.encode(metadata, buffer), true);
    switch (try f.apply_(carrying_write)) {
        .ok => {},
        .failed => return error.TestUnexpectedResult,
    }
    const after = try currentManifest(&f);
    try std.testing.expect(after.state_v3);
    try std.testing.expectEqualStrings("HYBSTA03", (try f.out.readFileAlloc(io, after.state.?.file, a, .unlimited))[0..8]);
}

test "S6-T9 manifest v2.6 M1 and M2: bit 8 without a state section, bit 9 without file-name sections, are refused at decode" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena();
    try initGeneration(&f, generation_roots);
    const bytes = try f.out.readFileAlloc(io, publication.current_manifest_file, a, .unlimited);
    const metadata = try manifest.decode(bytes);
    try std.testing.expect(metadata.state_v3 and !metadata.catalog_v6 and metadata.filename == null);
    var no_state = metadata;
    no_state.state = null;
    try std.testing.expectError(error.StateVersionFlagWithoutSection, manifest.encodedLength(no_state));
    no_state.state_v3 = false;
    const plain = try a.alloc(u8, try manifest.encodedLength(no_state));
    const encoded = try manifest.encode(no_state, plain);
    // Bit 8, then bit 9, set in the encoded bytes and the checksum resealed.
    for ([_]struct { bit: u16, err: anyerror }{ .{ .bit = manifest.flag_state_v3, .err = error.StateVersionFlagWithoutSection }, .{ .bit = manifest.flag_catalog_v6, .err = error.CatalogVersionFlagWithoutSection } }) |case| {
        const copy = try a.dupe(u8, encoded);
        std.mem.writeInt(u16, copy[10..12], std.mem.readInt(u16, copy[10..12], .little) | case.bit, .little);
        const header_len = manifest.header_length_v2;
        std.mem.writeInt(u64, copy[header_len - 8 ..][0..8], checksum.compute(.fnv1a64, copy[0 .. header_len - 8], copy[header_len..]), .little);
        try std.testing.expectError(case.err, manifest.decode(copy));
    }
    var no_catalog = metadata;
    no_catalog.catalog_v6 = true;
    try std.testing.expectError(error.CatalogVersionFlagWithoutSection, manifest.encodedLength(no_catalog));
}

// ------------------------------------- the pointer's source table checks ---

fn resealed(bytes: []u8, header_length: usize) void {
    const flags = std.mem.readInt(u16, bytes[10..12], .little);
    const value = checksum.compute(checksum.kindOfFlags(flags), bytes[0 .. header_length - 8], bytes[header_length..]);
    std.mem.writeInt(u64, bytes[header_length - 8 ..][0..8], value, .little);
}

const TableDamage = enum { documents_missing, documents_longer, documents_flipped, documents_rebound, source_missing, source_longer, source_flipped, source_rebound, source_v1 };

test "S6-T9 state v3: the pointer resolves a HYBSTA03 state only against the documents and source sections its manifest binds; each check refused (InvalidState), the writer's open refusing the same damage" {
    for (std.enums.values(TableDamage)) |damage| {
        var f = try Fixture.init();
        defer f.deinit();
        const a = f.arena();
        try initGeneration(&f, generation_roots);
        const metadata = try currentManifest(&f);
        _ = (try incremental_state.load(a, io, f.out)).?;
        const is_documents = switch (damage) {
            .documents_missing, .documents_longer, .documents_flipped, .documents_rebound => true,
            else => false,
        };
        const name = if (is_documents) metadata.documents_file else metadata.source_file;
        // Documents record v5: a 56-byte header, its checksum over bytes 0-47 at 48;
        // `HYBSRC02`: 48 bytes, over 0-39 at 40.
        const header_length: usize = if (is_documents) @import("core").segment_v5.header_length else @import("core").source.header_length;
        const bytes = try f.out.readFileAlloc(io, name, a, .unlimited);
        switch (damage) {
            .documents_missing, .source_missing => try f.out.deleteFile(io, name),
            .documents_longer, .source_longer => try f.out.writeFile(io, .{ .sub_path = name, .data = try std.mem.concat(a, u8, &.{ bytes, "\x00" }) }),
            .documents_flipped, .source_flipped => {
                bytes[bytes.len - 1] ^= 0x01;
                try f.out.writeFile(io, .{ .sub_path = name, .data = bytes });
            },
            .documents_rebound => {
                // A letter of a chunk's text changed, the section resealed:
                // a valid section that is not the one the manifest binds.
                const at = std.mem.indexOf(u8, bytes[header_length..], "harbour").? + header_length;
                bytes[at] = 'H';
                resealed(bytes, header_length);
                try f.out.writeFile(io, .{ .sub_path = name, .data = bytes });
            },
            .source_v1 => {
                // A whole `HYBSRC01` section in the source's place, bound by
                // the manifest (its size and checksum): the pointer's table
                // must be `HYBSRC02` under bit 6.
                const v1 = try @import("core").source.encode(a, &.{.{ .path = "home/x.md", .bytes = "x\n" }});
                try f.out.writeFile(io, .{ .sub_path = name, .data = v1 });
                var rebound = metadata;
                rebound.source_bytes = v1.len;
                rebound.source_checksum = (try @import("core").source.inspect(v1)).checksum;
                const buffer = try a.alloc(u8, try manifest.encodedLength(rebound));
                try publication.writeAtomicFile(f.out, io, publication.current_manifest_file, try manifest.encode(rebound, buffer), true);
            },
            .source_rebound => {
                // Record 0's SHA-256 changed, the section resealed.
                const text = "# File 0\n\nharbour lantern number 0\n";
                const at = std.mem.indexOf(u8, bytes[header_length..], &digest(text)).? + header_length;
                bytes[at] ^= 0x01;
                resealed(bytes, header_length);
                try f.out.writeFile(io, .{ .sub_path = name, .data = bytes });
            },
        }
        if (incremental_state.load(a, io, f.out)) |_| {
            std.debug.print("{s}: resolved\n", .{@tagName(damage)});
            return error.TestUnexpectedResult;
        } else |err| try std.testing.expectEqual(error.InvalidState, err);
        try std.testing.expectError(error.InvalidState, incremental_state.loadBound(a, io, f.out));
        // The writer's own open refuses a damaged section too (its own
        // errors), the files untouched; a missing section is its recovery
        // case since S4-T2 (`missing_section`: the generation is rebuilt
        // from what the request names), not this task's.
        if (damage == .documents_missing or damage == .source_missing) continue;
        const before = try f.listing();
        if (f.apply_(carrying_write)) |_| {
            std.debug.print("{s}: the write was not refused\n", .{@tagName(damage)});
            return error.TestUnexpectedResult;
        } else |_| {}
        try std.testing.expectEqualStrings(before, try f.listing());
    }
}

test "S6-T9 manifest v2.6 M4 at the writer's check: validateFilenameSections refuses a record v6 catalog without bit 9 and a v3 catalog under it" {
    const compat = @import("compat_98c4a2b_test.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fresh = try compat.freshIndex(a, tmp, "fresh");
    defer fresh.close(io);
    const metadata = try manifest.decode(try fresh.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    const f = metadata.filename.?;
    const catalog = try fresh.readFileAlloc(io, f.catalog_file, a, .unlimited);
    const lexical = try fresh.readFileAlloc(io, f.lexical_file, a, .unlimited);
    try manifest.validateFilenameSections(metadata, catalog, lexical);
    var without = metadata;
    without.catalog_v6 = false;
    try std.testing.expectError(error.FilenameCatalogVersionMismatch, manifest.validateFilenameSections(without, catalog, lexical));
    const v3 = try compat.catalogAsV3(a, fresh);
    const v3_metadata = try manifest.withFilename(without, f.catalog_file, f.lexical_file, v3, lexical);
    try std.testing.expect(!v3_metadata.catalog_v6);
    try manifest.validateFilenameSections(v3_metadata, v3, lexical);
    var under = v3_metadata;
    under.catalog_v6 = true;
    try std.testing.expectError(error.FilenameCatalogVersionMismatch, manifest.validateFilenameSections(under, v3, lexical));
}

test "S6-T9 state v3 bound: a payload with no slack (36 bytes a file, nothing else) is read at its count; one more file is refused before any allocation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Every string empty (one string, no text: the analyzer id and the one
    // root's id, label, kind and origin), five referenced files: the bytes
    // after the header are the one string length, the 24-byte root and
    // 5 x 36 record bytes, exactly the bound.
    var table: [5]SourceRef = undefined;
    var hexes: [5][64]u8 = undefined;
    var files: [5]Entry = undefined;
    for (&table, &hexes, &files, texts, 0..) |*ref, *hex, *entry, text, i| {
        const name = try std.fmt.allocPrint(a, "f{d}.md", .{i});
        ref.* = .{ .ordinal = @intCast(i), .path = try std.fmt.allocPrint(a, "/{s}", .{name}), .sha256 = digest(text), .length = text.len };
        hex.* = std.fmt.bytesToHex(ref.sha256, .lower);
        entry.* = .{ .root_id = "", .path = name, .hash = hex, .size = text.len, .chunks = 1 };
    }
    const empty_root = [_]incremental_state.Root{.{ .root_id = "", .label = "", .kind = "", .origin = "", .retain_source = true }};
    const state = incremental_state.State{ .generation = 1, .analyzer_id = "", .roots = &empty_root, .files = &files };
    var refs: [5]?SourceRef = undefined;
    for (&refs, table) |*slot, ref| slot.* = ref;
    const payload = try incremental_state.encodeBinaryRefs(a, state, &refs);
    try std.testing.expectEqual(@as(u32, 1), get32(payload, 20));
    try std.testing.expectEqual(incremental_state.binary_header_length + 4 + 24 + 5 * incremental_state.binary_ref_length, payload.len);
    try expectSameState(state, try incremental_state.decodeBinaryWith(a, payload, true, .{ .list = &table }));
    // Six files claimed: 4 + 24 + 6 x 36 > the 208 bytes there are; refused at the
    // count, before the first allocation (an allocator that fails at once
    // is never reached).
    const copy = try a.dupe(u8, payload);
    put32(copy, 28, 6);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.InvalidState, incremental_state.decodeBinaryWith(failing.allocator(), copy, true, .{ .list = &table }));
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    // Five claimed with one byte cut: refused at the same bound.
    var failing2 = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.InvalidState, incremental_state.decodeBinaryWith(failing2.allocator(), payload[0 .. payload.len - 1], true, .{ .list = &table }));
    try std.testing.expectEqual(@as(usize, 0), failing2.allocations);
}

test "S6-T9 state v3: a referenced record's label count past the label references, or its root past the strings, is InvalidState, first, middle and last record" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sample: Sample = undefined;
    sample.init();
    const labels = [_][]const u8{"kids"};
    for (&sample.files) |*entry| entry.required_labels = &labels;
    const refs = sample.refs();
    const payload = try incremental_state.encodeBinaryRefs(a, sample.state(), &refs);
    try expectSameState(sample.state(), try incremental_state.decodeBinaryWith(a, payload, true, sample.sourceTable()));
    const string_count = get32(payload, 20);
    for (positions) |k| {
        const at = recordOffset(payload, k);
        // Label count one more than the references left for this record.
        var copy = try a.dupe(u8, payload);
        put32(copy, at + 24, get32(copy, at + 24) + @as(u32, @intCast(5 - k)));
        try std.testing.expectError(error.InvalidState, incremental_state.decodeBinaryWith(a, copy, true, sample.sourceTable()));
        // Root string index at the string count (one past the last).
        copy = try a.dupe(u8, payload);
        put32(copy, at, string_count);
        try std.testing.expectError(error.InvalidState, incremental_state.decodeBinaryWith(a, copy, true, sample.sourceTable()));
        // Chunker string index at the string count.
        copy = try a.dupe(u8, payload);
        put32(copy, at + 20, string_count);
        try std.testing.expectError(error.InvalidState, incremental_state.decodeBinaryWith(a, copy, true, sample.sourceTable()));
    }
}

test "S6-T9 state v3 section header: HYBSTA03 at version 2 or 4 is UnsupportedVersion, the magics are not crossed, with the checksum recomputed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const state_section_module = @import("core").state_section;
    var sample: Sample = undefined;
    sample.init();
    const refs = sample.refs();
    const payload = try incremental_state.encodeBinaryRefs(a, sample.state(), &refs);
    const section = try state_section_module.encodeBinaryV3(a, payload);
    try std.testing.expectEqual(state_section_module.Form.binary_v3, (try state_section_module.inspect(section)).form);
    for ([_]u16{ 2, 4, 0, 0xffff }) |version| {
        const copy = try a.dupe(u8, section);
        std.mem.writeInt(u16, copy[8..10], version, .little);
        resealed(copy, state_section_module.header_length);
        try std.testing.expectError(error.UnsupportedVersion, state_section_module.inspect(copy));
    }
    // HYBSTA02's magic with version 3, and HYBSTA03's v2 counterpart.
    const v2_magic = try a.dupe(u8, section);
    @memcpy(v2_magic[0..8], "HYBSTA02");
    resealed(v2_magic, state_section_module.header_length);
    try std.testing.expectError(error.UnsupportedVersion, state_section_module.inspect(v2_magic));
    const v2 = try state_section_module.encodeBinary(a, payload);
    std.mem.writeInt(u16, v2[8..10], 3, .little);
    resealed(v2, state_section_module.header_length);
    try std.testing.expectError(error.UnsupportedVersion, state_section_module.inspect(v2));
}

test "S6-T9 state v3 writer bound: an entry offered the same source record as the reference before it keeps its full record (the ordinals strictly increase, S4)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sample: Sample = undefined;
    sample.init();
    // Entry 2 made a copy of entry 1 (same root, path, hash and size) and
    // offered entry 1's record: equal to the previous reference's ordinal.
    sample.files[2] = sample.files[1];
    var refs = sample.refs();
    refs[2] = refs[1];
    const payload = try incremental_state.encodeBinaryRefs(a, sample.state(), &refs);
    // Records 0 and 1 referenced, record 2 the full 76 bytes, 3 and 4
    // referenced again (above ordinal 1).
    const at2 = recordOffset(payload, 2);
    try std.testing.expectEqual(@as(u32, 0), get32(payload, at2 + 4) & 0x40);
    for ([_]usize{ 0, 1, 3, 4 }) |k| try std.testing.expect(get32(payload, recordOffset(payload, k) + 4) & 0x40 != 0);
    try expectSameState(sample.state(), try incremental_state.decodeBinaryWith(a, payload, true, sample.sourceTable()));
    // The bound's other side: record 1 (ordinal 1, one above record 0's)
    // was taken as a reference, checked above.
}

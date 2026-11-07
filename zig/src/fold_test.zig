//! S5-T4: K (`fold.zig`, fold-groups-v1) against the Python mirror's golden
//! (`fixtures/analyzer-v3-golden.json`, `scripts/gen_analyzer_v3_golden.py`):
//! every listed term's pieces, byte for byte, and the fold table's shape.
const std = @import("std");
const fold = @import("fold.zig");
const tables = @import("unicode_tables.zig");

const golden_path = "../fixtures/analyzer-v3-golden.json";

test {
    _ = fold;
}

fn expectPieces(term: []const u8, want: []const std.json.Value) !void {
    const a = std.testing.allocator;
    const got = try fold.keyTerms(a, term);
    defer fold.freePieces(a, got);
    var ok = got.len == want.len;
    if (ok) for (got, want) |g, w| {
        if (!std.mem.eql(u8, g, w.string)) ok = false;
    };
    if (!ok) {
        std.debug.print("K({s}): got {d} pieces:", .{ term, got.len });
        for (got) |g| std.debug.print(" [{s}]", .{g});
        std.debug.print("; want {d}:", .{want.len});
        for (want) |w| std.debug.print(" [{s}]", .{w.string});
        std.debug.print("\n", .{});
        return error.TestExpectedEqual;
    }
}

test "K equals the Python mirror's golden on every term, byte for byte" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, golden_path, a, .unlimited);
    const golden = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    try std.testing.expectEqualStrings(fold.policy_id, golden.object.get("policy").?.string);
    try std.testing.expectEqualStrings(tables.unicode_version, golden.object.get("unicode").?.string);
    const same = golden.object.get("same").?.array.items;
    const changed = golden.object.get("changed").?.array.items;
    const count = golden.object.get("count").?.object;
    try std.testing.expectEqual(count.get("same").?.integer, @as(i64, @intCast(same.len)));
    try std.testing.expectEqual(count.get("changed").?.integer, @as(i64, @intCast(changed.len)));
    try std.testing.expectEqual(count.get("terms").?.integer, @as(i64, @intCast(same.len + changed.len)));
    var failures: usize = 0;
    for (same) |term| {
        const one = [_]std.json.Value{term};
        expectPieces(term.string, &one) catch {
            failures += 1;
        };
    }
    for (changed) |row| {
        const pair = row.array.items;
        expectPieces(pair[0].string, pair[1].array.items) catch {
            failures += 1;
        };
    }
    if (failures != 0) {
        std.debug.print("{d} of {d} terms differ from the golden\n", .{ failures, same.len + changed.len });
        return error.TestExpectedEqual;
    }
    std.debug.print("S5-T4 K golden: {d} terms ({d} same, {d} changed) equal\n", .{ same.len + changed.len, same.len, changed.len });
}

test "the fold table is sorted and every output is valid UTF-8 in the pool" {
    try std.testing.expectEqual(tables.fold_from.len, tables.fold_to.len);
    for (tables.fold_from[1..], tables.fold_from[0 .. tables.fold_from.len - 1]) |next, prev| try std.testing.expect(prev < next);
    try std.testing.expectEqual(@as(usize, tables.fold_pool.len), tables.fold_offsets[tables.fold_offsets.len - 1]);
    for (tables.fold_to) |k| {
        const out = tables.fold_pool[tables.fold_offsets[k]..tables.fold_offsets[k + 1]];
        try std.testing.expect(out.len > 0);
        try std.testing.expect(std.unicode.utf8ValidateSlice(out));
    }
}

//! S5-T5: R (`verb_forms.zig`, fold-groups-v2) against the Python mirror's
//! golden (`fixtures/verb-forms-golden.json`, `scripts/gen_verb_forms_golden.py`):
//! every listed term's bases and forms byte for byte, every `off` term without
//! one, and the digest over every term of K's golden and R's traps.
const std = @import("std");
const fold = @import("fold.zig");
const verb_forms = @import("verb_forms.zig");

const golden_path = "../fixtures/verb-forms-golden.json";
const k_golden_path = "../fixtures/analyzer-v3-golden.json";

test {
    _ = verb_forms;
}

/// R on `term`: false when it does not apply; else `bases` and `forms` hold it.
fn rOf(keyer: *fold.Keyer, word: *std.ArrayList(u8), term: []const u8, bases: *verb_forms.Words, forms: *verb_forms.Words) !bool {
    const u = (try keyer.appendWord(term, word)) orelse {
        bases.len = 0;
        forms.len = 0;
        return false;
    };
    verb_forms.bases(u, bases);
    verb_forms.forms(u, term, forms);
    return true;
}

fn equalWords(got: *const verb_forms.Words, want: []const std.json.Value) bool {
    if (got.len != want.len) return false;
    for (want, 0..) |w, i| if (!std.mem.eql(u8, got.get(i), w.string)) return false;
    return true;
}

fn byBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

test "R equals the Python mirror's golden on every term, byte for byte" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, golden_path, a, .unlimited);
    const golden = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    try std.testing.expectEqualStrings(fold.policy_id, golden.object.get("policy").?.string);
    const listed = golden.object.get("listed").?.array.items;
    const off = golden.object.get("off").?.array.items;
    const count = golden.object.get("count").?.object;
    try std.testing.expectEqual(count.get("listed").?.integer, @as(i64, @intCast(listed.len)));
    try std.testing.expectEqual(count.get("off").?.integer, @as(i64, @intCast(off.len)));

    var keyer = fold.Keyer.init(std.testing.allocator);
    defer keyer.deinit();
    var word = std.ArrayList(u8).empty;
    defer word.deinit(std.testing.allocator);
    var bases = verb_forms.Words{};
    var forms = verb_forms.Words{};
    var failures: usize = 0;
    for (listed) |row| {
        const items = row.array.items;
        const term = items[0].string;
        const ok = (try rOf(&keyer, &word, term, &bases, &forms)) and equalWords(&bases, items[1].array.items) and equalWords(&forms, items[2].array.items);
        if (!ok) {
            failures += 1;
            if (failures <= 10) std.debug.print("R({s}) differs: {d} bases, {d} forms\n", .{ term, bases.len, forms.len });
        }
    }
    for (off) |term| {
        if (try rOf(&keyer, &word, term.string, &bases, &forms)) {
            failures += 1;
            if (failures <= 10) std.debug.print("R({s}) applies; the golden says off\n", .{term.string});
        }
    }

    // The digest: K's golden's terms and every listed or off term, sorted.
    const k_bytes = try std.Io.Dir.cwd().readFileAlloc(io, k_golden_path, a, .unlimited);
    const k_golden = try std.json.parseFromSliceLeaky(std.json.Value, a, k_bytes, .{});
    var seen = std.StringHashMap(void).init(a);
    for (k_golden.object.get("same").?.array.items) |t| try seen.put(t.string, {});
    for (k_golden.object.get("changed").?.array.items) |row| try seen.put(row.array.items[0].string, {});
    for (listed) |row| try seen.put(row.array.items[0].string, {});
    for (off) |t| try seen.put(t.string, {});
    const every = try a.alloc([]const u8, seen.count());
    var it = seen.keyIterator();
    var n: usize = 0;
    while (it.next()) |k| : (n += 1) every[n] = k.*;
    std.mem.sort([]const u8, every, {}, byBytes);
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    var applies: usize = 0;
    var lookups: usize = 0;
    for (every) |term| {
        const on = try rOf(&keyer, &word, term, &bases, &forms);
        if (on) applies += 1;
        lookups += forms.len;
        sha.update(term);
        sha.update("\t");
        for (0..bases.len) |i| {
            if (i > 0) sha.update(" ");
            sha.update(bases.get(i));
        }
        sha.update("\t");
        for (0..forms.len) |i| {
            if (i > 0) sha.update(" ");
            sha.update(forms.get(i));
        }
        sha.update("\n");
    }
    var out: [32]u8 = undefined;
    sha.final(&out);
    const hex = std.fmt.bytesToHex(out, .lower);
    const digest = golden.object.get("digest").?.object;
    try std.testing.expectEqual(digest.get("terms").?.integer, @as(i64, @intCast(every.len)));
    try std.testing.expectEqual(digest.get("applies").?.integer, @as(i64, @intCast(applies)));
    try std.testing.expectEqual(digest.get("lookups").?.integer, @as(i64, @intCast(lookups)));
    try std.testing.expectEqualStrings(digest.get("sha256").?.string, &hex);
    if (failures != 0) {
        std.debug.print("{d} of {d} listed terms differ from the golden\n", .{ failures, listed.len + off.len });
        return error.TestExpectedEqual;
    }
    std.debug.print("S5-T5 R golden: {d} listed + {d} off equal; digest over {d} terms ({d} applies, {d} lookups) equal\n", .{ listed.len, off.len, every.len, applies, lookups });
}

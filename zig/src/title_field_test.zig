//! S5-T2: the title field's tokens and grouping (`title_field.zig`). The
//! expected tokens are the Python reference's (`core._title_tokens`).
const std = @import("std");
const filename_field = @import("filename_field.zig");
const hybrid = @import("hybrid.zig");
const manifest = @import("manifest.zig");
const scope = @import("scope.zig");
const title_field = @import("title_field.zig");

const roots = [_]manifest.RootEntry{
    .{ .root_id = "r-home", .label = "home", .kind = "local", .retain_source = true },
    .{ .root_id = scope.legacy_root_id, .label = "folder", .kind = "local", .retain_source = true },
};

fn expectTokens(path: []const u8, expected: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try title_field.tokens(arena.allocator(), &roots, path);
    try std.testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try std.testing.expectEqualStrings(e, g);
}

test "title tokens: folders then the stem, never the root id" {
    try expectTokens("r-home/Music/Recorder-Practice.md", &.{ "music", "recorder", "practice" });
    try expectTokens("r-home/garden/garden/garden-diary.md", &.{ "garden", "garden", "garden", "diary" });
    try expectTokens("r-home/a/archive.tar.gz", &.{ "a", "archive", "tar" });
}

test "title tokens: a legacy-root or unrooted path is taken whole" {
    try expectTokens("loose/Kids_Questions.txt", &.{ "loose", "kids", "questions" });
    const legacy_only = [_]manifest.RootEntry{scope.legacy_roots[0]};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try title_field.tokens(arena.allocator(), &legacy_only, "r-home/notes/plan.md");
    const expected = [_][]const u8{ "r", "home", "notes", "plan" };
    try std.testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try std.testing.expectEqualStrings(e, g);
}

test "title stem follows Path.stem, not the filename field's stem" {
    try std.testing.expectEqualStrings(".bashrc", title_field.pathStem(".bashrc"));
    try std.testing.expectEqualStrings("notes.", title_field.pathStem("notes."));
    try std.testing.expectEqualStrings("archive.tar", title_field.pathStem("archive.tar.gz"));
    try std.testing.expectEqualStrings("plain", title_field.pathStem("plain"));
    try expectTokens("r-home/.bashrc", &.{"bashrc"});
    try expectTokens("r-home/notes.", &.{"notes"});
    // The filename field (S4-T2) keeps its own stem: a dot-first name is "".
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const docs = [_]hybrid.Document{.{ .id = "x", .text = "t", .path = "r-home/.bashrc", .start_line = 1, .end_line = 1 }};
    const catalog = try filename_field.group(arena.allocator(), &docs);
    try std.testing.expectEqualStrings("", catalog[0].text);
}

test "title tokens fold like analyzer-v2: Tamil NFC and NFD, full-width, accents" {
    try expectTokens("r-home/தமிழ்/வகுப்பு.md", &.{ "தமிழ்", "வகுப்பு" });
    // A decomposed accent (NFD) folds to the composed token.
    try expectTokens("r-home/Cafe\u{301}/menu.md", &.{ "café", "menu" });
    try expectTokens("r-home/Ｆｕｌｌ/Café-Straße.ﬁle.md", &.{ "ｆｕｌｌ", "café", "straße", "ﬁle" });
}

fn checkField(derived: title_field.Derived, documents: []const hybrid.Document) !void {
    const field = derived.field;
    try std.testing.expectEqual(documents.len, field.file_of.len);
    // Every chunk's file holds its path; each file's first chunk is its
    // anchor (smallest start line, end line, id).
    for (documents, field.file_of) |document, f| {
        const anchor = documents[field.files[f].first_chunk];
        try std.testing.expectEqualStrings(anchor.path, document.path);
        try std.testing.expect(anchor.start_line <= document.start_line);
    }
    // The term table is sorted bytewise and every term is found.
    for (field.terms[0..field.terms.len -| 1], field.terms[@min(1, field.terms.len)..]) |a, b| {
        try std.testing.expect(std.mem.order(u8, field.termBytes(a), field.termBytes(b)) == .lt);
    }
    for (field.terms) |term| {
        const found = field.lookup(field.termBytes(term)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(term.postings_start, found.postings_start);
        const list = field.termPostings(term);
        for (list[0..list.len -| 1], list[@min(1, list.len)..]) |a, b| try std.testing.expect(a.file < b.file);
    }
    try std.testing.expectEqual(@as(?title_field.Term, null), field.lookup("absent"));
}

const in_order = [_]hybrid.Document{
    .{ .id = "g2", .text = "", .path = "r-home/garden/garden-diary.md", .start_line = 9, .end_line = 12 },
    .{ .id = "g1", .text = "", .path = "r-home/garden/garden-diary.md", .start_line = 1, .end_line = 8 },
    .{ .id = "h1", .text = "", .path = "r-home/house-rules.md", .start_line = 1, .end_line = 5 },
    .{ .id = "m1", .text = "", .path = "r-home/music/recorder-practice.md", .start_line = 1, .end_line = 4 },
};

test "grouping in one pass when the paths come in order" {
    const derived = try title_field.derive(std.testing.allocator, std.testing.allocator, &in_order, &roots);
    defer derived.deinit(std.testing.allocator);
    try std.testing.expect(derived.profile.in_order);
    try std.testing.expectEqual(@as(usize, 3), derived.profile.files);
    try std.testing.expectEqual(@as(usize, 2), derived.profile.distinct_folders);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 1, 2 }, derived.field.file_of);
    try std.testing.expectEqual(@as(u32, 1), derived.field.files[0].first_chunk);
    // garden x2 in file 0 (folder + stem), lengths 3, 2, 3.
    const garden = derived.field.lookup("garden").?;
    try std.testing.expectEqual(@as(u32, 1), garden.postings_len);
    try std.testing.expectEqual(title_field.Posting{ .file = 0, .frequency = 2 }, derived.field.termPostings(garden)[0]);
    try std.testing.expectEqual(@as(u32, 3), derived.field.files[0].length);
    try std.testing.expectEqual(@as(u32, 2), derived.field.files[1].length);
    try std.testing.expectEqual(@as(u64, 8), derived.field.total_length);
    try std.testing.expect(derived.field.lookup("r-home") == null and derived.field.lookup("home") == null);
    try checkField(derived, &in_order);
}

test "grouping falls back when a file's chunks are not adjacent" {
    // A file's chunks split by another file's: the one-pass grouping does
    // not apply; the fallback groups by path and keeps first-chunk order.
    const scattered = [_]hybrid.Document{
        .{ .id = "m1", .text = "", .path = "r-home/music/recorder-practice.md", .start_line = 1, .end_line = 4 },
        .{ .id = "g2", .text = "", .path = "r-home/garden/garden-diary.md", .start_line = 9, .end_line = 12 },
        .{ .id = "h1", .text = "", .path = "r-home/house-rules.md", .start_line = 1, .end_line = 5 },
        .{ .id = "g1", .text = "", .path = "r-home/garden/garden-diary.md", .start_line = 1, .end_line = 8 },
    };
    const derived = try title_field.derive(std.testing.allocator, std.testing.allocator, &scattered, &roots);
    defer derived.deinit(std.testing.allocator);
    try std.testing.expect(!derived.profile.in_order);
    try std.testing.expectEqual(@as(usize, 3), derived.profile.files);
    // Ordinals by each file's earliest chunk: music 0, garden 1, house 2.
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 1 }, derived.field.file_of);
    try std.testing.expectEqual(@as(u32, 3), derived.field.files[1].first_chunk);
    try checkField(derived, &scattered);
    // The same terms, frequencies and lengths as the in-order derive.
    const ordered = try title_field.derive(std.testing.allocator, std.testing.allocator, &in_order, &roots);
    defer ordered.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(ordered.field.term_bytes, derived.field.term_bytes);
    try std.testing.expectEqual(ordered.field.total_length, derived.field.total_length);
}

test "derive of no documents, and the scratch is released (testing allocator)" {
    const derived = try title_field.derive(std.testing.allocator, std.testing.allocator, &.{}, &roots);
    defer derived.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), derived.profile.files);
    try std.testing.expectEqual(@as(?title_field.Term, null), derived.field.lookup("x"));
}

test "derive marks its five stages in order" {
    const Recorder = struct {
        names: [8][]const u8 = undefined,
        count: usize = 0,
        pub fn mark(self: *@This(), comptime name: []const u8) void {
            self.names[self.count] = name;
            self.count += 1;
        }
    };
    var recorder = Recorder{};
    const derived = try title_field.deriveMarked(std.testing.allocator, std.testing.allocator, &in_order, &roots, &recorder);
    defer derived.deinit(std.testing.allocator);
    const expected = [_][]const u8{ "grouping", "folders", "stems", "postings", "lookup" };
    try std.testing.expectEqual(expected.len, recorder.count);
    for (expected, recorder.names[0..recorder.count]) |e, g| try std.testing.expectEqualStrings(e, g);
}

test "the ASCII token path agrees with analyzer_v2.tokenize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const analyzer_v2 = @import("analyzer_v2.zig");
    // Every ASCII byte between two letters, and seeded random ASCII strings
    // (some longer than the 256-byte run buffer), plus non-ASCII text.
    var texts = std.ArrayList([]const u8).empty;
    for (0..128) |c| try texts.append(a, try std.fmt.allocPrint(a, "Ab{c}Cd", .{@as(u8, @intCast(c))}));
    var prng = std.Random.DefaultPrng.init(0x55e2);
    const random = prng.random();
    for (0..2000) |n| {
        const len = if (n % 100 == 0) 300 + random.uintLessThan(usize, 200) else random.uintLessThan(usize, 40);
        const text = try a.alloc(u8, len);
        for (text) |*c| c.* = if (n % 100 == 0) "aZ09"[random.uintLessThan(usize, 4)] else random.uintLessThan(u8, 128);
        try texts.append(a, text);
    }
    try texts.appendSlice(a, &.{ "Café-Straße", "தமிழ்-வகுப்பு", "Ｆｕｌｌ", "Cafe\u{301}", "1\u{FE0F}\u{20E3}x", "", "---" });
    for (texts.items) |text| {
        const want = try analyzer_v2.tokenize(a, text);
        const got = try title_field.tokenizeText(a, text);
        try std.testing.expectEqual(want.len, got.len);
        for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
    }
}

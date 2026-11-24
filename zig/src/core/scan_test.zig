//! S6-T24: `scan.run` over a fake source (ADR 0006 section 16, "scan.zig unit tests"): every hit exactly once
//! across pages for every page size from 1 to 7, `max_hits_per_file` across a page boundary, context at a
//! file's edges, the 512-byte cut with offsets clipped, the BOM and CRLF, the three cursor refusals, an
//! injected clock that stops pages between files, inside a file and inside a line with nothing lost or
//! repeated on resume, and the `capacity` refusal of a page that completes nothing (ruling O-7), naming its
//! cause (rework 1, ruling 5); the clock starting before the pattern is parsed (rework 1, ruling 1).
const std = @import("std");
const pattern = @import("pattern.zig");
const scan = @import("scan.zig");

const testing = std.testing;

const Fake = struct {
    bytes: []const []const u8,
    /// Per file: what the read answers instead of the bytes (null: the bytes).
    outcomes: []const ?scan.Read = &.{},

    fn read(context: *anyopaque, allocator: std.mem.Allocator, file: scan.File) error{OutOfMemory}!scan.Read {
        _ = allocator;
        const self: *const Fake = @ptrCast(@alignCast(context));
        if (file.key < self.outcomes.len) if (self.outcomes[file.key]) |outcome| return outcome;
        return .{ .ok = self.bytes[file.key] };
    }
};

fn sourceOf(arena: std.mem.Allocator, fake: *Fake, paths: []const []const u8) !scan.Source {
    const files = try arena.alloc(scan.File, paths.len);
    for (files, paths, 0..) |*file, path, index| file.* = .{ .root_id = "r-legacy", .path = path, .key = index };
    return .{ .kind = .index, .generation = 7, .files = files, .context = fake, .read = Fake.read };
}

var io_clock = scan.IoClock{ .io = testing.io };

fn realClock() pattern.Clock {
    return io_clock.clock();
}

const CountingClock = struct {
    now_ns: u64 = 0,
    step: u64 = std.time.ns_per_ms,

    fn now(context: ?*anyopaque) u64 {
        const self: *CountingClock = @ptrCast(@alignCast(context.?));
        self.now_ns += self.step;
        return self.now_ns;
    }

    fn clock(self: *CountingClock) pattern.Clock {
        return .{ .context = self, .now = now };
    }
};

fn ok(outcome: scan.Outcome) !scan.Answer {
    return switch (outcome) {
        .ok => |answer| answer,
        .failed => |failure| {
            std.debug.print("refused: {s}\n", .{failure.message});
            return error.TestUnexpectedResult;
        },
    };
}

fn refusal(outcome: scan.Outcome) ![]const u8 {
    return switch (outcome) {
        .ok => error.TestUnexpectedResult,
        .failed => |failure| failure.message,
    };
}

const Totals = struct {
    hits: std.ArrayList([]const u8) = .empty,
    pages: usize = 0,
    files_matched: usize = 0,
    files_scanned: usize = 0,
    files_capped: usize = 0,
    bytes_scanned: u64 = 0,
    stopped_time: usize = 0,
};

/// Every page of `request` to the end, the hits as `path:line [offsets]`.
fn allPages(arena: std.mem.Allocator, request: scan.Request, src: scan.Source, clock: ?*CountingClock) !Totals {
    var totals = Totals{};
    var current = request;
    while (true) {
        const answer = try ok(try scan.run(arena, current, src, if (clock) |c| c.clock() else realClock()));
        totals.pages += 1;
        for (answer.hits) |hit| try totals.hits.append(arena, try std.fmt.allocPrint(arena, "{s}:{d} {any}", .{ hit.path, hit.line, hit.match_offsets }));
        totals.files_matched += answer.files_matched;
        totals.files_scanned += answer.files_scanned;
        totals.files_capped += answer.files_capped;
        totals.bytes_scanned += answer.bytes_scanned;
        if (answer.stopped == .time) {
            totals.stopped_time += 1;
            try testing.expect(answer.next_cursor != null);
        }
        const next = answer.next_cursor orelse break;
        if (current.cursor) |previous| try testing.expect(!std.mem.eql(u8, previous, next));
        current.cursor = next;
        if (totals.pages > 100_000) return error.TestUnexpectedResult;
    }
    return totals;
}

fn expectSameHits(expected: Totals, got: Totals) !void {
    try testing.expectEqual(expected.hits.items.len, got.hits.items.len);
    for (expected.hits.items, got.hits.items) |a, b| try testing.expectEqualStrings(a, b);
    try testing.expectEqual(expected.files_matched, got.files_matched);
    try testing.expectEqual(expected.files_scanned, got.files_scanned);
    try testing.expectEqual(expected.files_capped, got.files_capped);
    try testing.expectEqual(expected.bytes_scanned, got.bytes_scanned);
}

const corpus_paths = [_][]const u8{ "a.txt", "b/c.md", "b/d.txt", "e.txt", "empty.txt" };
const corpus_bytes = [_][]const u8{
    "one 12\ntwo\nthree 34 56\n",
    "# 7\nno digits\n\n8 and 9\n",
    "nothing here\r\n",
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n",
    "",
};

test "S6-T24 scan: every hit exactly once across pages, for every page size from 1 to 7" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = Fake{ .bytes = &corpus_bytes };
    const src = try sourceOf(arena, &fake, &corpus_paths);
    const whole = try allPages(arena, .{ .pattern = "\\d+", .mode = .regex, .page_size = 100 }, src, null);
    try testing.expectEqual(@as(usize, 1), whole.pages);
    try testing.expectEqual(@as(usize, 14), whole.hits.items.len);
    try testing.expectEqualStrings("a.txt:1 { { 4, 6 } }", whole.hits.items[0]);
    try testing.expectEqualStrings("a.txt:3 { { 6, 8 }, { 9, 11 } }", whole.hits.items[1]);
    try testing.expectEqual(@as(usize, 3), whole.files_matched);
    try testing.expectEqual(@as(usize, 5), whole.files_scanned);
    for (1..8) |size| {
        const paged = try allPages(arena, .{ .pattern = "\\d+", .mode = .regex, .page_size = size }, src, null);
        try expectSameHits(whole, paged);
    }
}

test "S6-T24 scan: max_hits_per_file across a page boundary counts the file capped once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = Fake{ .bytes = &corpus_bytes };
    const src = try sourceOf(arena, &fake, &corpus_paths);
    const request = scan.Request{ .pattern = "\\d", .mode = .regex, .max_hits_per_file = 3, .page_size = 2 };
    const paged = try allPages(arena, request, src, null);
    // a.txt has 2 hit lines, b/c.md 2, e.txt 10 (capped at 3).
    try testing.expectEqual(@as(usize, 7), paged.hits.items.len);
    try testing.expectEqual(@as(usize, 1), paged.files_capped);
    try testing.expectEqual(@as(usize, 3), paged.files_matched);
    var one = request;
    one.page_size = 100;
    try expectSameHits(try allPages(arena, one, src, null), paged);
    // Exactly max_hits_per_file hits and no more: not capped.
    var exact = request;
    exact.max_hits_per_file = 10;
    try testing.expectEqual(@as(usize, 0), (try allPages(arena, exact, src, null)).files_capped);
}

test "S6-T24 scan: context at a file's edges, the 512-byte cut on a code-point boundary, BOM and CRLF" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var long = std.ArrayList(u8).empty;
    try long.appendSlice(arena, "x" ** 510);
    try long.appendSlice(arena, "நாள் needle"); // ந is 3 bytes: 510 + 3 > 512, so the cut is at 510
    try long.appendSlice(arena, "\r\n");
    const bytes = [_][]const u8{
        "\xef\xbb\xbfneedle first\r\nmiddle\r\nneedle last",
        long.items,
        "xx needle " ++ "y" ** 600 ++ "\n",
    };
    var fake = Fake{ .bytes = &bytes };
    const src = try sourceOf(arena, &fake, &.{ "bom.txt", "long.txt", "wide.txt" });
    const answer = try ok(try scan.run(arena, .{ .pattern = "needle", .context_lines = 2 }, src, realClock()));
    try testing.expectEqual(@as(usize, 4), answer.hits.len);
    const first = answer.hits[0];
    try testing.expectEqual(@as(u32, 1), first.line);
    try testing.expectEqualStrings("needle first", first.text); // no BOM, no CR
    try testing.expectEqual(@as(usize, 0), first.before.len);
    try testing.expectEqual(@as(usize, 2), first.after.len);
    try testing.expectEqualStrings("middle", first.after[0].text);
    const last = answer.hits[1];
    try testing.expectEqual(@as(u32, 3), last.line);
    try testing.expectEqual(@as(usize, 2), last.before.len);
    try testing.expectEqual(@as(usize, 0), last.after.len);
    try testing.expectEqualSlices([2]u32, &.{.{ 0, 6 }}, last.match_offsets);
    const cut = answer.hits[2];
    try testing.expectEqual(@as(usize, 510), cut.text.len);
    try testing.expect(cut.text_truncated);
    try testing.expectEqual(@as(usize, 0), cut.match_offsets.len); // the match starts past the text
    const wide = answer.hits[3];
    try testing.expectEqual(@as(usize, 512), wide.text.len);
    try testing.expectEqualSlices([2]u32, &.{.{ 3, 9 }}, wide.match_offsets);
    // A match that runs past the cut ends at the cut.
    const clipped = try ok(try scan.run(arena, .{ .pattern = "y+", .mode = .regex }, src, realClock()));
    try testing.expectEqualSlices([2]u32, &.{.{ 10, 512 }}, clipped.hits[0].match_offsets);
}

test "S6-T24 scan: cursors: stale across a publish, refused on another request, malformed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = Fake{ .bytes = &corpus_bytes };
    const src = try sourceOf(arena, &fake, &corpus_paths);
    const request = scan.Request{ .pattern = "\\d", .mode = .regex, .page_size = 1 };
    const first = try ok(try scan.run(arena, request, src, realClock()));
    const cursor = first.next_cursor.?;
    var next = request;
    next.cursor = cursor;
    _ = try ok(try scan.run(arena, next, src, realClock()));
    // Another generation: stale, as find.
    var published = src;
    published.generation = 8;
    try testing.expectEqualStrings("stale cursor", try refusal(try scan.run(arena, next, published, realClock())));
    // An index cursor sent to a folder scan: stale.
    var folder = src;
    folder.kind = .folder;
    try testing.expectEqualStrings("stale cursor", try refusal(try scan.run(arena, next, folder, realClock())));
    // Another pattern, case, scope or cap: not this request's. The page size and the budget may change.
    const others = [_]scan.Request{
        .{ .pattern = "\\d+", .mode = .regex, .cursor = cursor },
        .{ .pattern = "\\d", .mode = .regex, .case = .sensitive, .cursor = cursor },
        .{ .pattern = "\\d", .mode = .regex, .path_prefix = "b/", .cursor = cursor },
        .{ .pattern = "\\d", .mode = .regex, .max_hits_per_file = 2, .cursor = cursor },
        .{ .pattern = "\\d", .mode = .regex, .scope_labels = &.{"adults"}, .cursor = cursor },
        .{ .pattern = "\\d", .mode = .regex, .scope_roots = &.{"school"}, .cursor = cursor },
    };
    for (others) |other| try testing.expectEqualStrings("cursor does not belong to this request", try refusal(try scan.run(arena, other, src, realClock())));
    var resized = next;
    resized.page_size = 7;
    resized.time_budget_ms = 30_000;
    _ = try ok(try scan.run(arena, resized, src, realClock()));
    // Malformed.
    const hash_part = cursor[std.mem.indexOfScalar(u8, cursor, ':').? + 1 ..][0..16];
    const bad = [_][]const u8{
        "",
        "7",
        "7:0",
        try std.fmt.allocPrint(arena, "7:{s}:0:1", .{hash_part}),
        try std.fmt.allocPrint(arena, "7:{s}:0:1:0:0", .{hash_part}),
        try std.fmt.allocPrint(arena, "x:{s}:0:1:0", .{hash_part}),
        "7:zz:0:1:0",
        try std.fmt.allocPrint(arena, "7:{s}:0:0:0", .{hash_part}),
        try std.fmt.allocPrint(arena, "7:{s}:-1:1:0", .{hash_part}),
        try std.fmt.allocPrint(arena, "7:{s}:99:1:0", .{hash_part}),
        try std.fmt.allocPrint(arena, "7:{s}:0:1:51", .{hash_part}),
        // Rework 1, ruling 8: the schema's digits only (no sign, no `_`, lowercase hexadecimal).
        try std.fmt.allocPrint(arena, "7:{s}:+0:1:0", .{hash_part}),
        try std.fmt.allocPrint(arena, "+7:{s}:0:1:0", .{hash_part}),
        try std.fmt.allocPrint(arena, "7:{s}:0:1_0:0", .{hash_part}),
        try std.fmt.allocPrint(arena, "7:{s}:-0:1:0", .{hash_part}),
        try std.fmt.allocPrint(arena, "7:{s}:0:1:0", .{try std.ascii.allocUpperString(arena, hash_part)}),
    };
    for (bad) |text| {
        var malformed = request;
        malformed.cursor = text;
        testing.expectEqualStrings("malformed cursor", try refusal(try scan.run(arena, malformed, src, realClock()))) catch |err| {
            std.debug.print("cursor {s}\n", .{text});
            return err;
        };
    }
}

test "S6-T24 scan: field ranges are refused with find's message form" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = Fake{ .bytes = &corpus_bytes };
    const src = try sourceOf(arena, &fake, &corpus_paths);
    const cases = [_]struct { scan.Request, []const u8 }{
        .{ .{ .pattern = "a", .page_size = 0 }, "page_size must be 1..100" },
        .{ .{ .pattern = "a", .page_size = 101 }, "page_size must be 1..100" },
        .{ .{ .pattern = "a", .context_lines = 21 }, "context_lines must be 0..20" },
        .{ .{ .pattern = "a", .max_hits_per_file = 0 }, "max_hits_per_file must be 1..1000" },
        .{ .{ .pattern = "a", .max_hits_per_file = 1001 }, "max_hits_per_file must be 1..1000" },
        .{ .{ .pattern = "a", .time_budget_ms = 0 }, "time_budget_ms must be 1..30000" },
        .{ .{ .pattern = "a", .time_budget_ms = 30_001 }, "time_budget_ms must be 1..30000" },
        .{ .{ .pattern = "a", .name_glob = "" }, "name_glob must be 1..255 bytes with no /" },
        .{ .{ .pattern = "a", .name_glob = "b/*.md" }, "name_glob must be 1..255 bytes with no /" },
        .{ .{ .pattern = "" }, "pattern must be 1..1024 bytes" },
        .{ .{ .pattern = "a(", .mode = .regex }, "pattern not supported at byte 1: a group is not closed" },
    };
    for (cases) |case| try testing.expectEqualStrings(case[1], try refusal(try scan.run(arena, case[0], src, realClock())));
}

test "S6-T24 scan: path_prefix and name_glob narrow the files, and what cannot be read is counted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const outcomes = [_]?scan.Read{ null, .too_large, .unreadable, null, null };
    var fake = Fake{ .bytes = &corpus_bytes, .outcomes = &outcomes };
    const src = try sourceOf(arena, &fake, &corpus_paths);
    const all = try ok(try scan.run(arena, .{ .pattern = "\\d", .mode = .regex, .page_size = 100 }, src, realClock()));
    try testing.expectEqual(@as(usize, 1), all.not_scanned.too_large);
    try testing.expectEqual(@as(usize, 1), all.not_scanned.unreadable);
    try testing.expect(all.truncated);
    try testing.expectEqual(@as(usize, 3), all.files_scanned);
    const glob = try ok(try scan.run(arena, .{ .pattern = "\\d", .mode = .regex, .name_glob = "?.txt" }, src, realClock()));
    try testing.expectEqual(@as(usize, 2), glob.files_scanned); // a.txt and e.txt; d.txt cannot be read
    try testing.expect(glob.truncated);
    const prefix = try ok(try scan.run(arena, .{ .pattern = "\\d", .mode = .regex, .path_prefix = "e" }, src, realClock()));
    try testing.expectEqual(@as(usize, 2), prefix.files_scanned);
    try testing.expect(!prefix.truncated);
    try testing.expect(scan.globMatches("*.md", "notes.md"));
    try testing.expect(scan.globMatches("தீபாவளி-????????.txt", "தீபாவளி-பட்டியல்.txt"));
    try testing.expect(!scan.globMatches("*.md", "notes.md.bak"));
    try testing.expect(scan.globMatches("*a*b*", "xxaYYbzz"));
    try testing.expect(!scan.globMatches("a?", "a"));
    try testing.expect(scan.globMatches("*", ""));
}

fn manyLines(arena: std.mem.Allocator, count: usize, long_every: usize, long_cps: usize) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (0..count) |i| {
        if (long_every > 0 and i % long_every == long_every - 1) {
            try out.appendNTimes(arena, 'a', long_cps);
            try out.appendSlice(arena, " 42\n");
        } else try out.print(arena, "line {d} of words\n", .{i});
    }
    return out.items;
}

test "S6-T24 scan: an injected clock stops pages between files, inside a file and inside a line; resuming loses and repeats nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = [_][]const u8{
        try manyLines(arena, 1000, 0, 0),
        try manyLines(arena, 300, 50, 9000),
        "1\n", "2\n", "3\n", "4\n", "5\n", "6\n",
        try manyLines(arena, 2000, 7, 5000),
    };
    var fake = Fake{ .bytes = &bytes };
    const src = try sourceOf(arena, &fake, &.{ "a", "b", "c1", "c2", "c3", "c4", "c5", "c6", "d" });
    for ([_][]const u8{ "\\d+", "4", "(a|b)+ 4" }) |text| {
        const request = scan.Request{ .pattern = text, .mode = .regex, .page_size = 100, .max_hits_per_file = 1000, .time_budget_ms = 3 };
        var unhurried = request;
        unhurried.time_budget_ms = 30_000;
        const whole = try allPages(arena, unhurried, src, null);
        var clock = CountingClock{};
        const hurried = try allPages(arena, request, src, &clock);
        try expectSameHits(whole, hurried);
        std.debug.print("S6-T24 budget: {s}: {d} pages, {d} stopped by time, {d} hits\n", .{ text, hurried.pages, hurried.stopped_time, hurried.hits.items.len });
        try testing.expect(hurried.stopped_time >= 2);
    }
}

test "S6-T24 scan: a line that alone outlasts the budget is refused with capacity, never returned as progress (ruling O-7)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = [_][]const u8{ "short 1\n" ++ "a" ** 400_000 ++ "\n", "x\n" };
    var fake = Fake{ .bytes = &bytes };
    const src = try sourceOf(arena, &fake, &.{ "big.txt", "x.txt" });
    const request = scan.Request{ .pattern = "(a|b)+c", .mode = .regex, .time_budget_ms = 3 };
    // The first page completes line 1, then runs out inside line 2: stopped, with a cursor at line 2.
    var clock = CountingClock{};
    const first = try ok(try scan.run(arena, request, src, clock.clock()));
    try testing.expectEqual(scan.Stopped.time, first.stopped);
    try testing.expect(std.mem.endsWith(u8, first.next_cursor.?, ":0:2:0"));
    // From that cursor no position can be completed, even with the first line's 10 ms grace: refused, not the
    // same cursor handed back, and the cause is the line (the budget was not spent when it started).
    var again = request;
    again.cursor = first.next_cursor;
    clock = .{};
    const outcome = try scan.run(arena, again, src, clock.clock());
    switch (outcome) {
        .ok => return error.TestUnexpectedResult,
        .failed => |failure| {
            try testing.expectEqual(@import("source.zig").Code.capacity, failure.code);
            try testing.expectEqualStrings("line 2 of r-legacy/big.txt outlasts time_budget_ms (3): raise it (at most 30000) or narrow the scope", failure.message);
        },
    }
    // A larger budget passes it.
    again.time_budget_ms = 30_000;
    const done = try ok(try scan.run(arena, again, src, realClock()));
    try testing.expectEqual(scan.Stopped.none, done.stopped);
    try testing.expect(done.next_cursor == null);
}

test "S6-T24 rework 1, ruling 5: a budget spent before the first line is named, and the first line still gets its grace" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Each read of this clock is 5 ms later: the budget of 3 ms has passed by the time the first line starts.
    const long = [_][]const u8{"a" ** 400_000 ++ "\nx\n"};
    var fake = Fake{ .bytes = &long };
    const src = try sourceOf(arena, &fake, &.{"big.txt"});
    var clock = CountingClock{ .step = 5 * std.time.ns_per_ms };
    const refused = try scan.run(arena, .{ .pattern = "(a|b)+c", .mode = .regex, .time_budget_ms = 3 }, src, clock.clock());
    switch (refused) {
        .ok => return error.TestUnexpectedResult,
        .failed => |failure| try testing.expectEqualStrings("time_budget_ms (3) ran out reading r-legacy/big.txt, and line 1 did not finish in the 10 ms after: raise it (at most 30000) or narrow the scope", failure.message),
    }
    // A first line that fits the grace is searched, and the page then stops with a cursor past it.
    var lines = std.ArrayList(u8).empty;
    for (0..20_000) |i| try lines.print(arena, "line {d} 42\n", .{i});
    const many = [_][]const u8{lines.items};
    var fake_many = Fake{ .bytes = &many };
    const src_many = try sourceOf(arena, &fake_many, &.{"many.txt"});
    clock = .{ .step = 5 * std.time.ns_per_ms };
    const page = try ok(try scan.run(arena, .{ .pattern = "^line 0 ", .mode = .regex, .time_budget_ms = 3 }, src_many, clock.clock()));
    try testing.expectEqual(scan.Stopped.time, page.stopped);
    try testing.expectEqual(@as(usize, 1), page.hits.len);
    try testing.expect(!std.mem.endsWith(u8, page.next_cursor.?, ":0:1:0"));
}

test "S6-T24 rework 1, ruling 1: the clock starts before the pattern is parsed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = Fake{ .bytes = &corpus_bytes };
    const src = try sourceOf(arena, &fake, &corpus_paths);
    // A pattern refused when it is parsed has already read the clock once: the budget's start.
    var clock = CountingClock{};
    _ = try refusal(try scan.run(arena, .{ .pattern = "a(", .mode = .regex }, src, clock.clock()));
    try testing.expectEqual(@as(u64, std.time.ns_per_ms), clock.now_ns);
    // A request refused before it (a field out of range) has not.
    clock = .{};
    _ = try refusal(try scan.run(arena, .{ .pattern = "a", .page_size = 0 }, src, clock.clock()));
    try testing.expectEqual(@as(u64, 0), clock.now_ns);
}

test "S6-T24 scan: a pattern that can match the empty string makes every line a hit, with the warning flag" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = Fake{ .bytes = &corpus_bytes };
    const src = try sourceOf(arena, &fake, &corpus_paths);
    const answer = try ok(try scan.run(arena, .{ .pattern = "z*", .mode = .regex, .page_size = 100 }, src, realClock()));
    try testing.expect(answer.matches_empty);
    try testing.expectEqual(@as(usize, 3 + 4 + 1 + 10), answer.hits.len);
    for (answer.hits) |hit| try testing.expectEqual(@as(usize, 0), hit.match_offsets.len);
}

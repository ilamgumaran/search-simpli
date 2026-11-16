//! S6-T5 (contract 2.8.0): `ss_query`'s warnings under `search_field`
//! `both` and `filename`. Under `both` they are `content`'s, except that a
//! word a visible file name holds is not unmatched; under `filename` the
//! only term warning is `query_term_unmatched`, for a word no visible file
//! name holds. A word only a hidden file or name holds gets the warnings an
//! absent word gets, byte for byte (the label wall, S2-T4).
const std = @import("std");
const abi = @import("abi.zig");

const roots =
    \\[{"root_id":"home","label":"Home","kind":"host"},{"root_id":"school","label":"School","kind":"host"}]
;

/// One invented folder in two roots. `diary` is only a file's name, `museum`
/// only a chunk's word, `garden` only a folder's name; `quokka-notes.md`
/// needs a label, `school/` is a second root.
const files = [_]struct { root: []const u8, path: []const u8, text: []const u8, labels: []const u8 = "" }{
    .{ .root = "home", .path = "dinosaur-trip.md", .text = "# Trip\n\nthe dinosaur museum had bones\n" },
    .{ .root = "home", .path = "garden/bean-diary.md", .text = "# Beans\n\ntomatoes and beans grew tall\n" },
    .{ .root = "home", .path = "private/quokka-notes.md", .text = "# Notes\n\nzebra stripes\n", .labels = "[\"tenant:acme\"]" },
    .{ .root = "school", .path = "harbour-map.md", .text = "# Map\n\ntide charts\n" },
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    path_z: [:0]u8,
    handle: *abi.Handle,

    fn open() !Fixture {
        const a = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const path_z = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
        errdefer a.free(path_z);
        var changes: std.Io.Writer.Allocating = .init(a);
        defer changes.deinit();
        try changes.writer.print("{{\"roots\":{s},\"changes\":[", .{roots});
        for (files, 0..) |f, i| {
            const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(f.text.len));
            defer a.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, f.text);
            if (i != 0) try changes.writer.writeByte(',');
            try changes.writer.print("{{\"op\":\"add\",\"root_id\":\"{s}\",\"path\":\"{s}\",\"content_base64\":\"{s}\"", .{ f.root, f.path, encoded });
            if (f.labels.len != 0) try changes.writer.print(",\"required_labels\":{s}", .{f.labels});
            try changes.writer.writeByte('}');
        }
        try changes.writer.writeAll("]}");
        const changes_z = try a.dupeZ(u8, changes.written());
        defer a.free(changes_z);
        const applied = abi.ss_apply_changes(path_z, changes_z, "{\"filename_index\":true}") orelse {
            std.debug.print("ss_apply_changes failed: {s}\n", .{abi.ss_last_error()});
            return error.ApplyFailed;
        };
        abi.ss_free(applied);
        const handle = abi.ss_open(path_z) orelse return error.OpenFailed;
        return .{ .tmp = tmp, .path_z = path_z, .handle = handle };
    }

    fn close(fixture: *Fixture) void {
        abi.ss_close(fixture.handle);
        std.testing.allocator.free(fixture.path_z);
        fixture.tmp.cleanup();
    }

    /// The `warnings` array's exact bytes for `text` under `field` with
    /// `extra` options (a JSON object body, possibly empty).
    fn warnings(fixture: Fixture, text: []const u8, field: []const u8, extra: []const u8, vector: []const f32) ![]u8 {
        const a = std.testing.allocator;
        const text_z = try a.dupeZ(u8, text);
        defer a.free(text_z);
        const options = try std.fmt.allocPrintSentinel(a, "{{\"retrieval_mode\":\"lexical\",\"search_field\":\"{s}\"{s}{s}}}", .{ field, if (extra.len == 0) "" else ",", extra }, 0);
        defer a.free(options);
        const out = abi.ss_query(fixture.handle, text_z.ptr, if (vector.len == 0) null else vector.ptr, vector.len, 5, options.ptr) orelse {
            std.debug.print("ss_query failed: {s}\n", .{abi.ss_last_error()});
            return error.QueryFailed;
        };
        defer abi.ss_free(out);
        const report = std.mem.span(out);
        const start = std.mem.indexOf(u8, report, "\"warnings\":[") orelse return error.NoWarnings;
        const end = std.mem.indexOfPos(u8, report, start, "],\"request\":") orelse return error.NoRequest;
        return a.dupe(u8, report[start + "\"warnings\":".len .. end + 1]);
    }
};

inline fn unmatched(comptime term: []const u8) []const u8 {
    comptime {
        return "{\"code\":\"query_term_unmatched\",\"message\":\"the term was not found in the searched files\",\"term\":\"" ++ term ++ "\"}";
    }
}

test "both: the warnings content gives, codes, order, wording and members unchanged" {
    var fixture = try Fixture.open();
    defer fixture.close();
    const a = std.testing.allocator;
    // An expansion (dinosuar), a miss (qqzzxx), a group (tomato), a matched word (museum).
    const query = "trip dinosuar qqzzxx tomato museum";
    const content = try fixture.warnings(query, "content", "", &.{});
    defer a.free(content);
    const both = try fixture.warnings(query, "both", "", &.{});
    defer a.free(both);
    try std.testing.expectEqualStrings(content, both);
    try std.testing.expect(std.mem.indexOf(u8, both, "\"code\":\"query_term_expanded\",\"message\":\"also searched: dinosaur\",\"term\":\"dinosuar\",\"expansions\":[\"dinosaur\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, both, "\"code\":\"query_term_grouped\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, both, "\"members\":[\"tomatoes\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, both, unmatched("qqzzxx")) != null);
}

test "both: a word only a visible file name holds is not unmatched; a word only a folder holds still is" {
    var fixture = try Fixture.open();
    defer fixture.close();
    const a = std.testing.allocator;
    const content = try fixture.warnings("diary", "content", "", &.{});
    defer a.free(content);
    try std.testing.expectEqualStrings("[" ++ unmatched("diary") ++ "]", content);
    const both = try fixture.warnings("diary", "both", "", &.{});
    defer a.free(both);
    try std.testing.expectEqualStrings("[]", both);
    // `garden` is a folder of a visible file, not a file name: the
    // file-name channel does not hold it (open question in the Report).
    const folder = try fixture.warnings("garden diary", "both", "", &.{});
    defer a.free(folder);
    try std.testing.expectEqualStrings("[" ++ unmatched("garden") ++ "]", folder);
}

test "filename: only query_term_unmatched, for a word no visible file name holds" {
    var fixture = try Fixture.open();
    defer fixture.close();
    const a = std.testing.allocator;
    const got = try fixture.warnings("Trip dinosuar qqzzxx tomato museum diary DIARY trip", "filename", "", &.{});
    defer a.free(got);
    try std.testing.expectEqualStrings("[" ++ unmatched("dinosuar") ++ "," ++ unmatched("qqzzxx") ++ "," ++ unmatched("tomato") ++ "," ++ unmatched("museum") ++ "]", got);
}

test "both and filename: query_empty_after_analysis and vector_ignored as under content" {
    var fixture = try Fixture.open();
    defer fixture.close();
    const a = std.testing.allocator;
    for ([_][]const u8{ "both", "filename" }) |field| {
        const content = try fixture.warnings("!!! ...", "content", "", &.{});
        defer a.free(content);
        const got = try fixture.warnings("!!! ...", field, "", &.{});
        defer a.free(got);
        try std.testing.expectEqualStrings(content, got);
        try std.testing.expect(std.mem.indexOf(u8, got, "query_empty_after_analysis") != null);
        const vector = [_]f32{ 1, 0 };
        const with_vector = try fixture.warnings("trip", field, "", &vector);
        defer a.free(with_vector);
        const content_vector = try fixture.warnings("trip", "content", "", &vector);
        defer a.free(content_vector);
        try std.testing.expectEqualStrings(content_vector, with_vector);
        try std.testing.expect(std.mem.indexOf(u8, with_vector, "\"code\":\"vector_ignored\"") != null);
    }
}

test "both and filename: a word only a hidden file or name holds gets an absent word's warnings, byte for byte" {
    var fixture = try Fixture.open();
    defer fixture.close();
    const a = std.testing.allocator;
    // Each hidden word, its scope, and an absent word of the same length.
    const cases = [_]struct { hidden: []const u8, absent: []const u8, extra: []const u8 }{
        // A name and chunk words of a file that needs a label.
        .{ .hidden = "quokka", .absent = "qqzzxx", .extra = "" },
        .{ .hidden = "zebra", .absent = "qzzxq", .extra = "" },
        // A file of a root left out.
        .{ .hidden = "harbour", .absent = "qqzzxxq", .extra = "\"roots\":[\"home\"]" },
        .{ .hidden = "tide", .absent = "qzxq", .extra = "\"roots\":[\"home\"]" },
        // A file outside the path prefix (its name and its words).
        .{ .hidden = "dinosaur", .absent = "qqzzxxqq", .extra = "\"path_prefix\":\"home/garden/\"" },
        .{ .hidden = "museum", .absent = "qqzzxq", .extra = "\"path_prefix\":\"home/garden/\"" },
    };
    for ([_][]const u8{ "both", "filename" }) |field| {
        for (cases) |c| {
            const hidden = try fixture.warnings(c.hidden, field, c.extra, &.{});
            defer a.free(hidden);
            const absent = try fixture.warnings(c.absent, field, c.extra, &.{});
            defer a.free(absent);
            // The absent word's bytes with its term replaced by the hidden one.
            const expected = try std.mem.replaceOwned(u8, a, absent, c.absent, c.hidden);
            defer a.free(expected);
            std.testing.expectEqualStrings(expected, hidden) catch |err| {
                std.debug.print("field {s}, hidden {s}, scope {s}\n", .{ field, c.hidden, c.extra });
                return err;
            };
            try std.testing.expect(std.mem.indexOf(u8, hidden, "query_term_unmatched") != null);
        }
        // With the label, the labelled file's name and words are visible again.
        const seen = try fixture.warnings("quokka", field, "\"principal_labels\":[\"tenant:acme\"]", &.{});
        defer a.free(seen);
        try std.testing.expectEqualStrings("[]", seen);
    }
}

test "content: the field path leaves content's warnings as they were" {
    var fixture = try Fixture.open();
    defer fixture.close();
    const a = std.testing.allocator;
    const got = try fixture.warnings("trip diary dinosuar", "content", "", &.{});
    defer a.free(got);
    try std.testing.expectEqualStrings("[" ++ unmatched("diary") ++ "," ++ unmatched("dinosuar") ++
        ",{\"code\":\"query_term_expanded\",\"message\":\"also searched: dinosaur\",\"term\":\"dinosuar\",\"expansions\":[\"dinosaur\"]}]", got);
}

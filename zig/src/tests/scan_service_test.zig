//! S6-T24: `scan` through the operations layer (`ScopedService.scan`, `ops.scan`) over real indexes
//! (ADR 0006 section 16): the order across a legacy root and named roots; a file hidden by its root or its
//! labels never appears and is not counted; a root without retention counts `not_retained`; pending and
//! skipped files count in scope; the `capacity` refusal of a generation without source; and the workspace:
//! a scan of a 10 MiB file, with the open, inside a 64 MiB cap (NFR-13's form, `nfr13_arena_test.zig`).
const std = @import("std");
const apply = @import("core").apply;
const indexer = @import("core").indexer;
const scan = @import("core").scan;
const snapshot_open = @import("core").snapshot_open;
const ops = @import("operations").ops;
const service_module = @import("operations").service;
const nfr13 = @import("nfr13_arena_test.zig");

const io = std.testing.io;
const testing = std.testing;

fn b64(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const out = try a.alloc(u8, std.base64.standard.Encoder.calcSize(text.len));
    _ = std.base64.standard.Encoder.encode(out, text);
    return out;
}

/// Three roots: `b-open` (retained), `a-vault` (needs the label `adults`), `c-bare` (keeps no bytes); in
/// `b-open` one file needs the label `adults`, one is pending and one is too large for the apply's cap.
fn indexRoots(a: std.mem.Allocator, out: std.Io.Dir) !void {
    const request = try std.fmt.allocPrint(a,
        \\{{"roots":[{{"root_id":"b-open","kind":"host"}},{{"root_id":"a-vault","kind":"host","required_labels":["adults"]}},{{"root_id":"c-bare","kind":"host","retain_source":false}}],
        \\"changes":[
        \\{{"op":"add","root_id":"b-open","path":"z.md","content_base64":"{s}"}},
        \\{{"op":"add","root_id":"b-open","path":"a/notes.txt","content_base64":"{s}"}},
        \\{{"op":"add","root_id":"b-open","path":"secret.txt","content_base64":"{s}","required_labels":["adults"]}},
        \\{{"op":"pending","root_id":"b-open","path":"later.txt","size":10}},
        \\{{"op":"add","root_id":"b-open","path":"huge.txt","content_base64":"{s}"}},
        \\{{"op":"add","root_id":"a-vault","path":"plans.md","content_base64":"{s}"}},
        \\{{"op":"add","root_id":"c-bare","path":"bare.txt","content_base64":"{s}"}}
        \\]}}
    , .{
        try b64(a, "code TS-0142 here\nnothing\n"),
        try b64(a, "first TS-0142\nsecond TS-0142\n"),
        try b64(a, "TS-0142 is secret\n"),
        try b64(a, "TS-0142 " ** 40),
        try b64(a, "TS-0142 in the vault\n"),
        try b64(a, "TS-0142 kept nowhere\n"),
    });
    switch (try apply.applyChanges(a, io, out, request, .{ .max_file_bytes = 100 })) {
        .ok => {},
        .failed => |failure| {
            std.debug.print("apply refused: {s}\n", .{failure.message});
            return error.TestUnexpectedResult;
        },
    }
}

fn scanJson(a: std.mem.Allocator, service: service_module.Service, request: []const u8, caller: ops.Caller) !std.json.Value {
    const params = (try ops.parseObject(a, request)).ok;
    return switch (try ops.scan(a, service, params, caller)) {
        .ok => |text| try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}),
        .failed => |failure| {
            std.debug.print("refused: {s}\n", .{failure.message});
            return error.TestUnexpectedResult;
        },
    };
}

fn hitKeys(a: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    for (value.object.get("hits").?.array.items) |hit| {
        try out.writer.print("{s}/{s}:{d} ", .{ hit.object.get("root_id").?.string, hit.object.get("path").?.string, hit.object.get("line").?.integer });
    }
    return out.written();
}

fn count(value: std.json.Value, object: []const u8, name: []const u8) i64 {
    return value.object.get(object).?.object.get(name).?.integer;
}

test "S6-T24 scan over roots: root then path order, hidden files never appear nor count, not_retained, pending and skipped in scope" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try indexRoots(a, tmp.dir);
    const opened = try snapshot_open.openScoped(a, io, tmp.dir);
    const service = service_module.Service{ .engine = opened.engine, .folder = opened.folder };

    // No labels: a-vault and secret.txt are hidden; c-bare's file is visible but not retained.
    const plain = try scanJson(a, service, "{\"pattern\":\"TS-0142\"}", .{});
    try testing.expectEqualStrings("b-open/a/notes.txt:1 b-open/a/notes.txt:2 b-open/z.md:1 ", try hitKeys(a, plain));
    try testing.expectEqual(@as(i64, 1), count(plain, "not_scanned", "not_retained"));
    try testing.expectEqual(@as(i64, 1), count(plain, "not_scanned", "too_large"));
    try testing.expectEqual(@as(i64, 1), plain.object.get("pending_files").?.integer);
    try testing.expectEqual(@as(i64, 2), plain.object.get("files_scanned").?.integer);
    try testing.expect(plain.object.get("truncated").?.bool);
    const roots = plain.object.get("scope").?.object.get("roots").?.array.items;
    try testing.expectEqual(@as(usize, 2), roots.len); // b-open and c-bare

    // With the label: a-vault comes first (root ids by bytes), then b-open with secret.txt in its place.
    const adult = try scanJson(a, service, "{\"pattern\":\"TS-0142\",\"principal_labels\":[\"adults\"]}", .{ .request_labels = true });
    try testing.expectEqualStrings("a-vault/plans.md:1 b-open/a/notes.txt:1 b-open/a/notes.txt:2 b-open/secret.txt:1 b-open/z.md:1 ", try hitKeys(a, adult));
    try testing.expectEqual(@as(i64, 4), adult.object.get("files_scanned").?.integer);

    // A root named away, and path_prefix and name_glob narrowing what is counted too.
    const narrowed = try scanJson(a, service, "{\"pattern\":\"TS-0142\",\"roots\":[\"c-bare\"]}", .{});
    try testing.expectEqualStrings("", try hitKeys(a, narrowed));
    try testing.expectEqual(@as(i64, 1), count(narrowed, "not_scanned", "not_retained"));
    try testing.expectEqual(@as(i64, 0), narrowed.object.get("pending_files").?.integer);
    const glob = try scanJson(a, service, "{\"pattern\":\"TS-0142\",\"name_glob\":\"*.md\"}", .{});
    try testing.expectEqualStrings("b-open/z.md:1 ", try hitKeys(a, glob));
    try testing.expect(!glob.object.get("truncated").?.bool);

    // A cursor is bound to the effective scope: the labelled caller's cursor is not the plain caller's.
    const paged = try scanJson(a, service, "{\"pattern\":\"TS-0142\",\"page_size\":1,\"principal_labels\":[\"adults\"]}", .{ .request_labels = true });
    const cursor = paged.object.get("next_cursor").?.string;
    const params = (try ops.parseObject(a, try std.fmt.allocPrint(a, "{{\"pattern\":\"TS-0142\",\"cursor\":\"{s}\"}}", .{cursor}))).ok;
    switch (try ops.scan(a, service, params, .{})) {
        .ok => return error.TestUnexpectedResult,
        .failed => |failure| try testing.expectEqualStrings("cursor does not belong to this request", failure.message),
    }
    // Unknown fields and field messages.
    for ([_][2][]const u8{
        .{ "{\"pattern\":\"x\",\"bogus\":1}", "unknown field \"bogus\"" },
        .{ "{}", "pattern is required" },
        .{ "{\"pattern\":\"x\",\"mode\":\"glob\"}", "mode must be literal or regex" },
        .{ "{\"pattern\":\"x\",\"case\":\"upper\"}", "case must be sensitive, insensitive or smart" },
        .{ "{\"pattern\":\"x\",\"whole_word\":1}", "whole_word must be a boolean" },
        .{ "{\"pattern\":\"x\",\"page_size\":-1}", "page_size must be a non-negative integer" },
        .{ "{\"pattern\":\"x\",\"principal_labels\":[\"adults\"]}", "principal_labels comes from the trusted caller (the server's --labels), not from a request" },
    }) |case| {
        switch (try ops.scan(a, service, (try ops.parseObject(a, case[0])).ok, .{})) {
            .ok => return error.TestUnexpectedResult,
            .failed => |failure| try testing.expectEqualStrings(case[1], failure.message),
        }
    }
}

test "S6-T24 scan: a generation without source bytes is refused with capacity, as read_span is" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const request = try std.fmt.allocPrint(a, "{{\"roots\":[{{\"root_id\":\"only\",\"kind\":\"host\",\"retain_source\":false}}],\"changes\":[{{\"op\":\"add\",\"root_id\":\"only\",\"path\":\"x.txt\",\"content_base64\":\"{s}\"}}]}}", .{try b64(a, "x 1\n")});
    switch (try apply.applyChanges(a, io, tmp.dir, request, .{})) {
        .ok => {},
        .failed => return error.TestUnexpectedResult,
    }
    const opened = try snapshot_open.openScoped(a, io, tmp.dir);
    const service = service_module.Service{ .engine = opened.engine, .folder = opened.folder };
    switch (try ops.scan(a, service, (try ops.parseObject(a, "{\"pattern\":\"x\"}")).ok, .{})) {
        .ok => |text| {
            // A section may still be bound with no file in it: then every file counts not_retained.
            const value = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
            try testing.expectEqual(@as(i64, 1), count(value, "not_scanned", "not_retained"));
            try testing.expectEqual(@as(usize, 0), value.object.get("hits").?.array.items.len);
        },
        .failed => |failure| try testing.expectEqual(ops.Code.capacity, failure.code),
    }
}

test "S6-T24 NFR-13: scan of a 10 MiB file, with the open, inside a 64 MiB cap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var needles: usize = 0;
    try tmp.dir.createDirPath(io, "folder");
    var folder = try tmp.dir.openDir(io, "folder", .{ .iterate = true });
    defer folder.close(io);
    {
        // 10 MiB of short lines, one in 1,000 holding the needle.
        const size: usize = 10 * 1024 * 1024;
        const bytes = try a.alloc(u8, size);
        var at: usize = 0;
        var line: usize = 0;
        while (at < size) : (line += 1) {
            const needle = line % 1000 == 999;
            const text = if (needle) "a line with needle-77 in it\n" else "an ordinary line of words\n";
            const n = @min(text.len, size - at);
            @memcpy(bytes[at .. at + n], text[0..n]);
            at += n;
            if (needle and n == text.len) needles += 1;
        }
        try folder.writeFile(io, .{ .sub_path = "big.txt", .data = bytes });
    }
    try tmp.dir.createDirPath(io, "index");
    var out = try tmp.dir.openDir(io, "index", .{ .iterate = true });
    defer out.close(io);
    _ = try indexer.indexFolder(a, io, folder, out, .v2, null, 1600, 3, .{});

    var capped = nfr13.Capped{ .parent = std.heap.page_allocator, .cap = nfr13.cap_bytes };
    var engine_arena = std.heap.ArenaAllocator.init(capped.allocator());
    defer engine_arena.deinit();
    const opened = try snapshot_open.openScopedWith(.{ .blocks = capped.allocator(), .arena = engine_arena.allocator() }, io, out);
    defer snapshot_open.close(opened.engine, opened.folder);
    const scoped = service_module.ScopedService{ .service = .{ .engine = opened.engine, .folder = opened.folder } };
    var total: usize = 0;
    var cursor: ?[]const u8 = null;
    var cursor_buffer: [128]u8 = undefined;
    var peak: usize = 0;
    while (true) {
        var op_arena = std.heap.ArenaAllocator.init(capped.allocator());
        defer op_arena.deinit();
        _ = capped.markPeak();
        const result = try scoped.scan(op_arena.allocator(), .{ .pattern = "needle-77", .page_size = 100, .max_hits_per_file = 1000, .time_budget_ms = 30_000, .cursor = cursor }, .{});
        const answer = result.outcome.ok;
        total += answer.hits.len;
        peak = @max(peak, capped.peak);
        const next = answer.next_cursor orelse break;
        @memcpy(cursor_buffer[0..next.len], next);
        cursor = cursor_buffer[0..next.len];
    }
    std.debug.print("S6-T24 NFR-13 scan of a 10 MiB file under a {d} B cap: peak live bytes {d}, {d} hit lines\n", .{ nfr13.cap_bytes, peak, total });
    try testing.expectEqual(@as(usize, 0), capped.refused);
    try testing.expect(peak <= nfr13.cap_bytes);
    try testing.expectEqual(needles, total); // every needle line, page by page
}

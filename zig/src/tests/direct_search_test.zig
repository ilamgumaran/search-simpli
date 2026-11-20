//! S6-T2: `searchd search <folder> "<query>"` builds the generation `index`
//! would publish, in memory, and answers with `query`'s and `evidence`'s
//! code. These tests hold it to that: the detached sections are the bytes
//! `index` writes; every answer over the J2 corpus, the whole `fixtures/`
//! folder and a folder built to exercise the walk's rules equals the indexed
//! one on all three fields; the command reads but never writes the folder;
//! its usage errors are one line and status 2.
const std = @import("std");
const cli = @import("interfaces").cli;
const chunker = @import("core").chunker;
const engine_module = @import("core").engine;
const filename_field = @import("core").filename_field;
const indexer = @import("core").indexer;
const snapshot_open = @import("core").snapshot_open;

const j2 = "../fixtures/j2";
const fixtures = "../fixtures";
const fields = [_]filename_field.Field{ .content, .filename, .both };

fn tmpPath(a: std.mem.Allocator, tmp: std.testing.TmpDir, sub: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, sub });
}

/// The J2 pack's 290 query strings (`fixtures/j2/judgments.json`).
fn j2Queries(a: std.mem.Allocator) ![]const []const u8 {
    const io = std.testing.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, j2 ++ "/judgments.json", a, .unlimited);
    const judgments = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    const rows = judgments.object.get("queries").?.array.items;
    const out = try a.alloc([]const u8, rows.len);
    for (rows, out) |row, *query| query.* = row.object.get("query").?.string;
    return out;
}

/// A folder that exercises every rule of the walk: ignored directories,
/// dotfiles and dot-directories, extensions in and out of the list (upper
/// case too), nested folders, Markdown and plain text, an empty file, a
/// file that is not UTF-8, and one larger than a small cap.
fn writeRulesFolder(dir: std.Io.Dir) !void {
    const io = std.testing.io;
    const files = [_]struct { []const u8, []const u8 }{
        .{ "notes/garden.md", "# Garden\n\n## Tomatoes\n\nThe tomatoes by the shed need water every evening.\n\n## Beans\n\nRunner beans climb the hazel poles.\n" },
        .{ "notes/kitchen.txt", "The kettle is descaled on Sundays.\nThe pantry holds flour, oats and lentils.\n" },
        .{ "notes/deep/deeper/attic.MD", "# Attic\n\nThe attic holds the winter blankets and the old lantern.\n" },
        .{ "code/lantern.py", "def light_lantern():\n    return 'the lantern glows'\n" },
        .{ "code/config.yaml", "lantern: brass\nshed: green\n" },
        .{ "empty.md", "" },
        .{ "picture.png", "lantern tomatoes shed (not a listed extension)\n" },
        .{ "README", "lantern tomatoes shed (no extension)\n" },
        .{ ".hidden.md", "lantern tomatoes shed in a dotfile\n" },
        .{ ".secret/plans.md", "lantern tomatoes shed in a dot-directory\n" },
        .{ "node_modules/pkg/readme.md", "lantern tomatoes shed in node_modules\n" },
        .{ "notes/__pycache__/cache.txt", "lantern tomatoes shed in __pycache__\n" },
        .{ "zig-out/out.txt", "lantern tomatoes shed in zig-out\n" },
        .{ ".search/index.md", "lantern tomatoes shed in .search\n" },
        .{ "big/bulky.txt", "lantern " ** 400 },
    };
    for (files) |file| {
        if (std.fs.path.dirname(file[0])) |parent| try dir.createDirPath(io, parent);
        try dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
    }
    // Not UTF-8: `unreadable`, as for `index`.
    try dir.writeFile(io, .{ .sub_path = "notes/broken.txt", .data = &[_]u8{ 'l', 'a', 'n', 't', 0xff, 0xfe, '\n' } });
}

const rules_queries = [_][]const u8{
    "lantern",           "tomatoes shed", "attic blankets", "kettle pantry", "garden",  "readme",
    "node_modules pkg",  "hidden",        "bulky",          "broken",        "config",  "lantern glows",
    "Tomatoes \"water\"", "beans hazel",  "nothing matches this",
};

fn openIndexed(a: std.mem.Allocator, out: std.Io.Dir, field: filename_field.Field) !engine_module.Engine {
    const io = std.testing.io;
    // As `runQuery`/`runEvidence` open a directory for `field`.
    return if (field != .content) (try snapshot_open.openScoped(a, io, out)).engine else try snapshot_open.open(a, io, out);
}

const Form = enum { text, json, evidence };

fn answer(a: std.mem.Allocator, engine: engine_module.Engine, query: []const u8, options: cli.QueryOptions, form: Form) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(a);
    var with_form = options;
    with_form.json = form == .json;
    if (form == .evidence) {
        try cli.answerEvidence(a, engine, query, with_form, &output.writer);
    } else {
        try cli.answerQuery(a, engine, query, with_form, &output.writer);
    }
    return output.written();
}

/// Every query on every field in every form, with each `top_k`: the answer
/// over the generation `search` builds equals the answer over the one
/// `index --filename-index` (with the same caps) published. Returns how many
/// answers were compared.
fn expectSameAnswers(folder: []const u8, queries: []const []const u8, caps: indexer.Caps, top_ks: []const usize) !usize {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var index_caps = caps;
    index_caps.filename_index = true;
    var sink: std.Io.Writer.Allocating = .init(a);
    try cli.runIndex(io, a, folder, try tmpPath(a, tmp, "out"), .{ .caps = index_caps }, &sink.writer);
    var out = try tmp.dir.openDir(io, "out", .{ .iterate = true });
    defer out.close(io);
    var root = try std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true });
    defer root.close(io);
    var compared: usize = 0;
    for (fields) |field| {
        const searched = try cli.buildAndOpen(a, io, root, .{
            .folder = folder,
            .text = "unused",
            .options = .{ .search_field = field },
            .max_file_bytes = caps.max_file_bytes,
            .max_total_bytes = caps.max_total_bytes,
        });
        const indexed = try openIndexed(a, out, field);
        for (queries) |query| for (top_ks) |top_k| for ([_]Form{ .text, .json, .evidence }) |form| {
            var query_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer query_arena.deinit();
            const qa = query_arena.allocator();
            const options = cli.QueryOptions{ .search_field = field, .top_k = top_k };
            const want = try answer(qa, indexed, query, options, form);
            const got = try answer(qa, searched.engine, query, options, form);
            if (!std.mem.eql(u8, want, got)) {
                std.debug.print("S6-T2: {s} differs: query '{s}' field {s} form {s} top_k {d}\n", .{ folder, query, @tagName(field), @tagName(form), top_k });
                return error.TestExpectedEqual;
            }
            compared += 1;
        };
    }
    return compared;
}

test "S6-T2: search answers as index then query/evidence, J2 corpus, every query, all three fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const queries = try j2Queries(arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 290), queries.len);
    const compared = try expectSameAnswers(j2, queries, .{}, &.{10});
    try std.testing.expectEqual(@as(usize, 290 * 3 * 3), compared);
}

test "S6-T2: search answers as index then query/evidence, the whole fixtures folder" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const all = try j2Queries(arena_state.allocator());
    // Every tenth J2 query (29), at two depths.
    var picked = std.ArrayList([]const u8).empty;
    var index: usize = 0;
    while (index < all.len) : (index += 10) try picked.append(arena_state.allocator(), all[index]);
    _ = try expectSameAnswers(fixtures, picked.items, .{}, &.{ 3, 25 });
}

test "S6-T2: search answers as index then query/evidence over the walk's rules and the byte caps" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeRulesFolder(tmp.dir);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const folder = try tmpPath(arena_state.allocator(), tmp, ".");
    _ = try expectSameAnswers(folder, &rules_queries, .{}, &.{ 1, 10 });
    // `bulky.txt` (3,200 bytes) over the file cap; a total cap that leaves
    // files over for a later run.
    _ = try expectSameAnswers(folder, &rules_queries, .{ .max_file_bytes = 1000 }, &.{10});
    _ = try expectSameAnswers(folder, &rules_queries, .{ .max_total_bytes = 200 }, &.{10});
}

fn expectFileBytes(a: std.mem.Allocator, dir: std.Io.Dir, name: []const u8, want: []const u8) !void {
    const got = try dir.readFileAlloc(std.testing.io, name, a, .unlimited);
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("S6-T2: {s} differs from the detached section ({d} B on disk, {d} B in memory)\n", .{ name, got.len, want.len });
        return error.TestExpectedEqual;
    }
}

/// The detached sections are byte for byte what `index` publishes into an
/// empty directory with the same caps, and they are all there is: the
/// directory holds those files, `INDEX-STATE.json` and `WRITER.LOCK`.
fn expectSectionsEqualIndex(folder: []const u8, caps: indexer.Caps) !void {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var sink: std.Io.Writer.Allocating = .init(a);
    try cli.runIndex(io, a, folder, try tmpPath(a, tmp, "out"), .{ .caps = caps }, &sink.writer);
    var out = try tmp.dir.openDir(io, "out", .{ .iterate = true });
    defer out.close(io);
    var root = try std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true });
    defer root.close(io);
    const detached = try indexer.buildFolderDetached(a, io, root, .v2, chunker.default_max_chars, chunker.default_overlap_lines, caps);
    const s = detached.sections;
    try expectFileBytes(a, out, "MANIFEST", s.manifest);
    try expectFileBytes(a, out, "documents-1.hybseg", s.documents);
    try expectFileBytes(a, out, "lexical-1.hyblex", s.lexical);
    try expectFileBytes(a, out, "source-1.hybsrc", s.source.?);
    try std.testing.expectEqualStrings("state-1.hybstate", s.state_file);
    try expectFileBytes(a, out, "state-1.hybstate", s.state);
    var expected_files: usize = 7;
    if (caps.filename_index orelse false) {
        try expectFileBytes(a, out, "filenames-1.hybseg", s.catalog.?);
        try expectFileBytes(a, out, "filename-lexical-1.hyblex", s.filename_lexical.?);
        expected_files += 2;
    } else {
        try std.testing.expect(s.catalog == null and s.filename_lexical == null);
    }
    var count: usize = 0;
    var it = out.iterate();
    while (try it.next(io)) |_| count += 1;
    try std.testing.expectEqual(expected_files, count);
    try std.testing.expectEqual(@as(u64, 1), detached.report.generation);
}

test "S6-T2: the detached sections are the bytes index publishes (J2, fixtures, the walk's rules; with and without the file-name channel)" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeRulesFolder(tmp.dir);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rules = try tmpPath(arena_state.allocator(), tmp, ".");
    for ([_][]const u8{ j2, fixtures, rules }) |folder| {
        try expectSectionsEqualIndex(folder, .{});
        try expectSectionsEqualIndex(folder, .{ .filename_index = true });
    }
    try expectSectionsEqualIndex(rules, .{ .filename_index = true, .max_file_bytes = 1000 });
    try expectSectionsEqualIndex(rules, .{ .max_total_bytes = 200 });
}

/// Every entry under `dir` (recursively) with its kind, size and
/// modification time, one line each, sorted.
fn treeListing(a: std.mem.Allocator, dir: std.Io.Dir) ![]const u8 {
    const io = std.testing.io;
    var lines = std.ArrayList([]const u8).empty;
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const stat = try dir.statFile(io, entry.path, .{ .follow_symlinks = false });
        try lines.append(a, try std.fmt.allocPrint(a, "{s} {s} {d} {d}", .{ entry.path, @tagName(stat.kind), stat.size, stat.mtime.nanoseconds }));
    }
    std.mem.sort([]const u8, lines.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lessThan);
    return std.mem.join(a, "\n", lines.items);
}

fn runSearch(a: std.mem.Allocator, args: []const []const u8) !struct { status: u8, out: []const u8, err: []const u8 } {
    var buffer: [512]u8 = undefined;
    const command = cli.parseArgs(args, &buffer);
    switch (command) {
        .usage_error => |usage| return .{ .status = usage.status, .out = "", .err = try a.dupe(u8, usage.message) },
        .search => |search| {
            var output: std.Io.Writer.Allocating = .init(a);
            var errors: std.Io.Writer.Allocating = .init(a);
            const status = try cli.runSearchFolder(std.testing.io, a, search, &output.writer, &errors.writer);
            return .{ .status = status, .out = output.written(), .err = errors.written() };
        },
        else => return error.TestUnexpectedResult,
    }
}

test "S6-T2: search reads the folder and writes nothing in it or beside it" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "folder", .default_dir);
    var folder = try tmp.dir.openDir(io, "folder", .{ .iterate = true });
    defer folder.close(io);
    try writeRulesFolder(folder);
    const folder_path = try tmpPath(a, tmp, "folder");
    // The folder's parent holds the folder and nothing else.
    const before = try treeListing(a, tmp.dir);
    for (fields) |field| for ([_][]const u8{ "", "--json", "--evidence" }) |form| {
        var args = std.ArrayList([]const u8).empty;
        try args.appendSlice(a, &.{ "search", folder_path, "lantern tomatoes", "--search-field", @tagName(field), "--max-file-bytes", "1000" });
        if (form.len != 0) try args.append(a, form);
        const result = try runSearch(a, args.items);
        try std.testing.expectEqual(@as(u8, 0), result.status);
        try std.testing.expect(result.out.len > 0);
        // The cap and the broken file are counted on stderr, one line.
        try std.testing.expectEqualStrings("searchd: search: 2 files not searched (too_large=1 unreadable=1 budget_exhausted=0)\n", result.err);
    };
    try std.testing.expectEqualStrings(before, try treeListing(a, tmp.dir));
}

test "S6-T2: search's usage errors are one line and status 2; an empty folder answers nothing, status 0" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "empty", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "plain.md", .data = "a file, not a folder\n" });
    const cases = [_]struct { args: []const []const u8, needle: []const u8 }{
        .{ .args = &.{"search"}, .needle = "<folder>" },
        .{ .args = &.{ "search", "folder" }, .needle = "\"<query>\"" },
        .{ .args = &.{ "search", "folder", "" }, .needle = "the query is empty" },
        .{ .args = &.{ "search", "folder", " \t\n" }, .needle = "the query is empty" },
        .{ .args = &.{ "search", "folder", "\xff" }, .needle = "not valid UTF-8" },
        .{ .args = &.{ "search", "folder", "q", "--top-k", "0" }, .needle = "--top-k" },
        .{ .args = &.{ "search", "folder", "q", "--search-field", "title" }, .needle = "--search-field" },
        .{ .args = &.{ "search", "folder", "q", "--max-file-bytes", "-1" }, .needle = "--max-file-bytes" },
        .{ .args = &.{ "search", "folder", "q", "--max-total-bytes" }, .needle = "--max-total-bytes" },
        .{ .args = &.{ "search", "folder", "q", "--out", "x" }, .needle = "unknown flag for search" },
        .{ .args = &.{ "search", try tmpPath(a, tmp, "missing"), "q" }, .needle = "(no such folder)" },
        .{ .args = &.{ "search", try tmpPath(a, tmp, "plain.md"), "q" }, .needle = "(not a folder)" },
    };
    for (cases) |case| {
        const result = try runSearch(a, case.args);
        try std.testing.expectEqual(@as(u8, 2), result.status);
        try std.testing.expectEqualStrings("", result.out);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.err, "\n"));
        try std.testing.expect(std.mem.endsWith(u8, result.err, "\n"));
        if (std.mem.indexOf(u8, result.err, case.needle) == null) {
            std.debug.print("S6-T2: '{s}' lacks '{s}'\n", .{ result.err, case.needle });
            return error.TestExpectedEqual;
        }
    }
    // An empty folder answers as an empty index does.
    const empty = try tmpPath(a, tmp, "empty");
    var sink: std.Io.Writer.Allocating = .init(a);
    try cli.runIndex(io, a, empty, try tmpPath(a, tmp, "empty-index"), .{ .caps = .{ .filename_index = true } }, &sink.writer);
    for (fields) |field| {
        const result = try runSearch(a, &.{ "search", empty, "anything", "--search-field", @tagName(field), "--evidence" });
        try std.testing.expectEqual(@as(u8, 0), result.status);
        try std.testing.expectEqualStrings("", result.err);
        var want: std.Io.Writer.Allocating = .init(a);
        try cli.runEvidence(io, a, try tmpPath(a, tmp, "empty-index"), "anything", .{ .search_field = field }, &want.writer);
        try std.testing.expectEqualStrings(want.written(), result.out);
    }
    // `empty-index` aside, `search` left the temporary folder as it was.
    var it = tmp.dir.iterate();
    var names: usize = 0;
    while (try it.next(io)) |_| names += 1;
    try std.testing.expectEqual(@as(usize, 3), names);
}

test "S6-T2: search's flags reach the answer (field, top-k, json, evidence, caps)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buffer: [512]u8 = undefined;
    const parsed = cli.parseArgs(&.{ "search", "f", "q", "--search-field", "filename", "--top-k", "7", "--json", "--evidence", "--max-file-bytes", "12", "--max-total-bytes", "34" }, &buffer);
    const args = parsed.search;
    try std.testing.expectEqualStrings("f", args.folder);
    try std.testing.expectEqualStrings("q", args.text);
    try std.testing.expectEqual(filename_field.Field.filename, args.options.search_field);
    try std.testing.expectEqual(@as(usize, 7), args.options.top_k);
    try std.testing.expect(args.options.json and args.evidence);
    try std.testing.expectEqual(@as(u64, 12), args.max_file_bytes);
    try std.testing.expectEqual(@as(u64, 34), args.max_total_bytes);
    const defaults = cli.parseArgs(&.{ "search", "f", "q" }, &buffer).search;
    try std.testing.expectEqual(filename_field.Field.content, defaults.options.search_field);
    try std.testing.expectEqual(@as(usize, 10), defaults.options.top_k);
    try std.testing.expect(!defaults.options.json and !defaults.evidence);
    try std.testing.expectEqual(@as(u64, 10 * 1024 * 1024), defaults.max_file_bytes);
    try std.testing.expectEqual(@as(u64, 512 * 1024 * 1024), defaults.max_total_bytes);

    // Through the whole command: each field, form and depth gives what
    // `query`/`evidence` give over `index --filename-index` of the folder.
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var sink: std.Io.Writer.Allocating = .init(a);
    const out = try tmpPath(a, tmp, "out");
    try cli.runIndex(io, a, j2, out, .{ .caps = .{ .filename_index = true } }, &sink.writer);
    const query = "volcano project due date";
    for (fields) |field| for ([_][]const u8{ "", "--json", "--evidence" }) |form| for ([_][]const u8{ "1", "10" }) |top_k| {
        var args_list = std.ArrayList([]const u8).empty;
        try args_list.appendSlice(a, &.{ "search", j2, query, "--search-field", @tagName(field), "--top-k", top_k });
        if (form.len != 0) try args_list.append(a, form);
        const got = try runSearch(a, args_list.items);
        try std.testing.expectEqual(@as(u8, 0), got.status);
        var want: std.Io.Writer.Allocating = .init(a);
        const options = cli.QueryOptions{ .search_field = field, .top_k = try std.fmt.parseInt(usize, top_k, 10), .json = std.mem.eql(u8, form, "--json") };
        if (std.mem.eql(u8, form, "--evidence")) {
            try cli.runEvidence(io, a, out, query, options, &want.writer);
        } else {
            try cli.runQuery(io, a, out, query, options, &want.writer);
        }
        try std.testing.expectEqualStrings(want.written(), got.out);
    };
}

test "S6-T2: the scoped detached open reads the source section from memory" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var root = try std.Io.Dir.cwd().openDir(io, j2, .{ .iterate = true });
    defer root.close(io);
    const detached = try indexer.buildFolderDetached(a, io, root, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{ .filename_index = true });
    const s = detached.sections;
    const scoped = try snapshot_open.openScopedDetached(a, io, .{ .manifest = s.manifest, .documents = s.documents, .lexical = s.lexical, .source = s.source, .catalog = s.catalog, .filename_lexical = s.filename_lexical });
    const section = (try scoped.folder.sourceSection()).?;
    try std.testing.expectEqual(@as(usize, 95), section.file_count);
    try std.testing.expect(scoped.folder.sourceError() == null);
    const entry = section.find("school/volcano-project.md") orelse section.find("volcano-project.md") orelse {
        // The walk's records are bare relative paths (root `r-legacy`).
        return error.TestUnexpectedResult;
    };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, j2 ++ "/school/volcano-project.md", a, .unlimited);
    try std.testing.expectEqualStrings(bytes, switch (try section.fileBytes(a, entry)) {
        .ok => |b| b,
        else => return error.TestUnexpectedResult,
    });
    // A damaged section is refused at the first use, as from a file.
    var damaged = try a.dupe(u8, s.source.?);
    damaged[damaged.len - 1] ^= 0xff;
    const bad = try snapshot_open.openScopedDetached(a, io, .{ .manifest = s.manifest, .documents = s.documents, .lexical = s.lexical, .source = damaged });
    try std.testing.expect((try bad.folder.sourceSection()) == null);
    try std.testing.expect(bad.folder.sourceError() != null);
}

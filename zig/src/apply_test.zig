//! S3-T3 ruling 4: roots, `apply_changes` and visible-scope statistics,
//! tested through the request JSON and the scoped operations' payloads.
const std = @import("std");
const apply = @import("apply.zig");
const chunker = @import("chunker.zig");
const hybrid = @import("hybrid.zig");
const incremental_state = @import("incremental_state.zig");
const indexer = @import("indexer.zig");
const lexical_build = @import("lexical_build.zig");
const manifest = @import("manifest.zig");
const publication = @import("publication.zig");
const report = @import("report.zig");
const rpc = @import("rpc.zig");
const scope = @import("scope.zig");
const service_module = @import("service.zig");
const snapshot_open = @import("snapshot_open.zig");
const source = @import("source.zig");
const find_module = @import("find.zig");

const io = std.testing.io;

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

    fn applyOk(f: *Fixture, request: []const u8, options: apply.Options) !apply.Report {
        switch (try apply.applyChanges(f.arena(), io, f.out, request, options)) {
            .ok => |r| return r,
            .failed => |failure| {
                std.debug.print("unexpected refusal: {s}\n", .{failure.message});
                return error.TestUnexpectedResult;
            },
        }
    }

    fn applyFail(f: *Fixture, request: []const u8, options: apply.Options) !source.Failure {
        switch (try apply.applyChanges(f.arena(), io, f.out, request, options)) {
            .ok => return error.TestUnexpectedResult,
            .failed => |failure| return failure,
        }
    }

    /// Every file of the index directory with its bytes' hash (WRITER.LOCK
    /// aside): equal before and after means nothing was published.
    fn listing(f: *Fixture) ![]const u8 {
        var names = std.ArrayList([]const u8).empty;
        var it = f.out.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or std.mem.eql(u8, entry.name, "WRITER.LOCK")) continue;
            try names.append(f.arena(), try f.arena().dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, lessThan);
        var out = std.ArrayList(u8).empty;
        for (names.items) |name| {
            const bytes = try f.out.readFileAlloc(io, name, f.arena(), .unlimited);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
            try out.print(f.arena(), "{s} {x}\n", .{ name, digest });
        }
        return out.toOwnedSlice(f.arena());
    }

    fn opened(f: *Fixture) !service_module.ScopedService {
        const scoped = try snapshot_open.openScoped(f.arena(), io, f.out);
        return .{ .service = .{ .engine = scoped.engine, .folder = scoped.folder } };
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn b64(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const out = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(text.len));
    return std.base64.standard.Encoder.encode(out, text);
}

fn hex(text: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// One `add` change with `content_base64` (and labels when given).
fn add(allocator: std.mem.Allocator, root_id: []const u8, path: []const u8, text: []const u8, labels: []const u8) ![]const u8 {
    const labels_field = if (labels.len == 0) "" else try std.fmt.allocPrint(allocator, ",\"required_labels\":{s}", .{labels});
    return std.fmt.allocPrint(allocator, "{{\"op\":\"add\",\"root_id\":\"{s}\",\"path\":\"{s}\",\"content_base64\":\"{s}\"{s}}}", .{ root_id, path, try b64(allocator, text), labels_field });
}

fn joinChanges(allocator: std.mem.Allocator, roots: []const u8, changes: []const []const u8) ![]const u8 {
    const body = try std.mem.join(allocator, ",", changes);
    return std.fmt.allocPrint(allocator, "{{\"roots\":{s},\"changes\":[{s}]}}", .{ roots, body });
}

const two_roots =
    \\[{"root_id":"home","label":"Home","kind":"host"},{"root_id":"school","label":"School","kind":"icloud"}]
;

fn searchPaths(scoped: service_module.ScopedService, allocator: std.mem.Allocator, query: []const u8, request: scope.Request) ![]const []const u8 {
    const results = try allocator.alloc(hybrid.Result, 50);
    const evidence = try allocator.alloc(@import("engine.zig").Evidence, 50);
    const found = try scoped.searchKnowledge(allocator, query, &.{}, .{ .retrieval_mode = .lexical, .top_k = 50 }, request, results, evidence, null);
    const paths = try allocator.alloc([]const u8, found.len);
    for (found, paths) |item, *path| path.* = item.path;
    return paths;
}

fn contains(paths: []const []const u8, wanted: []const u8) bool {
    for (paths) |path| if (std.mem.eql(u8, path, wanted)) return true;
    return false;
}

/// Every operation's payload for `request`, as one JSON document:
/// `search_knowledge` (with the trace's warnings and counts) for each query,
/// `read_chunk` for each id, `list_sources`, `list_files`, `index_status`,
/// `read_span` and `outline` for each file, and whether each probe word is a
/// visible term (the prefix-expansion hook).
fn payloads(
    allocator: std.mem.Allocator,
    scoped: service_module.ScopedService,
    request: scope.Request,
    queries: []const []const u8,
    chunk_ids: []const []const u8,
    files: []const [2][]const u8,
    probes: []const []const u8,
) ![]const u8 {
    const svc = scoped.service;
    var out: std.Io.Writer.Allocating = .init(allocator);
    var json = std.json.Stringify{ .writer = &out.writer };
    try json.beginObject();
    for (queries) |query| {
        var trace = hybrid.Trace{ .allocator = allocator, .io = io };
        const results = try allocator.alloc(hybrid.Result, 10);
        const evidence = try allocator.alloc(@import("engine.zig").Evidence, 10);
        const found = try scoped.searchKnowledge(allocator, query, &.{}, .{ .retrieval_mode = .lexical, .top_k = 10 }, request, results, evidence, &trace);
        try json.objectField(try std.fmt.allocPrint(allocator, "search {s}", .{query}));
        try rpc.writeSearchResultValueWith(&json, svc, query, .lexical, request.principal_labels.len, found, .{
            .trace = &trace,
            .mode = .lexical,
            .analyzer_id = svc.engine.analyzer_id,
            .top_k = 10,
            .candidate_k = 100,
            .path_prefix = null,
        });
        try json.objectField("matched_chunks");
        try json.write(trace.matched_chunks);
    }
    // `find` (S3-T2) in each mode over the same scope.
    for (queries) |query| {
        for ([_]find_module.Mode{ .words, .prefix, .phrase }) |mode| {
            const text = if (mode == .prefix) try std.fmt.allocPrint(allocator, "{s}*", .{query[0..@min(query.len, 3)]}) else query;
            try json.objectField(try std.fmt.allocPrint(allocator, "find {s} {s}", .{ @tagName(mode), text }));
            switch (try scoped.find(allocator, .{ .query = text, .mode = mode }, request)) {
                .ok => |answer| try find_module.writeJson(&json, answer),
                .failed => |failure| try json.write(failure),
            }
        }
    }
    try json.objectField("read_chunk");
    try json.beginArray();
    for (chunk_ids) |id| try json.write(try scoped.readChunk(allocator, id, null, request));
    try json.endArray();
    try json.objectField("list_sources");
    try json.write(try scoped.listSources(allocator, null, request));
    try json.objectField("list_files");
    try service_module.writeFilesJson(&json, try scoped.listFiles(allocator, request, null, null));
    try json.objectField("index_status");
    try service_module.writeScopedStatusJson(&json, try scoped.indexStatus(allocator, request));
    try json.objectField("files");
    try json.beginArray();
    for (files) |file| {
        switch (try scoped.readSpan(allocator, request, file[0], file[1], 1, 3, 0)) {
            .ok => |span| try source.writeSpanJson(&json, span),
            .failed => |failure| try json.write(failure),
        }
        switch (try scoped.outline(allocator, request, file[0], file[1])) {
            .ok => |data| try source.writeOutlineJson(&json, data),
            .failed => |failure| try json.write(failure),
        }
    }
    try json.endArray();
    try json.objectField("visible_terms");
    try json.beginArray();
    // S3-T4: the hook `find`'s prefix expansion runs (`find.termInScope`).
    const resolved = try service_module.resolve(svc, allocator, request);
    const find_request = find_module.Request{ .query = "", .principal_labels = request.principal_labels, .visible_roots = resolved.mask() };
    for (probes) |probe| {
        var visible = false;
        for (svc.engine.lexical_index.terms, 0..) |entry, term_index| {
            if (!std.mem.eql(u8, entry.term, probe)) continue;
            visible = find_module.termInScope(svc.engine, find_request, term_index);
        }
        try json.write(visible);
    }
    try json.endArray();
    try json.endObject();
    return out.written();
}

// ------------------------------------------------------------------ roots ---

test "S3-T3: two roots indexed and queried together and apart; a root is its own corpus" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena();
    const school_files = [_][2][]const u8{
        .{ "tides.md", "# Tides\n\nThe tide table for the coast trip.\n" },
        .{ "spelling.md", "# Spelling\n\nThe spelling test is on Friday.\n" },
    };
    const home_files = [_][2][]const u8{
        .{ "trips/seaside.md", "# Seaside\n\nCheck the tide table before the walk.\n" },
        .{ "chores.md", "# Chores\n\nFeed the cat, then the tide of laundry.\n" },
    };
    var changes = std.ArrayList([]const u8).empty;
    for (school_files) |file| try changes.append(a, try add(a, "school", file[0], file[1], ""));
    for (home_files) |file| try changes.append(a, try add(a, "home", file[0], file[1], ""));
    const first = try f.applyOk(try joinChanges(a, two_roots, changes.items), .{});
    try std.testing.expectEqual(@as(u64, 1), first.generation);
    try std.testing.expectEqual(@as(usize, 4), first.added);

    const scoped = try f.opened();
    const together = try searchPaths(scoped, a, "tide", .{});
    try std.testing.expect(contains(together, "school/tides.md"));
    try std.testing.expect(contains(together, "home/trips/seaside.md"));
    const school_only = try searchPaths(scoped, a, "tide", .{ .roots = &.{"school"} });
    try std.testing.expectEqual(@as(usize, 1), school_only.len);
    try std.testing.expectEqualStrings("school/tides.md", school_only[0]);
    const home_only = try searchPaths(scoped, a, "tide", .{ .roots = &.{"home"} });
    try std.testing.expectEqual(@as(usize, 2), home_only.len);
    for (home_only) |path| try std.testing.expect(std.mem.startsWith(u8, path, "home/"));
    try std.testing.expectEqual(@as(usize, 0), (try searchPaths(scoped, a, "tide", .{ .roots = &.{"nowhere"} })).len);

    // Per-root statistics: the school root searched alone scores exactly as
    // an index holding only the school root (BM25 idf over the visible scope).
    var g = try Fixture.init();
    defer g.deinit();
    var school_changes = std.ArrayList([]const u8).empty;
    for (school_files) |file| try school_changes.append(g.arena(), try add(g.arena(), "school", file[0], file[1], ""));
    _ = try g.applyOk(try joinChanges(g.arena(), two_roots, school_changes.items), .{});
    const queries = [_][]const u8{ "tide table", "spelling friday", "the" };
    const alone = try payloads(a, scoped, .{ .roots = &.{"school"} }, &queries, &.{}, &.{}, &.{});
    const only_school = try payloads(a, try g.opened(), .{}, &queries, &.{}, &.{}, &.{});
    // The status names the visible roots, so compare the searches only.
    const cut_a = std.mem.indexOf(u8, alone, "\"read_chunk\"").?;
    const cut_b = std.mem.indexOf(u8, only_school, "\"read_chunk\"").?;
    try std.testing.expectEqualStrings(only_school[0..cut_b], alone[0..cut_a]);
}

test "S3-T3: remove_root leaves no term, count, state, source or meta of the root" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena();
    const changes = [_][]const u8{
        try add(a, "home", "garden.md", "# Garden\n\nPlant the beans by the fence.\n", ""),
        try add(a, "school", "robots.md", "# Robots\n\nThe rover motors need new gears.\n", ""),
    };
    _ = try f.applyOk(try joinChanges(a, two_roots, &changes), .{});
    const removed = try f.applyOk("{\"changes\":[{\"op\":\"remove_root\",\"root_id\":\"school\"}]}", .{});
    try std.testing.expectEqual(@as(usize, 1), removed.roots_removed);
    try std.testing.expectEqual(@as(u64, 2), removed.generation);

    const scoped = try f.opened();
    const engine = scoped.service.engine;
    for (engine.lexical_index.terms) |term| {
        for ([_][]const u8{ "rover", "motors", "gears", "robots" }) |gone| try std.testing.expect(!std.mem.eql(u8, term.term, gone));
    }
    for (engine.documents) |document| try std.testing.expect(std.mem.startsWith(u8, document.path, "home/"));
    try std.testing.expectEqual(@as(usize, 0), (try searchPaths(scoped, a, "rover motors", .{})).len);
    const status = try scoped.indexStatus(a, .{});
    try std.testing.expectEqual(@as(usize, 1), status.roots.len);
    try std.testing.expectEqualStrings("home", status.roots[0].root_id);
    try std.testing.expectEqual(@as(usize, 1), status.files);
    try std.testing.expectEqual(@as(usize, 1), scoped.service.folder.?.roots.len);
    const section = (try scoped.service.folder.?.sourceSection()).?;
    try std.testing.expectEqual(@as(usize, 1), section.file_count);
    try std.testing.expect(section.find("school/robots.md") == null);
    const state = (try incremental_state.load(a, io, f.out)).?;
    try std.testing.expectEqual(@as(usize, 1), state.roots.len);
    for (state.files) |entry| try std.testing.expectEqualStrings("home", entry.root_id);
    const meta_bytes = try f.out.readFileAlloc(io, "MANIFEST", a, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, meta_bytes, "school") == null);
    // An unknown root is not an error: it removes nothing.
    const again = try f.applyOk("{\"changes\":[{\"op\":\"remove_root\",\"root_id\":\"school\"}]}", .{});
    try std.testing.expectEqual(@as(usize, 0), again.roots_removed);
}

// ----------------------------------------------------- hidden versus absent ---

const domain_roots =
    \\[{"root_id":"home","label":"Home","kind":"host"},{"root_id":"school","label":"School","kind":"icloud"}]
;

fn publicChanges(a: std.mem.Allocator) ![]const []const u8 {
    const list = [_][]const u8{
        try add(a, "home", "chores.md", "# Chores\n\nWash the dishes and feed the cat.\nThe dishes go on the rack.\n", ""),
        try add(a, "home", "garden.md", "# Garden\n\nWater the beans after school.\n", ""),
        try add(a, "home", "empty.txt", "", ""),
        try add(a, "school", "menu.md", "# Lunch\n\nSoup and dishes of rice on Monday.\n", ""),
    };
    return a.dupe([]const u8, &list);
}

fn hiddenChanges(a: std.mem.Allocator) ![]const []const u8 {
    const list = [_][]const u8{
        try add(a, "home", "money/budget.md", "# Budget\n\nThe salary pays for dishes and the mortgage.\nSalary day is Friday.\n", "[\"adults\"]"),
        try add(a, "home", "money/notes.txt", "salary review and dishes\n", "[\"adults\"]"),
        try add(a, "home", "money/blank.txt", "", "[\"adults\"]"),
    };
    return a.dupe([]const u8, &list);
}

test "S3-T3: a hidden label domain inside one root is indistinguishable from absent in every payload" {
    // A: both domains in root `home`. B: the public domain only.
    var with_hidden = try Fixture.init();
    defer with_hidden.deinit();
    var without = try Fixture.init();
    defer without.deinit();
    const a = with_hidden.arena();
    const both = try std.mem.concat(a, []const u8, &.{ try publicChanges(a), try hiddenChanges(a) });
    _ = try with_hidden.applyOk(try joinChanges(a, domain_roots, both), .{});
    _ = try without.applyOk(try joinChanges(without.arena(), domain_roots, try publicChanges(without.arena())), .{});

    const scoped_a = try with_hidden.opened();
    const scoped_b = try without.opened();
    var hidden_ids = std.ArrayList([]const u8).empty;
    for (scoped_a.service.engine.documents) |document| {
        if (document.required_labels.len != 0) try hidden_ids.append(a, document.id);
    }
    try std.testing.expect(hidden_ids.items.len >= 2);
    try hidden_ids.append(a, "0123456789abcdef0123"); // never existed
    const queries = [_][]const u8{ "dishes", "salary", "salary dishes cat", "friday", "mortgage review" };
    const files = [_][2][]const u8{
        .{ "home", "money/budget.md" },  .{ "home", "money/notes.txt" }, .{ "home", "money/blank.txt" },
        .{ "home", "never-was.md" },      .{ "home", "chores.md" },       .{ "home", "empty.txt" },
        .{ "vault", "money/budget.md" },
    };
    const probes = [_][]const u8{ "salary", "mortgage", "dishes", "rack", "review" };
    const public_request = scope.Request{};
    const outsider = scope.Request{ .principal_labels = &.{"kids"} };
    for ([_]scope.Request{ public_request, outsider }) |request| {
        const payload_a = try payloads(a, scoped_a, request, &queries, hidden_ids.items, &files, &probes);
        const payload_b = try payloads(a, scoped_b, request, &queries, hidden_ids.items, &files, &probes);
        try std.testing.expectEqualStrings(payload_b, payload_a);
    }
    // The hidden-only term does not expand and the shared term's idf is the
    // visible scope's: the scores above are equal, and so is this.
    const salary = try payloads(a, scoped_a, .{}, &.{}, &.{}, &.{}, &.{"salary"});
    try std.testing.expect(std.mem.endsWith(u8, salary, "\"visible_terms\":[false]}"));
    // With the label the domain is visible again (the comparison is not vacuous).
    const adult = try payloads(a, scoped_a, .{ .principal_labels = &.{"adults"} }, &queries, hidden_ids.items, &files, &probes);
    const adult_b = try payloads(a, scoped_b, .{ .principal_labels = &.{"adults"} }, &queries, hidden_ids.items, &files, &probes);
    try std.testing.expect(!std.mem.eql(u8, adult, adult_b));
    try std.testing.expect(std.mem.indexOf(u8, adult, "money/budget.md") != null);

    // The RPC/ABI path (no precomputed statistics, labels only) counts the
    // visible scope exactly and scores the same as the precomputed groups.
    var plain = scoped_a.service.engine;
    plain.statistics = null;
    plain.labeled_documents = null;
    const results = try a.alloc(hybrid.Result, 10);
    const exact = try plain.queryTokenized(a, "salary dishes cat", &.{}, results, .{ .retrieval_mode = .lexical });
    const grouped_results = try a.alloc(hybrid.Result, 10);
    const grouped = try scoped_b.service.engine.queryTokenized(a, "salary dishes cat", &.{}, grouped_results, .{ .retrieval_mode = .lexical });
    try std.testing.expectEqual(grouped.len, exact.len);
    for (grouped, exact) |left, right| {
        try std.testing.expectEqualStrings(left.document_id, right.document_id);
        try std.testing.expectEqual(left.lexical_score, right.lexical_score);
    }
}

test "S3-T3: a root with more than 64 label sets counts exactly and scores like the visible corpus" {
    var many = try Fixture.init();
    defer many.deinit();
    var few = try Fixture.init();
    defer few.deinit();
    const a = many.arena();
    var all = std.ArrayList([]const u8).empty;
    var visible = std.ArrayList([]const u8).empty;
    const public_text = "# Shared\n\nThe orchard has apple trees and pear trees.\n";
    try all.append(a, try add(a, "home", "orchard.md", public_text, ""));
    try visible.append(a, try add(a, "home", "orchard.md", public_text, ""));
    for (0..70) |i| {
        const label = try std.fmt.allocPrint(a, "[\"set-{d}\"]", .{i});
        const text = try std.fmt.allocPrint(a, "apple note {d} with secret word w{d}\n", .{ i, i });
        const path = try std.fmt.allocPrint(a, "notes/n{d}.txt", .{i});
        try all.append(a, try add(a, "home", path, text, label));
        if (i == 3) try visible.append(a, try add(a, "home", path, text, label));
    }
    _ = try many.applyOk(try joinChanges(a, domain_roots, all.items), .{});
    _ = try few.applyOk(try joinChanges(a, domain_roots, visible.items), .{});
    const scoped_many = try many.opened();
    try std.testing.expect((try scoped_many.service.folder.?.statistics()).exact_roots[0]);
    const request = scope.Request{ .principal_labels = &.{"set-3"} };
    const queries = [_][]const u8{ "apple", "apple w3 w4", "trees" };
    const left = try payloads(a, scoped_many, request, &queries, &.{}, &.{}, &.{ "w3", "w4" });
    const right = try payloads(a, try few.opened(), request, &queries, &.{}, &.{}, &.{ "w3", "w4" });
    try std.testing.expectEqualStrings(right, left);
}

test "S3-T3: forged principal_labels in a host-fed request are rejected and nothing is published" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena();
    _ = try f.applyOk(try joinChanges(a, domain_roots, &.{try add(a, "home", "a.md", "# A\n\nalpha\n", "")}), .{});
    const before = try f.listing();
    const top = try std.fmt.allocPrint(a, "{{\"principal_labels\":[\"adults\"],\"changes\":[{s}]}}", .{try add(a, "home", "b.md", "beta\n", "")});
    const refused = try f.applyFail(top, .{});
    try std.testing.expectEqual(source.Code.invalid_argument, refused.code);
    try std.testing.expect(std.mem.indexOf(u8, refused.message, "principal_labels") != null);
    const inner = try std.fmt.allocPrint(a, "{{\"changes\":[{{\"op\":\"remove\",\"root_id\":\"home\",\"path\":\"a.md\",\"principal_labels\":[\"adults\"]}}]}}", .{});
    try std.testing.expectEqual(source.Code.invalid_argument, (try f.applyFail(inner, .{})).code);
    const in_root = "{\"roots\":[{\"root_id\":\"home\",\"principal_labels\":[\"adults\"]}],\"changes\":[]}";
    try std.testing.expectEqual(source.Code.invalid_argument, (try f.applyFail(in_root, .{})).code);
    try std.testing.expectEqualStrings(before, try f.listing());
}

// ------------------------------------------------------------ the operations ---

test "S3-T3: add, change, move, pending, add, remove and remove_root, one call each" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena();
    const roots = "[{\"root_id\":\"home\",\"label\":\"Home\",\"kind\":\"host\"}]";
    const added = try f.applyOk(try joinChanges(a, roots, &.{try add(a, "home", "recipes/soup.md", "# Soup\n\nLentils and carrots simmer slowly.\n", "")}), .{});
    try std.testing.expectEqual(@as(usize, 1), added.added);

    const change = try std.fmt.allocPrint(a, "{{\"changes\":[{{\"op\":\"change\",\"root_id\":\"home\",\"path\":\"recipes/soup.md\",\"content_base64\":\"{s}\",\"sha256\":\"{s}\",\"mtime_ms\":1761900000000}}]}}", .{ try b64(a, "# Soup\n\nLentils, carrots and leeks simmer slowly.\n"), &hex("# Soup\n\nLentils, carrots and leeks simmer slowly.\n") });
    const changed = try f.applyOk(change, .{});
    try std.testing.expectEqual(@as(usize, 1), changed.changed);
    try std.testing.expectEqual(@as(usize, 0), changed.added);

    const moved = try f.applyOk("{\"changes\":[{\"op\":\"move\",\"root_id\":\"home\",\"path\":\"recipes/soup-v2.md\",\"moved_from\":\"recipes/soup.md\"}]}", .{});
    try std.testing.expectEqual(@as(usize, 1), moved.moved);
    try std.testing.expectEqual(@as(usize, 0), moved.added);
    try std.testing.expectEqual(@as(usize, 0), moved.removed);
    {
        const scoped = try f.opened();
        const hits = try searchPaths(scoped, a, "leeks", .{});
        try std.testing.expectEqual(@as(usize, 1), hits.len);
        try std.testing.expectEqualStrings("home/recipes/soup-v2.md", hits[0]);
        const document = scoped.service.engine.documents[0];
        var id: [20]u8 = undefined;
        chunker.chunkId(&id, "home/recipes/soup-v2.md", document.start_line, document.end_line, document.text);
        try std.testing.expectEqualStrings(&id, document.id); // re-keyed
        try std.testing.expectEqualStrings("# Soup\n\nLentils, carrots and leeks simmer slowly.\n", (try scoped.service.folder.?.sourceSection()).?.find("home/recipes/soup-v2.md").?.bytes);
        const state = (try incremental_state.load(a, io, f.out)).?;
        try std.testing.expectEqualStrings("recipes/soup.md", state.files[0].moved_from.?);
        try std.testing.expectEqual(@as(?i64, 1761900000000), state.files[0].mtime_ms);
    }

    // `pending` over an indexed file removes its chunks and lists it by name.
    const pending = try f.applyOk("{\"changes\":[{\"op\":\"pending\",\"root_id\":\"home\",\"path\":\"recipes/soup-v2.md\",\"size\":5000}]}", .{});
    try std.testing.expectEqual(@as(usize, 1), pending.pending);
    try std.testing.expectEqual(@as(usize, 0), pending.documents);
    {
        const scoped = try f.opened();
        try std.testing.expectEqual(@as(usize, 0), (try searchPaths(scoped, a, "leeks", .{})).len);
        const status = try scoped.indexStatus(a, .{});
        try std.testing.expectEqual(@as(usize, 1), status.pending);
        try std.testing.expectEqualStrings("recipes/soup-v2.md", status.pending_paths[0].path);
        const files = try scoped.listFiles(a, .{}, null, null);
        try std.testing.expectEqual(@as(usize, 1), files.len);
        try std.testing.expectEqualStrings("pending", files[0].status);
    }
    const arrived = try f.applyOk(try joinChanges(a, "[]", &.{try add(a, "home", "recipes/soup-v2.md", "# Soup\n\nLentil soup, now with barley.\n", "")}), .{});
    try std.testing.expectEqual(@as(usize, 1), arrived.added);
    try std.testing.expectEqual(@as(usize, 0), arrived.pending);

    const removed = try f.applyOk("{\"changes\":[{\"op\":\"remove\",\"root_id\":\"home\",\"path\":\"recipes/soup-v2.md\"}]}", .{});
    try std.testing.expectEqual(@as(usize, 1), removed.removed);
    try std.testing.expectEqual(@as(usize, 0), removed.documents);

    const gone = try f.applyOk("{\"changes\":[{\"op\":\"remove_root\",\"root_id\":\"home\"}]}", .{});
    try std.testing.expectEqual(@as(usize, 1), gone.roots_removed);
    try std.testing.expectEqual(@as(u64, 7), gone.generation);
    const unknown = try f.applyFail("{\"changes\":[{\"op\":\"remove\",\"root_id\":\"home\",\"path\":\"x.md\"}]}", .{});
    try std.testing.expect(std.mem.indexOf(u8, unknown.message, "undeclared root") != null);
}

test "S3-T3: a content hash mismatch rejects that change; the rest is published" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena();
    const bad = try std.fmt.allocPrint(a, "{{\"op\":\"add\",\"root_id\":\"home\",\"path\":\"x.md\",\"content_base64\":\"{s}\",\"sha256\":\"{s}\"}}", .{ try b64(a, "real bytes\n"), &hex("other bytes\n") });
    const wrong_size = try std.fmt.allocPrint(a, "{{\"op\":\"add\",\"root_id\":\"home\",\"path\":\"y.md\",\"content_base64\":\"{s}\",\"size\":99}}", .{try b64(a, "four\n")});
    const not_utf8 = try std.fmt.allocPrint(a, "{{\"op\":\"add\",\"root_id\":\"home\",\"path\":\"z.md\",\"content_base64\":\"{s}\"}}", .{try b64(a, "\xff\xfe broken\n")});
    const good = try add(a, "home", "good.md", "# Good\n\nkept words\n", "");
    const result = try f.applyOk(try joinChanges(a, domain_roots, &.{ bad, wrong_size, not_utf8, good }), .{});
    try std.testing.expectEqual(@as(usize, 1), result.added);
    try std.testing.expectEqual(@as(usize, 3), result.rejected.len);
    try std.testing.expectEqualStrings("hash_mismatch", result.rejected[0].reason);
    try std.testing.expectEqualStrings("x.md", result.rejected[0].path);
    try std.testing.expectEqualStrings("size_mismatch", result.rejected[1].reason);
    try std.testing.expectEqualStrings("invalid_utf8", result.rejected[2].reason);
    const scoped = try f.opened();
    try std.testing.expectEqual(@as(usize, 0), (try searchPaths(scoped, a, "real", .{})).len);
    try std.testing.expectEqual(@as(usize, 1), (try searchPaths(scoped, a, "kept", .{})).len);
}

test "S4-T2 R5: a root whose path has a linked prefix is read, a link below the root is still refused" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena();
    try f.tmp.dir.createDirPath(io, "real/desk/notes");
    try f.tmp.dir.createDirPath(io, "elsewhere");
    const words = "harbour tide words\n";
    try f.tmp.dir.writeFile(io, .{ .sub_path = "real/desk/notes/words.txt", .data = words });
    try f.tmp.dir.writeFile(io, .{ .sub_path = "elsewhere/secret.txt", .data = "outside words\n" });
    // `alias` -> `real`: the declared root is `<tmp>/alias/desk`, the way a
    // root under `/tmp` or `/var` on macOS reaches its real folder.
    try f.tmp.dir.symLink(io, "real", "alias", .{});
    try f.tmp.dir.symLink(io, "../../elsewhere", "real/desk/linked", .{});
    const base = try f.tmp.dir.realPathFileAlloc(io, ".", a);
    const desk = try std.fmt.allocPrint(a, "{s}/alias/desk", .{base});
    const roots = try std.fmt.allocPrint(a, "[{{\"root_id\":\"desk\",\"kind\":\"local\",\"path\":\"{s}\"}}]", .{desk});
    const change = try std.fmt.allocPrint(a, "{{\"op\":\"add\",\"root_id\":\"desk\",\"path\":\"notes/words.txt\",\"file\":\"{s}/notes/words.txt\",\"sha256\":\"{s}\"}}", .{ desk, &hex(words) });
    const applied = try f.applyOk(try joinChanges(a, roots, &.{change}), .{ .allow_file_reads = true });
    try std.testing.expectEqual(@as(usize, 1), applied.added);
    try std.testing.expectEqual(@as(usize, 0), applied.unreadable_paths.len);
    try std.testing.expectEqual(@as(u64, words.len), applied.bytes_read);
    const scoped = try f.opened();
    try std.testing.expectEqual(@as(usize, 1), (try searchPaths(scoped, a, "harbour", .{})).len);
    // Below the root nothing is followed.
    const linked = try std.fmt.allocPrint(a, "{{\"op\":\"add\",\"root_id\":\"desk\",\"path\":\"s.txt\",\"file\":\"{s}/linked/secret.txt\",\"sha256\":\"{s}\"}}", .{ desk, &hex("outside words\n") });
    try std.testing.expectEqual(source.Code.invalid_argument, (try f.applyFail(try joinChanges(a, roots, &.{linked}), .{ .allow_file_reads = true })).code);
}

test "S3-T3: unsafe paths, a file outside its root, a symlink and disabled file reads are refused whole" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena();
    try f.tmp.dir.createDirPath(io, "desk/notes");
    try f.tmp.dir.createDirPath(io, "elsewhere");
    try f.tmp.dir.writeFile(io, .{ .sub_path = "desk/notes/words.txt", .data = "spelling words list\n" });
    try f.tmp.dir.writeFile(io, .{ .sub_path = "elsewhere/secret.txt", .data = "outside words\n" });
    try f.tmp.dir.symLink(io, "../elsewhere/secret.txt", "desk/link.txt", .{});
    try f.tmp.dir.symLink(io, "../elsewhere", "desk/linked", .{});
    const desk = try f.tmp.dir.realPathFileAlloc(io, "desk", a);
    const outside = try f.tmp.dir.realPathFileAlloc(io, "elsewhere/secret.txt", a);
    const roots = try std.fmt.allocPrint(a, "[{{\"root_id\":\"desk\",\"label\":\"Desk\",\"kind\":\"local\",\"path\":\"{s}\"}}]", .{desk});
    const words = "spelling words list\n";

    // A good batch first, so there is a generation to keep.
    const ok_change = try std.fmt.allocPrint(a, "{{\"op\":\"add\",\"root_id\":\"desk\",\"path\":\"lists/words.txt\",\"file\":\"{s}/notes/words.txt\",\"sha256\":\"{s}\"}}", .{ desk, &hex(words) });
    const first = try f.applyOk(try joinChanges(a, roots, &.{ok_change}), .{ .allow_file_reads = true });
    try std.testing.expectEqual(@as(usize, 1), first.added);
    try std.testing.expectEqual(@as(u64, words.len), first.bytes_read);
    const before = try f.listing();

    const cases = [_][]const u8{
        // a `..` path, a NUL, a leading slash, an empty component
        try add(a, "desk", "../escape.md", "x\n", ""),
        try std.fmt.allocPrint(a, "{{\"op\":\"add\",\"root_id\":\"desk\",\"path\":\"a\\u0000b.md\",\"content_base64\":\"{s}\"}}", .{try b64(a, "x\n")}),
        try add(a, "desk", "/abs.md", "x\n", ""),
        try add(a, "desk", "a//b.md", "x\n", ""),
        // a file outside the root, a symlinked file, a symlinked directory,
        // a `..` inside the file path
        try std.fmt.allocPrint(a, "{{\"op\":\"add\",\"root_id\":\"desk\",\"path\":\"s.txt\",\"file\":\"{s}\",\"sha256\":\"{s}\"}}", .{ outside, &hex("outside words\n") }),
        try std.fmt.allocPrint(a, "{{\"op\":\"add\",\"root_id\":\"desk\",\"path\":\"s.txt\",\"file\":\"{s}/link.txt\",\"sha256\":\"{s}\"}}", .{ desk, &hex("outside words\n") }),
        try std.fmt.allocPrint(a, "{{\"op\":\"add\",\"root_id\":\"desk\",\"path\":\"s.txt\",\"file\":\"{s}/linked/secret.txt\",\"sha256\":\"{s}\"}}", .{ desk, &hex("outside words\n") }),
        try std.fmt.allocPrint(a, "{{\"op\":\"add\",\"root_id\":\"desk\",\"path\":\"s.txt\",\"file\":\"{s}/notes/../../elsewhere/secret.txt\",\"sha256\":\"{s}\"}}", .{ desk, &hex("outside words\n") }),
        // both content fields, neither, `file` without sha256, non-strict base64
        try std.fmt.allocPrint(a, "{{\"op\":\"add\",\"root_id\":\"desk\",\"path\":\"b.txt\",\"file\":\"{s}/notes/words.txt\",\"content_base64\":\"eA==\",\"sha256\":\"{s}\"}}", .{ desk, &hex(words) }),
        "{\"op\":\"add\",\"root_id\":\"desk\",\"path\":\"b.txt\"}",
        try std.fmt.allocPrint(a, "{{\"op\":\"add\",\"root_id\":\"desk\",\"path\":\"b.txt\",\"file\":\"{s}/notes/words.txt\"}}", .{desk}),
        "{\"op\":\"add\",\"root_id\":\"desk\",\"path\":\"b.txt\",\"content_base64\":\"eA=\"}",
        "{\"op\":\"add\",\"root_id\":\"desk\",\"path\":\"b.txt\",\"content_base64\":\"eB==\"}",
        "{\"op\":\"add\",\"root_id\":\"desk\",\"path\":\"b.txt\",\"content_base64\":\"e A==\"}",
        // an unknown op, an unknown field, a bad root id, an undeclared root
        "{\"op\":\"rename\",\"root_id\":\"desk\",\"path\":\"b.txt\"}",
        "{\"op\":\"remove\",\"root_id\":\"desk\",\"path\":\"b.txt\",\"force\":true}",
        "{\"op\":\"remove\",\"root_id\":\"de/sk\",\"path\":\"b.txt\"}",
        "{\"op\":\"remove\",\"root_id\":\"vault\",\"path\":\"b.txt\"}",
    };
    for (cases) |case| {
        const refused = try f.applyFail(try joinChanges(a, roots, &.{ try add(a, "desk", "fine.md", "fine words\n", ""), case }), .{ .allow_file_reads = true });
        try std.testing.expectEqual(source.Code.invalid_argument, refused.code);
        try std.testing.expectEqualStrings(before, try f.listing());
    }
    // File reads disabled.
    const disabled = try f.applyFail(try joinChanges(a, roots, &.{ok_change}), .{});
    try std.testing.expect(std.mem.indexOf(u8, disabled.message, "file reads are not enabled") != null);
    // A root that is not local cannot take `file`; r-legacy is reserved.
    const icloud_roots = "[{\"root_id\":\"desk\",\"kind\":\"icloud\"}]";
    try std.testing.expectEqual(source.Code.invalid_argument, (try f.applyFail(try joinChanges(a, icloud_roots, &.{ok_change}), .{ .allow_file_reads = true })).code);
    try std.testing.expectEqual(source.Code.invalid_argument, (try f.applyFail("{\"roots\":[{\"root_id\":\"r-legacy\",\"kind\":\"local\"}],\"changes\":[]}", .{})).code);
    try std.testing.expectEqualStrings(before, try f.listing());
}

test "S3-T3: a batch over the caps is refused whole" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena();
    _ = try f.applyOk(try joinChanges(a, domain_roots, &.{try add(a, "home", "a.md", "alpha words\n", "")}), .{});
    const before = try f.listing();
    var many = std.ArrayList([]const u8).empty;
    for (0..apply.max_changes + 1) |i| try many.append(a, try std.fmt.allocPrint(a, "{{\"op\":\"remove\",\"root_id\":\"home\",\"path\":\"f{d}.md\"}}", .{i}));
    const over_count = try f.applyFail(try joinChanges(a, "[]", many.items), .{});
    try std.testing.expectEqual(source.Code.capacity, over_count.code);
    // Exactly 10,000 is accepted.
    _ = try f.applyOk(try joinChanges(a, "[]", many.items[0..apply.max_changes]), .{});
    const after_ok = try f.listing();
    const big = [_][]const u8{
        try add(a, "home", "b.md", "0123456789 0123456789\n", ""),
        try add(a, "home", "c.md", "0123456789 0123456789\n", ""),
    };
    const over_bytes = try f.applyFail(try joinChanges(a, "[]", &big), .{ .max_total_bytes = 30 });
    try std.testing.expectEqual(source.Code.capacity, over_bytes.code);
    try std.testing.expectEqualStrings(after_ok, try f.listing());
    try std.testing.expect(!std.mem.eql(u8, before, after_ok));
    // One file over max_file_bytes is too_large, not a refusal.
    const one = try f.applyOk(try joinChanges(a, "[]", big[0..1]), .{ .max_file_bytes = 10 });
    try std.testing.expectEqual(@as(usize, 1), one.too_large_paths.len);
    try std.testing.expectEqualStrings("b.md", one.too_large_paths[0].path);
}

test "S3-T3: a stale expect_generation is refused first, naming the current generation" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena();
    _ = try f.applyOk(try joinChanges(a, domain_roots, &.{try add(a, "home", "a.md", "alpha\n", "")}), .{});
    const before = try f.listing();
    const stale = try f.applyFail(try std.fmt.allocPrint(a, "{{\"expect_generation\":0,\"changes\":[{s}]}}", .{try add(a, "home", "b.md", "beta\n", "")}), .{});
    try std.testing.expectEqual(source.Code.invalid_argument, stale.code);
    try std.testing.expectEqualStrings("stale: generation is 1", stale.message);
    // Checked before the rest of the request: a stale and malformed request says stale.
    const both = try f.applyFail("{\"expect_generation\":7,\"changes\":[{\"op\":\"nope\"}],\"extra\":1}", .{});
    try std.testing.expectEqualStrings("stale: generation is 1", both.message);
    try std.testing.expectEqualStrings(before, try f.listing());
    const fresh = try f.applyOk(try std.fmt.allocPrint(a, "{{\"expect_generation\":1,\"changes\":[{s}]}}", .{try add(a, "home", "b.md", "beta\n", "")}), .{});
    try std.testing.expectEqual(@as(u64, 2), fresh.generation);
}

test "S3-T3: duplicate and conflicting changes apply in array order and are reported" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena();
    _ = try f.applyOk(try joinChanges(a, domain_roots, &.{try add(a, "home", "b.md", "beta words\n", "")}), .{});
    const changes = [_][]const u8{
        try add(a, "home", "a.md", "first words\n", ""),
        try add(a, "home", "a.md", "second words\n", ""),
        "{\"op\":\"remove\",\"root_id\":\"home\",\"path\":\"b.md\"}",
        try add(a, "home", "b.md", "beta again\n", ""),
        "{\"op\":\"remove\",\"root_id\":\"home\",\"path\":\"c.md\"}",
        "{\"op\":\"remove\",\"root_id\":\"home\",\"path\":\"c.md\"}",
    };
    const result = try f.applyOk(try joinChanges(a, "[]", &changes), .{});
    try std.testing.expectEqual(@as(usize, 3), result.conflicts.len);
    try std.testing.expectEqualStrings("a.md", result.conflicts[0].path);
    try std.testing.expectEqual(apply.Op.add, result.conflicts[0].replaced);
    try std.testing.expectEqual(apply.Op.add, result.conflicts[0].by);
    try std.testing.expectEqualStrings("b.md", result.conflicts[1].path);
    try std.testing.expectEqual(apply.Op.remove, result.conflicts[1].replaced);
    try std.testing.expectEqualStrings("c.md", result.conflicts[2].path);
    try std.testing.expectEqual(@as(usize, 1), result.added);
    try std.testing.expectEqual(@as(usize, 1), result.changed);
    try std.testing.expectEqual(@as(usize, 0), result.removed);
    const scoped = try f.opened();
    try std.testing.expectEqual(@as(usize, 0), (try searchPaths(scoped, a, "first", .{})).len);
    try std.testing.expectEqual(@as(usize, 1), (try searchPaths(scoped, a, "second", .{})).len);
    try std.testing.expectEqual(@as(usize, 1), (try searchPaths(scoped, a, "again", .{})).len);
}

test "S3-T3: rename detection pairs equal hashes by sorted path and reports ambiguous moves" {
    const same = "# Same\n\nidentical words in two files\n";
    var outcomes: [2][]const u8 = undefined;
    for ([_]bool{ false, true }, 0..) |reversed, run| {
        var f = try Fixture.init();
        defer f.deinit();
        const a = f.arena();
        _ = try f.applyOk(try joinChanges(a, domain_roots, &.{
            try add(a, "home", "x.md", same, ""),
            try add(a, "home", "y.md", same, ""),
            try add(a, "home", "keep.md", "kept words\n", ""),
        }), .{});
        const remove_x = "{\"op\":\"remove\",\"root_id\":\"home\",\"path\":\"x.md\"}";
        const remove_y = "{\"op\":\"remove\",\"root_id\":\"home\",\"path\":\"y.md\"}";
        const add_z = try add(a, "home", "z.md", same, "");
        const order: []const []const u8 = if (reversed) &.{ add_z, remove_y, remove_x } else &.{ remove_x, remove_y, add_z };
        const result = try f.applyOk(try joinChanges(a, "[]", order), .{});
        try std.testing.expectEqual(@as(usize, 1), result.moved);
        try std.testing.expectEqual(@as(usize, 1), result.removed);
        try std.testing.expectEqual(@as(usize, 0), result.added);
        try std.testing.expectEqual(@as(usize, 1), result.unchanged);
        try std.testing.expectEqual(@as(usize, 1), result.ambiguous_moves.len);
        const ambiguous = result.ambiguous_moves[0];
        try std.testing.expectEqual(@as(usize, 2), ambiguous.from.len);
        try std.testing.expectEqualStrings("x.md", ambiguous.from[0]);
        try std.testing.expectEqualStrings("y.md", ambiguous.from[1]);
        try std.testing.expectEqualStrings("x.md", ambiguous.pairs[0].from);
        try std.testing.expectEqualStrings("z.md", ambiguous.pairs[0].to);
        const state = (try incremental_state.load(a, io, f.out)).?;
        var moved_from: ?[]const u8 = null;
        for (state.files) |entry| if (std.mem.eql(u8, entry.path, "z.md")) {
            moved_from = entry.moved_from;
        };
        try std.testing.expectEqualStrings("x.md", moved_from.?);
        var out: std.Io.Writer.Allocating = .init(a);
        var json = std.json.Stringify{ .writer = &out.writer };
        try json.write(result.ambiguous_moves);
        outcomes[run] = try std.testing.allocator.dupe(u8, out.written());
    }
    defer for (outcomes) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings(outcomes[0], outcomes[1]);

    // One removed and one added with the same hash: a plain move, nothing ambiguous.
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena();
    _ = try f.applyOk(try joinChanges(a, domain_roots, &.{try add(a, "home", "old.md", same, "")}), .{});
    const plain = try f.applyOk(try joinChanges(a, "[]", &.{ "{\"op\":\"remove\",\"root_id\":\"home\",\"path\":\"old.md\"}", try add(a, "home", "new.md", same, "") }), .{});
    try std.testing.expectEqual(@as(usize, 1), plain.moved);
    try std.testing.expectEqual(@as(usize, 0), plain.ambiguous_moves.len);
    // An explicit move from an unknown path is rejected.
    const unknown = try f.applyOk("{\"changes\":[{\"op\":\"move\",\"root_id\":\"home\",\"path\":\"b.md\",\"moved_from\":\"nowhere.md\"}]}", .{});
    try std.testing.expectEqualStrings("move_source_unknown", unknown.rejected[0].reason);
}

test "S3-T3: a crash between the manifest and the state write leaves a readable generation; the next call reports unchanged" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena();
    _ = try f.applyOk(try joinChanges(a, domain_roots, &.{
        try add(a, "home", "a.md", "# A\n\nalpha words\n", ""),
        try add(a, "home", "b.md", "# B\n\nbeta words\n", ""),
    }), .{});
    const crash = try joinChanges(a, "[]", &.{try add(a, "home", "b.md", "# B\n\nbeta words, edited\n", "")});
    try std.testing.expectError(error.SimulatedCrash, apply.applyChanges(a, io, f.out, crash, .{ .fail_after_publish = true }));
    // The new generation is published and readable; the state names the old one.
    const scoped = try f.opened();
    try std.testing.expectEqual(@as(u64, 2), scoped.service.engine.generation);
    try std.testing.expectEqual(@as(usize, 1), (try searchPaths(scoped, a, "edited", .{})).len);
    try std.testing.expectEqual(@as(u64, 1), (try incremental_state.load(a, io, f.out)).?.generation);
    // The host retries the same content: nothing changed since generation 2.
    const retry = try f.applyOk(try joinChanges(a, "[]", &.{
        try add(a, "home", "a.md", "# A\n\nalpha words\n", ""),
        try add(a, "home", "b.md", "# B\n\nbeta words, edited\n", ""),
    }), .{});
    try std.testing.expectEqual(@as(usize, 2), retry.unchanged);
    try std.testing.expectEqual(@as(usize, 0), retry.changed);
    try std.testing.expectEqual(@as(usize, 0), retry.added);
    try std.testing.expectEqual(@as(u64, 3), retry.generation);
    try std.testing.expectEqual(@as(u64, 3), (try incremental_state.load(a, io, f.out)).?.generation);
}

test "S3-T3: index_folder's root and host roots share an index; --update leaves host roots alone" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena();
    try f.tmp.dir.createDirPath(io, "folder/notes");
    var folder = try f.tmp.dir.openDir(io, "folder", .{ .iterate = true });
    defer folder.close(io);
    try folder.writeFile(io, .{ .sub_path = "notes/plan.md", .data = "# Plan\n\nThe walk plan for Saturday.\n" });
    const first = try indexer.indexFolderIncremental(a, io, folder, f.out, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    try std.testing.expectEqual(@as(usize, 1), first.added);
    // A host root beside the folder root; a root id equal to a folder
    // directory would make record paths ambiguous and is refused.
    const collide = try f.applyFail(try joinChanges(a, "[{\"root_id\":\"notes\",\"kind\":\"host\"}]", &.{try add(a, "notes", "x.md", "x\n", "")}), .{});
    try std.testing.expect(std.mem.indexOf(u8, collide.message, "collides") != null);
    _ = try f.applyOk(try joinChanges(a, domain_roots, &.{try add(a, "home", "walk.md", "# Walk\n\nA walk by the canal.\n", "")}), .{});
    const second = try indexer.indexFolderIncremental(a, io, folder, f.out, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    try std.testing.expectEqual(@as(usize, 1), second.unchanged);
    try std.testing.expectEqual(@as(usize, 0), second.removed);
    const scoped = try f.opened();
    const hits = try searchPaths(scoped, a, "walk", .{});
    try std.testing.expect(contains(hits, "notes/plan.md"));
    try std.testing.expect(contains(hits, "home/walk.md"));
    const legacy_only = try searchPaths(scoped, a, "walk", .{ .roots = &.{"r-legacy"} });
    try std.testing.expectEqual(@as(usize, 1), legacy_only.len);
    try std.testing.expectEqualStrings("notes/plan.md", legacy_only[0]);
    // The state is version 2 and names both roots.
    const state = (try incremental_state.load(a, io, f.out)).?;
    try std.testing.expectEqual(@as(u32, 2), state.version);
    try std.testing.expectEqual(@as(usize, 3), state.roots.len);
}

test "S3-T3: the report JSON carries every section 6 field" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena();
    const result = try f.applyOk(try joinChanges(a, domain_roots, &.{try add(a, "home", "a.md", "alpha\n", "")}), .{});
    var out: std.Io.Writer.Allocating = .init(a);
    var json = std.json.Stringify{ .writer = &out.writer };
    try apply.writeReportJson(&json, result);
    const text = out.written();
    inline for (.{ "generation", "added", "changed", "removed", "moved", "pending", "unchanged", "too_large", "too_large_paths", "unreadable", "unreadable_paths", "rejected", "conflicts", "ambiguous_moves", "roots_removed", "budget_exhausted", "bytes_read", "ms" }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, text, "\"" ++ name ++ "\":") != null);
    }
}

// ------------------------------------------------- the judgment pack (UC-007) ---

fn hitOverlaps(root_id: []const u8, path: []const u8, start: u32, end: u32, expected: std.json.ObjectMap) bool {
    return std.mem.eql(u8, root_id, expected.get("root_id").?.string) and std.mem.eql(u8, path, expected.get("path").?.string) and
        start <= expected.get("end_line").?.integer and expected.get("start_line").?.integer <= end;
}

const PackHit = struct { root_id: []const u8, path: []const u8, start_line: u32, end_line: u32 };

/// `words` as the lifecycle steps use it: BM25 over the scope, then only
/// chunks holding every analyzed query term (S3-T2 owns the real `find`).
fn packFind(a: std.mem.Allocator, scoped: service_module.ScopedService, query: []const u8, roots: ?[]const []const u8) ![]PackHit {
    const results = try a.alloc(hybrid.Result, 100);
    const evidence = try a.alloc(@import("engine.zig").Evidence, 100);
    const found = try scoped.searchKnowledge(a, query, &.{}, .{ .retrieval_mode = .lexical, .top_k = 100 }, .{ .roots = roots }, results, evidence, null);
    const terms = try indexer.tokenize(a, .v2, query);
    var hits = std.ArrayList(PackHit).empty;
    const folder = scoped.service.folder.?;
    for (found, 0..) |item, i| {
        const tokens = try indexer.tokenize(a, .v2, item.content);
        var all = true;
        for (terms) |term| {
            var present = false;
            for (tokens) |token| if (std.mem.eql(u8, token, term)) {
                present = true;
            };
            all = all and present;
        }
        if (!all) continue;
        const root = folder.roots[folder.document_roots[results[i].document_index]];
        try hits.append(a, .{ .root_id = root.root_id, .path = scope.relativePath(root, item.path), .start_line = item.start_line, .end_line = item.end_line });
    }
    return hits.toOwnedSlice(a);
}

test "S3-T3: the family-folder lifecycle scenarios (UC-007 q11-q13) through apply_changes" {
    const pack = "../fixtures/family-folder";
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const judgments = try std.json.parseFromSliceLeaky(std.json.Value, a, try std.Io.Dir.cwd().readFileAlloc(io, pack ++ "/judgments.json", a, .unlimited), .{});
    var passed: usize = 0;
    for (judgments.object.get("scenarios").?.array.items) |scenario| {
        if (!std.mem.eql(u8, scenario.object.get("kind").?.string, "lifecycle")) continue;
        var f = try Fixture.init();
        defer f.deinit();
        // The three roots as `local` roots fed by `file` changes.
        var roots_json = std.ArrayList(u8).empty;
        var changes = std.ArrayList([]const u8).empty;
        try roots_json.append(a, '[');
        for (judgments.object.get("roots").?.array.items, 0..) |root_value, index| {
            const root_id = root_value.string;
            const folder_path = try std.Io.Dir.cwd().realPathFileAlloc(io, try std.fmt.allocPrint(a, "{s}/{s}", .{ pack, root_id }), a);
            if (index > 0) try roots_json.append(a, ',');
            try roots_json.print(a, "{{\"root_id\":\"{s}\",\"label\":\"{s}\",\"kind\":\"local\",\"retain_source\":true,\"path\":\"{s}\"}}", .{ root_id, root_id, folder_path });
            var folder = try std.Io.Dir.cwd().openDir(io, folder_path, .{ .iterate = true });
            defer folder.close(io);
            for (try indexer.collectCandidatePaths(a, io, folder)) |path| {
                const bytes = try folder.readFileAlloc(io, path, a, .unlimited);
                try changes.append(a, try std.fmt.allocPrint(a, "{{\"op\":\"add\",\"root_id\":\"{s}\",\"path\":\"{s}\",\"file\":\"{s}/{s}\",\"sha256\":\"{s}\"}}", .{ root_id, path, folder_path, path, &hex(bytes) }));
            }
        }
        try roots_json.append(a, ']');
        const first = try f.applyOk(try joinChanges(a, roots_json.items, changes.items), .{ .allow_file_reads = true });
        try std.testing.expectEqual(changes.items.len, first.added);

        var ok = true;
        for (scenario.object.get("steps").?.array.items) |step_value| {
            const step = step_value.object;
            const op = step.get("op").?.string;
            if (std.mem.eql(u8, op, "apply_changes")) {
                var batch = std.ArrayList([]const u8).empty;
                for (step.get("changes").?.array.items) |change| {
                    if (change.object.get("text")) |text| {
                        try batch.append(a, try add(a, change.object.get("root_id").?.string, change.object.get("path").?.string, text.string, ""));
                    } else {
                        var out: std.Io.Writer.Allocating = .init(a);
                        var json = std.json.Stringify{ .writer = &out.writer };
                        try json.write(change);
                        try batch.append(a, out.written());
                    }
                }
                const result = try f.applyOk(try joinChanges(a, "[]", batch.items), .{});
                var it = step.get("expect_report").?.object.iterator();
                while (it.next()) |entry| {
                    const want: usize = @intCast(entry.value_ptr.integer);
                    const got: usize = inline for (.{ "added", "changed", "removed", "pending", "moved", "roots_removed" }) |name| {
                        if (std.mem.eql(u8, entry.key_ptr.*, name)) break @field(result, name);
                    } else return error.UnknownReportField;
                    if (want != got) ok = false;
                }
            } else if (std.mem.eql(u8, op, "find")) {
                var roots: ?[]const []const u8 = null;
                if (step.get("roots")) |value| {
                    const list = try a.alloc([]const u8, value.array.items.len);
                    for (value.array.items, list) |item, *slot| slot.* = item.string;
                    roots = list;
                }
                const hits = try packFind(a, try f.opened(), step.get("query").?.string, roots);
                if (step.get("expect_hits")) |expected| {
                    for (expected.array.items) |e| {
                        var any = false;
                        for (hits) |h| any = any or hitOverlaps(h.root_id, h.path, h.start_line, h.end_line, e.object);
                        ok = ok and any;
                    }
                    for (hits) |h| {
                        var any = false;
                        for (expected.array.items) |e| any = any or hitOverlaps(h.root_id, h.path, h.start_line, h.end_line, e.object);
                        ok = ok and any;
                    }
                }
                if (step.get("expect_hits_include")) |expected| for (expected.array.items) |e| {
                    var any = false;
                    for (hits) |h| any = any or hitOverlaps(h.root_id, h.path, h.start_line, h.end_line, e.object);
                    ok = ok and any;
                };
                if (step.get("expect_paths_include")) |paths| for (paths.array.items) |p| {
                    var any = false;
                    for (hits) |h| any = any or std.mem.eql(u8, h.path, p.string);
                    ok = ok and any;
                };
                if (step.get("expect_paths_exclude")) |paths| for (paths.array.items) |p| {
                    for (hits) |h| ok = ok and !std.mem.eql(u8, h.path, p.string);
                };
                if (step.get("expect_empty") != null) ok = ok and hits.len == 0;
            } else if (std.mem.eql(u8, op, "index_status")) {
                const status = try (try f.opened()).indexStatus(a, .{});
                const expect = step.get("expect").?.object;
                if (expect.get("pending_paths")) |expected| {
                    ok = ok and expected.array.items.len == status.pending_paths.len;
                    for (expected.array.items, 0..) |e, i| {
                        if (i >= status.pending_paths.len) break;
                        ok = ok and std.mem.eql(u8, e.object.get("path").?.string, status.pending_paths[i].path) and
                            std.mem.eql(u8, e.object.get("root_id").?.string, status.pending_paths[i].root_id);
                    }
                }
                if (expect.get("roots")) |expected| {
                    ok = ok and expected.array.items.len == status.roots.len;
                    for (expected.array.items, 0..) |e, i| {
                        if (i < status.roots.len) ok = ok and std.mem.eql(u8, e.string, status.roots[i].root_id);
                    }
                }
                if (expect.get("no_trace_of_roots")) |gone| for (gone.array.items) |g| {
                    const state = (try incremental_state.load(a, io, f.out)).?;
                    for (state.roots) |root| ok = ok and !std.mem.eql(u8, root.root_id, g.string);
                    for (state.files) |file| ok = ok and !std.mem.eql(u8, file.root_id, g.string);
                    const scoped = try f.opened();
                    for (scoped.service.engine.documents) |document| ok = ok and !std.mem.startsWith(u8, document.path, g.string);
                    for (try scoped.listFiles(a, .{}, null, null)) |file| ok = ok and !std.mem.eql(u8, file.root_id, g.string);
                };
            } else return error.UnknownStep;
        }
        if (!ok) std.debug.print("lifecycle scenario {s} failed\n", .{scenario.object.get("id").?.string});
        try std.testing.expect(ok);
        passed += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), passed);
    std.debug.print("S3-T3 family-folder lifecycle through apply_changes: {d}/3 scenarios\n", .{passed});
}

test "S3-T3: find and index_status say pending_files and truncated, over the visible scope only" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena();
    _ = try f.applyOk(try joinChanges(a, domain_roots, &.{
        try add(a, "home", "notes.md", "# Notes\n\nthe canal walk\n", ""),
        try std.fmt.allocPrint(a, "{{\"op\":\"pending\",\"root_id\":\"home\",\"path\":\"later.md\",\"size\":10}}", .{}),
        try std.fmt.allocPrint(a, "{{\"op\":\"pending\",\"root_id\":\"home\",\"path\":\"secret.md\",\"size\":10,\"required_labels\":[\"adults\"]}}", .{}),
    }), .{});
    {
        const scoped = try f.opened();
        const answer = (try scoped.find(a, .{ .query = "canal" }, .{})).ok;
        try std.testing.expectEqual(@as(usize, 1), answer.hits.len);
        try std.testing.expectEqualStrings("home", answer.hits[0].root_id);
        try std.testing.expectEqualStrings("notes.md", answer.hits[0].path);
        try std.testing.expectEqual(@as(usize, 1), answer.pending_files); // the labelled one is hidden
        try std.testing.expect(!answer.truncated);
        try std.testing.expectEqual(@as(usize, 2), (try scoped.find(a, .{ .query = "canal" }, .{ .principal_labels = &.{"adults"} })).ok.pending_files);
        try std.testing.expectEqual(@as(usize, 0), (try scoped.find(a, .{ .query = "canal" }, .{ .roots = &.{"school"} })).ok.pending_files);
    }
    // A file over max_file_bytes is skipped: results over its root are truncated
    // until the path changes again; a hidden skipped file does not show.
    _ = try f.applyOk(try joinChanges(a, "[]", &.{
        try add(a, "home", "big.md", "0123456789 0123456789 0123456789\n", "[\"adults\"]"),
    }), .{ .max_file_bytes = 10 });
    {
        const scoped = try f.opened();
        try std.testing.expect(!(try scoped.find(a, .{ .query = "canal" }, .{})).ok.truncated);
        try std.testing.expect((try scoped.find(a, .{ .query = "canal" }, .{ .principal_labels = &.{"adults"} })).ok.truncated);
        try std.testing.expect((try scoped.indexStatus(a, .{ .principal_labels = &.{"adults"} })).truncated);
    }
    _ = try f.applyOk(try joinChanges(a, "[]", &.{try add(a, "home", "plain.md", "plain\n", "")}), .{ .max_file_bytes = 10 });
    _ = try f.applyOk(try joinChanges(a, "[]", &.{try add(a, "home", "huge.md", "0123456789 0123456789 0123456789\n", "")}), .{ .max_file_bytes = 10 });
    try std.testing.expect((try (try f.opened()).find(a, .{ .query = "canal" }, .{})).ok.truncated);
    try std.testing.expect(!(try (try f.opened()).find(a, .{ .query = "canal" }, .{ .roots = &.{"school"} })).ok.truncated);
    _ = try f.applyOk(try joinChanges(a, "[]", &.{try add(a, "home", "huge.md", "small now\n", "")}), .{});
    try std.testing.expect(!(try (try f.opened()).find(a, .{ .query = "canal" }, .{})).ok.truncated);
}

test "S3-T3: a generation carrying unchanged documents has the lexical section a fresh positional build gives" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena();
    _ = try f.applyOk(try joinChanges(a, domain_roots, &.{
        try add(a, "home", "a.md", "# A\n\nThe canal boat, the canal lock and Café rocks.\n", ""),
        try add(a, "home", "b.txt", "the the the boat\nboat lock\n", ""),
        try add(a, "school", "c.md", "# C\n\nபள்ளி விடுமுறை and a lock\n", ""),
    }), .{});
    _ = try f.applyOk(try joinChanges(a, "[]", &.{
        try add(a, "home", "b.txt", "a new boat with ducks\n", ""),
        "{\"op\":\"move\",\"root_id\":\"home\",\"path\":\"z/a.md\",\"moved_from\":\"a.md\"}",
    }), .{});
    const scoped = try f.opened();
    const engine = scoped.service.engine;
    const lists = try a.alloc([]const @import("analysis.zig").PositionedToken, engine.documents.len);
    for (engine.documents, lists) |document, *list| list.* = try indexer.tokenizePositioned(a, .v2, document.text);
    const fresh = try lexical_build.buildPositional(a, engine.documents, lists);
    const expected = try a.alloc(u8, try @import("lexical_segment.zig").encodedLength(fresh));
    _ = try @import("lexical_segment.zig").encode(fresh, expected);
    const metadata = try manifest.decode(try f.out.readFileAlloc(io, "MANIFEST", a, .unlimited));
    try std.testing.expectEqualSlices(u8, expected, try f.out.readFileAlloc(io, metadata.lexical_file, a, .unlimited));
    try std.testing.expect(metadata.has_positions);
}

test "committed recovery state preserves own labels, hashes, mtimes, pending and moves without cache" {
    var f = try Fixture.init(); defer f.deinit();
    const a = f.arena();
    const initial = try joinChanges(a, "[{\"root_id\":\"home\",\"kind\":\"host\",\"retain_source\":false,\"required_labels\":[\"shared\"]}]", &.{
        try add(a, "home", "note.md", "copper recovery evidence", "[\"shared\"]"),
        try add(a, "home", "empty.txt", "", "[\"shared\"]"),
        "{\"op\":\"pending\",\"root_id\":\"home\",\"path\":\"waiting.txt\",\"size\":123,\"mtime_ms\":77,\"required_labels\":[\"shared\"]}",
    });
    _ = try f.applyOk(initial, .{});
    // S4-T2 R3: the committed state is the generation's own section, bound
    // by the manifest (flag bit 4), not a copy inside `meta`.
    const first = try manifest.decode(try f.out.readFileAlloc(io, "MANIFEST", a, .unlimited));
    try std.testing.expectEqualStrings("state-1.hybstate", first.state.?.file);
    try std.testing.expect(std.mem.indexOf(u8, first.meta, "recovery_state") == null);
    const moved = "{\"changes\":[{\"op\":\"move\",\"root_id\":\"home\",\"path\":\"moved.md\",\"moved_from\":\"note.md\",\"mtime_ms\":999}]}";
    try std.testing.expectError(error.SimulatedCrash, apply.applyChanges(a, io, f.out, moved, .{ .fail_after_publish = true }));
    // Neither the host bytes nor a matching mutable state are available.
    try f.out.deleteFile(io, incremental_state.state_file);
    _ = try f.applyOk("{\"changes\":[]}", .{});
    const recovered = (try incremental_state.load(a, io, f.out)).?;
    try std.testing.expectEqual(@as(usize, 3), recovered.files.len);
    for (recovered.files) |file| {
        try std.testing.expectEqual(@as(usize, 1), file.required_labels.len);
        try std.testing.expectEqualStrings("shared", file.required_labels[0]);
        if (std.mem.eql(u8, file.path, "moved.md")) {
            try std.testing.expectEqualStrings("note.md", file.moved_from.?);
            try std.testing.expectEqual(@as(i64, 999), file.mtime_ms.?);
            try std.testing.expect(file.hash.len == 64);
        } else if (std.mem.eql(u8, file.path, "waiting.txt")) {
            try std.testing.expectEqual(@as(i64, 77), file.mtime_ms.?);
            try std.testing.expectEqual(incremental_state.Status.pending, file.status);
        }
    }
    // Removing an inherited requirement must not strip an identical own label.
    _ = try f.applyOk("{\"roots\":[{\"root_id\":\"home\",\"required_labels\":[]}],\"changes\":[]}", .{});
    const scoped = try f.opened();
    const hidden = try searchPaths(scoped, a, "copper", .{});
    try std.testing.expectEqual(@as(usize, 0), hidden.len);
    // A corrupt compatibility cache also cannot replace committed authority.
    try f.out.writeFile(io, .{ .sub_path = incremental_state.state_file, .data = "not json" });
    const recovered_report = try f.applyOk(try joinChanges(a, "[]", &.{try add(a, "home", "moved.md", "copper recovery evidence", "[\"shared\"]")}), .{});
    try std.testing.expect(recovered_report.unchanged >= 1);
}

test "S4-T2 R3: a damaged recovery-state section refuses the write and readers still open" {
    var f = try Fixture.init(); defer f.deinit();
    const a = f.arena();
    _ = try f.applyOk(try joinChanges(a, "[{\"root_id\":\"home\",\"kind\":\"host\"}]", &.{try add(a, "home", "note.md", "copper harbour evidence", "[]")}), .{});
    const metadata = try manifest.decode(try f.out.readFileAlloc(io, "MANIFEST", a, .unlimited));
    const bound = metadata.state.?;
    const original = try f.out.readFileAlloc(io, bound.file, a, .unlimited);
    try std.testing.expectEqual(bound.bytes, original.len);
    const next = "{\"changes\":[]}";

    // One flipped payload byte: the checksum no longer matches.
    const flipped = try a.dupe(u8, original);
    flipped[flipped.len - 2] ^= 0x01;
    try f.out.writeFile(io, .{ .sub_path = bound.file, .data = flipped });
    const before = try f.listing();
    try std.testing.expectError(error.StateSectionChecksumMismatch, apply.applyChanges(a, io, f.out, next, .{}));
    try std.testing.expectEqualStrings(before, try f.listing());
    // The reader never reads the section: the generation opens and answers.
    const scoped = try f.opened();
    try std.testing.expectEqual(@as(usize, 1), (try searchPaths(scoped, a, "copper", .{})).len);

    // A short file: the size no longer matches the manifest.
    try f.out.writeFile(io, .{ .sub_path = bound.file, .data = original[0 .. original.len - 1] });
    try std.testing.expectError(error.StateSectionSizeMismatch, apply.applyChanges(a, io, f.out, next, .{}));
    // A flipped magic byte with the size kept: the header is refused.
    const bad_magic = try a.dupe(u8, original);
    bad_magic[0] = 'X';
    try f.out.writeFile(io, .{ .sub_path = bound.file, .data = bad_magic });
    try std.testing.expectError(error.InvalidStateSection, apply.applyChanges(a, io, f.out, next, .{}));

    // Restored, the next write succeeds and binds its own state section;
    // pruning removes the superseded one with its generation.
    try f.out.writeFile(io, .{ .sub_path = bound.file, .data = original });
    _ = try f.applyOk(next, .{ .keep_generations = 1 });
    const after = try manifest.decode(try f.out.readFileAlloc(io, "MANIFEST", a, .unlimited));
    try std.testing.expect(after.generation > metadata.generation);
    try std.testing.expect(!std.mem.eql(u8, after.state.?.file, bound.file));
    try std.testing.expectError(error.FileNotFound, f.out.statFile(io, bound.file, .{}));
}

test "restricted writers cannot change root policy, hidden files or labels" {
    var f = try Fixture.init(); defer f.deinit();
    const a = f.arena();
    _ = try f.applyOk(try joinChanges(a, two_roots, &.{ try add(a, "home", "public.md", "public copper", "[]"), try add(a, "home", "secret.md", "secret gold", "[\"secret\"]") }), .{});
    const options = apply.Options{ .write_roots = &.{"home"}, .write_labels = &.{} };
    const before = try f.listing();
    for ([_][]const u8{
        "{\"roots\":[{\"root_id\":\"home\",\"required_labels\":[]}],\"changes\":[]}",
        "{\"changes\":[{\"op\":\"remove\",\"root_id\":\"home\",\"path\":\"secret.md\"}]}",
        "{\"changes\":[{\"op\":\"move\",\"root_id\":\"home\",\"path\":\"secret.md\",\"moved_from\":\"public.md\"}]}",
        "{\"changes\":[{\"op\":\"remove_root\",\"root_id\":\"home\"}]}",
        "{\"changes\":[{\"op\":\"remove_root\",\"root_id\":\"school\"}]}",
    }) |request| {
        _ = try f.applyFail(request, options);
        try std.testing.expectEqualStrings(before, try f.listing());
    }
    const changed = try f.applyOk(try joinChanges(a, "[]", &.{try add(a, "home", "public.md", "public silver", "[]")}), options);
    try std.testing.expectEqual(@as(usize, 1), changed.changed);
}

//! S6-T18: `engine.queryOneShot`, the one-shot lexical query that ranks with
//! the title field (`searchd query`, `evidence` and `search` under `content`).
//! It must answer exactly as the command line did when it derived the field
//! itself (derive, then `Engine.queryTokenized`), allocate the same from the
//! allocator it is given, and not derive again for an engine whose scoped
//! open already holds a field. Invented content only.
const std = @import("std");
const analyzer_v2 = @import("analyzer_v2.zig");
const chunker = @import("chunker.zig");
const engine_module = @import("engine.zig");
const hybrid = @import("hybrid.zig");
const indexer = @import("indexer.zig");
const lexical_build = @import("lexical_build.zig");
const manifest = @import("manifest.zig");
const postings = @import("postings.zig");
const snapshot_open = @import("snapshot_open.zig");
const title_field = @import("title_field.zig");

const roots = [_]manifest.RootEntry{.{ .root_id = "r-home", .label = "home", .kind = "local", .retain_source = true }};

const docs = [_]hybrid.Document{
    .{ .id = "g-1", .text = "tomato rows by the fence", .path = "r-home/garden/plan.md", .start_line = 1, .end_line = 4 },
    .{ .id = "g-2", .text = "beans climb the poles", .path = "r-home/garden/plan.md", .start_line = 5, .end_line = 8 },
    .{ .id = "h-1", .text = "the nurse said to rest", .path = "r-home/health/doctor-visits.md", .start_line = 1, .end_line = 3 },
    .{ .id = "n-1", .text = "a note about tomato soup", .path = "r-home/notes.md", .start_line = 1, .end_line = 2 },
    .{ .id = "t-1", .text = "high water at noon", .path = "r-home/trips/harbour-tides.md", .start_line = 1, .end_line = 2 },
};

/// An engine over `docs`, its dictionary sorted bytewise (as `HYBLEX02` is).
fn makeEngine(a: std.mem.Allocator) !engine_module.Engine {
    const token_lists = try a.alloc([][]const u8, docs.len);
    for (docs, token_lists) |doc, *tokens_out| tokens_out.* = try analyzer_v2.tokenize(a, doc.text);
    var index = try lexical_build.build(a, &docs, token_lists);
    const terms = try a.dupe(postings.TermEntry, index.terms);
    std.mem.sort(postings.TermEntry, terms, {}, struct {
        fn less(_: void, x: postings.TermEntry, y: postings.TermEntry) bool {
            return std.mem.order(u8, x.term, y.term) == .lt;
        }
    }.less);
    index.terms = terms;
    index.sorted_terms = true;
    return .{ .generation = 1, .analyzer_id = analyzer_v2.analyzer_id, .embedding_model_id = "", .vector_dimensions = 0, .documents = &docs, .lexical_index = index, .roots = &roots };
}

/// What `interfaces/cli.zig`'s `runSearch` did before S6-T18, line for line:
/// the reference the call is held to.
fn deriveThenQuery(allocator: std.mem.Allocator, engine: engine_module.Engine, query_text: []const u8, top_k: usize) ![]hybrid.Result {
    const result_output = try allocator.alloc(hybrid.Result, engine.documents.len);
    const title = try title_field.derive(allocator, allocator, engine.documents, engine.roots);
    const options = hybrid.SearchOptions{ .top_k = top_k, .candidate_k = @max(top_k, engine.documents.len), .retrieval_mode = .lexical, .title = &title.field };
    return engine.queryTokenized(allocator, query_text, &.{}, result_output, options);
}

/// A pass-through allocator that counts the calls and bytes asked of it and
/// the most bytes live at once.
const Counting = struct {
    parent: std.mem.Allocator,
    allocs: usize = 0,
    frees: usize = 0,
    bytes: usize = 0,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn grew(self: *Counting, old: usize, new: usize) void {
        self.live = self.live - old + new;
        if (new > old) self.bytes += new - old;
        self.peak = @max(self.peak, self.live);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const result = self.parent.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocs += 1;
        self.grew(0, len);
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (!self.parent.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.grew(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const result = self.parent.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.grew(memory.len, new_len);
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, alignment, ret_addr);
        self.frees += 1;
        self.live -= memory.len;
    }
};

fn expectSameResults(want: []const hybrid.Result, got: []const hybrid.Result) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try std.testing.expectEqual(w.document_index, g.document_index);
        try std.testing.expectEqualStrings(w.document_id, g.document_id);
        try std.testing.expectEqualStrings(w.path, g.path);
        try std.testing.expectEqual(w.start_line, g.start_line);
        try std.testing.expectEqual(w.end_line, g.end_line);
        try std.testing.expectEqual(@as(u32, @bitCast(w.fused_score)), @as(u32, @bitCast(g.fused_score)));
        try std.testing.expectEqual(@as(u32, @bitCast(w.lexical_score)), @as(u32, @bitCast(g.lexical_score)));
        try std.testing.expectEqual(@as(u32, @bitCast(w.semantic_score)), @as(u32, @bitCast(g.semantic_score)));
        try std.testing.expectEqual(w.lexical_rank, g.lexical_rank);
        try std.testing.expectEqual(w.semantic_rank, g.semantic_rank);
        try std.testing.expectEqual(w.title_score == null, g.title_score == null);
        if (w.title_score) |score| try std.testing.expectEqual(@as(u32, @bitCast(score)), @as(u32, @bitCast(g.title_score.?)));
    }
}

const queries = [_][]const u8{ "tomato", "garden", "harbour tides", "doctor rest", "tomatoes", "nothing-here", "the", "Garden PLAN" };

test "one-shot query: the answers of deriving the field and querying, allocation for allocation" {
    var engine_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer engine_arena.deinit();
    const engine = try makeEngine(engine_arena.allocator());
    for (queries) |query| for ([_]usize{ 1, 3, 10 }) |top_k| {
        // Two fresh arenas, so that each grows (and resizes in place) alike.
        var want_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer want_arena.deinit();
        var got_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer got_arena.deinit();
        var want_count = Counting{ .parent = want_arena.allocator() };
        var got_count = Counting{ .parent = got_arena.allocator() };
        const want = try deriveThenQuery(want_count.allocator(), engine, query, top_k);
        const got = try engine_module.queryOneShot(engine, got_count.allocator(), query, top_k);
        try expectSameResults(want, got);
        try std.testing.expectEqual(want_count.allocs, got_count.allocs);
        try std.testing.expectEqual(want_count.frees, got_count.frees);
        try std.testing.expectEqual(want_count.bytes, got_count.bytes);
        try std.testing.expectEqual(want_count.peak, got_count.peak);
        try std.testing.expectEqual(want_count.live, got_count.live);
    };
}

test "one-shot query: ranks with the title field (a title-only file is found)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const engine = try makeEngine(a);
    // "garden" is in no chunk's text, only in the folder name of garden/plan.md.
    const found = try engine_module.queryOneShot(engine, a, "garden", 10);
    try std.testing.expect(found.len >= 1);
    try std.testing.expectEqualStrings("r-home/garden/plan.md", found[0].path);
    try std.testing.expect(found[0].title_score != null);
    // Without the field the same query finds nothing.
    const plain = try engine.queryTokenized(a, "garden", &.{}, try a.alloc(hybrid.Result, docs.len), .{ .top_k = 10, .candidate_k = docs.len, .retrieval_mode = .lexical });
    try std.testing.expectEqual(@as(usize, 0), plain.len);
}

test "one-shot query: invalid UTF-8 is refused, and out of memory is returned" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const engine = try makeEngine(a);
    try std.testing.expectError(error.InvalidQueryText, engine_module.queryOneShot(engine, a, "tomato \xff", 10));
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var inner = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer inner.deinit();
        var failing = std.testing.FailingAllocator.init(inner.allocator(), .{ .fail_index = fail_index });
        if (engine_module.queryOneShot(engine, failing.allocator(), "tomato garden", 10)) |_| {
            break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    } else return error.TestUnexpectedResult;
    try std.testing.expect(fail_index > 0);
}

test "one-shot query: a scoped open ranks with its folder's field, derived once by the folder, nothing from the caller's allocator" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var folder_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer folder_tmp.cleanup();
    var out_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer out_tmp.cleanup();
    try folder_tmp.dir.createDirPath(io, "garden");
    try folder_tmp.dir.writeFile(io, .{ .sub_path = "garden/plan.md", .data = "# Plan\n\nTomatoes by the fence.\n" });
    try folder_tmp.dir.writeFile(io, .{ .sub_path = "week.md", .data = "# Week\n\nThe tide table for the harbour walk.\n" });
    _ = try indexer.indexFolderIncremental(a, io, folder_tmp.dir, out_tmp.dir, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    const eager = try snapshot_open.open(a, io, out_tmp.dir);
    const opened = try snapshot_open.openScoped(a, io, out_tmp.dir);
    defer opened.folder.close();
    const loads = opened.folder.loads;
    try std.testing.expect(!opened.folder.titleDerived());
    for ([_][]const u8{ "garden", "tide", "week tomatoes" }) |query| {
        var call_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer call_arena.deinit();
        var count = Counting{ .parent = call_arena.allocator() };
        const scoped = try engine_module.queryOneShot(opened.engine, count.allocator(), query, 10);
        try std.testing.expect(opened.folder.titleDerived());
        try std.testing.expectEqual(@as(u32, 1), loads.title_loads);
        // The call derived nothing into its allocator: it allocated exactly what
        // the ranking with the folder's field allocates.
        var ref_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer ref_arena.deinit();
        var ref_count = Counting{ .parent = ref_arena.allocator() };
        const r = ref_count.allocator();
        const options = hybrid.SearchOptions{ .top_k = 10, .candidate_k = @max(10, opened.engine.documents.len), .retrieval_mode = .lexical, .title = try opened.folder.titleField() };
        const reference = try opened.engine.queryTokenized(r, query, &.{}, try r.alloc(hybrid.Result, opened.engine.documents.len), options);
        try std.testing.expectEqual(ref_count.allocs, count.allocs);
        try std.testing.expectEqual(ref_count.bytes, count.bytes);
        try std.testing.expectEqual(ref_count.peak, count.peak);
        try expectSameResults(reference, scoped);
        // And the eager open, which derives its own field, answers the same.
        try expectSameResults(try engine_module.queryOneShot(eager, a, query, 10), scoped);
    }
    try std.testing.expectEqual(@as(u32, 1), loads.title_loads);
}

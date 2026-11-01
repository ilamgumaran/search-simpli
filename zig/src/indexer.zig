//! Native folder indexing (S1-T1 acceptance criterion 3): walks a folder
//! and indexes its UTF-8 text/markdown/source files, lexical-only (no
//! embeddings), no Python involved. Since S3-T3 the walk builds an
//! `apply_changes` batch (one `local` root `r-legacy`, one change per
//! candidate file) and `apply.applyBatch` chunks, tokenizes and publishes it,
//! so one code path writes every generation. Extension list and
//! ignored-directory set mirror
//! `search_platform.core.DEFAULT_EXTENSIONS`/`IGNORED_DIRECTORIES` exactly,
//! so the same folder produces the same candidate file set as the Python
//! reference.
const std = @import("std");
const analysis = @import("analysis.zig");
const analyzer_v2 = @import("analyzer_v2.zig");
const apply = @import("apply.zig");
const chunker = @import("chunker.zig");
const incremental_state = @import("incremental_state.zig");
const scope = @import("scope.zig");
const snapshot_open = @import("snapshot_open.zig");

pub const AnalyzerId = enum {
    v1,
    v2,

    pub fn label(self: AnalyzerId) []const u8 {
        return switch (self) {
            .v1 => "analyzer-v1",
            .v2 => "analyzer-v2",
        };
    }

    pub fn parse(text: []const u8) ?AnalyzerId {
        if (std.mem.eql(u8, text, "analyzer-v1") or std.mem.eql(u8, text, "v1")) return .v1;
        if (std.mem.eql(u8, text, "analyzer-v2") or std.mem.eql(u8, text, "v2")) return .v2;
        return null;
    }
};

/// `search_platform.core.DEFAULT_EXTENSIONS`.
pub const default_extensions = [_][]const u8{
    ".c", ".cpp", ".css", ".go", ".h", ".html", ".java", ".js", ".json",
    ".md", ".py", ".rs", ".rst", ".toml", ".ts", ".txt", ".yaml", ".yml", ".zig",
};

/// `search_platform.core.IGNORED_DIRECTORIES`.
pub const ignored_directories = [_][]const u8{
    ".git", ".search", ".zig-cache", "__pycache__", "node_modules", "zig-out",
};

pub const IndexReport = struct {
    generation: u64,
    analyzer_id: []const u8,
    files_indexed: usize,
    files_skipped: usize,
    /// Relative paths of every file counted under `files_skipped` (stat
    /// failure, oversized-for-usize, read failure, invalid UTF-8, or a
    /// chunker error) -- S1-T4 criterion 3: a skipped file is never silent,
    /// it is always named.
    unreadable_paths: [][]const u8,
    documents: usize,
    terms: usize,
    postings: usize,
};

fn hasAllowedExtension(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const suffix = name[dot..];
    var lowered_buffer: [16]u8 = undefined;
    if (suffix.len > lowered_buffer.len) return false;
    for (suffix, 0..) |byte, i| lowered_buffer[i] = std.ascii.toLower(byte);
    const lowered = lowered_buffer[0..suffix.len];
    for (default_extensions) |candidate| {
        if (std.mem.eql(u8, candidate, lowered)) return true;
    }
    return false;
}

fn isIgnoredComponent(part: []const u8) bool {
    if (part.len > 0 and part[0] == '.') return true;
    for (ignored_directories) |ignored| {
        if (std.mem.eql(u8, ignored, part)) return true;
    }
    return false;
}

fn isIgnoredPath(relative_path: []const u8) bool {
    var it = std.mem.splitScalar(u8, relative_path, '/');
    while (it.next()) |part| {
        if (isIgnoredComponent(part)) return true;
    }
    return false;
}

fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Walk `root` and return every candidate file's relative path (matching
/// extension, not under an ignored directory/dotfile), sorted. Shared by
/// `indexFolder` and `indexFolderIncremental` so both see the same file set
/// for the same folder.
pub fn collectCandidatePaths(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir) ![][]const u8 {
    var paths = std.ArrayList([]const u8).empty;
    var walker = try root.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (isIgnoredPath(entry.path)) continue;
        if (!hasAllowedExtension(entry.basename)) continue;
        try paths.append(allocator, try allocator.dupe(u8, entry.path));
    }
    const items = try paths.toOwnedSlice(allocator);
    std.mem.sort([]const u8, items, {}, lessThanPath);
    return items;
}

fn tokenizeV1(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var tokens = std.ArrayList([]const u8).empty;
    defer tokens.deinit(allocator);
    var iterator = analysis.TokenIterator.init(text);
    while (iterator.next()) |token| {
        const owned = try allocator.alloc(u8, token.bytes.len);
        for (token.bytes, 0..) |byte, i| owned[i] = std.ascii.toLower(byte);
        try tokens.append(allocator, owned);
    }
    return tokens.toOwnedSlice(allocator);
}

pub fn tokenize(allocator: std.mem.Allocator, analyzer: AnalyzerId, text: []const u8) ![][]const u8 {
    return switch (analyzer) {
        .v1 => tokenizeV1(allocator, text),
        .v2 => analyzer_v2.tokenize(allocator, text),
    };
}

/// `tokenize` with each token's codepoint span in `text` (S3-T2): what the
/// positional lexical build (`HYBLEX02`) records as ordinals and offsets.
pub fn tokenizePositioned(allocator: std.mem.Allocator, analyzer: AnalyzerId, text: []const u8) ![]const analysis.PositionedToken {
    return switch (analyzer) {
        .v1 => analysis.tokenizePositioned(allocator, text, true),
        .v2 => analyzer_v2.tokenizePositioned(allocator, text),
    };
}

/// The one root `index_folder` writes (S3-T1): its records keep bare
/// relative paths (`scope.zig`).
pub const legacy_root_id = scope.legacy_root_id;

/// Walk `root`, chunk and tokenize every matching file, and publish a fresh
/// generation into `out_dir` (a full rebuild: the previous generation, if
/// any, is not consulted). `allocator` is expected to be an arena.
///
/// S3-T3 (ruling 2): this is a walk that builds an `apply_changes` batch
/// (one `local` root `r-legacy`, one `walk` change per candidate file) and
/// hands it to `apply.applyBatch`, so one code path writes every generation.
/// The report keeps every S1 field.
///
/// An empty folder (no candidate files, or every candidate file skipped)
/// publishes an empty generation (0 documents/terms/postings) rather than
/// failing -- S1-T4 criterion 3. A file over `caps.max_file_bytes` is not
/// read and is reported as `too_large`; once `caps.max_total_bytes` has been
/// read in this run every remaining candidate is left out and counted as
/// `budget_exhausted` (S1-T5 criterion 1). A full rebuild reports
/// `changed`/`removed`/`unchanged` as 0 and `added` as the files it indexed.
pub fn indexFolder(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    out_dir: std.Io.Dir,
    analyzer: AnalyzerId,
    generation: u64,
    max_chars: usize,
    overlap_lines: usize,
    caps: Caps,
) !IncrementalReport {
    return walkAndApply(allocator, io, root, out_dir, analyzer, max_chars, overlap_lines, caps, true, generation);
}

fn walkAndApply(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    out_dir: std.Io.Dir,
    analyzer: AnalyzerId,
    max_chars: usize,
    overlap_lines: usize,
    caps: Caps,
    fresh: bool,
    generation: ?u64,
) !IncrementalReport {
    const paths = try collectCandidatePaths(allocator, io, root);
    const changes = try allocator.alloc(apply.Change, paths.len);
    for (paths, changes) |path, *change| {
        change.* = .{ .op = .change, .root_id = legacy_root_id, .path = path, .content = .{ .walk = .{ .dir = root, .sub_path = path } } };
    }
    const roots = [_]apply.RootDecl{.{ .root_id = legacy_root_id, .label = "folder", .kind = "local", .retain_source = caps.retain_source }};
    const outcome = try apply.applyBatch(allocator, io, out_dir, .{ .roots = &roots, .changes = changes }, .{
        .analyzer = analyzer,
        .max_chars = max_chars,
        .overlap_lines = overlap_lines,
        .filename_index = caps.filename_index,
        .max_file_bytes = caps.max_file_bytes,
        .max_total_bytes = caps.max_total_bytes,
        .keep_generations = caps.keep_generations,
        .origin = "folder",
        .budget = .exhaust,
        // A rename in a walked folder stays `removed` + `added`: the S1
        // report has no `moved` field (host batches detect renames).
        .detect_renames = false,
        .complete_root = legacy_root_id,
        .fresh = fresh,
        .generation = generation,
    });
    const report = switch (outcome) {
        .ok => |r| r,
        .failed => return error.ApplyRefused,
    };
    return .{
        .generation = report.generation,
        .analyzer_id = report.analyzer_id,
        .added = report.added,
        .changed = report.changed,
        .removed = report.removed,
        .unchanged = report.unchanged,
        .budget_exhausted = report.budget_exhausted_paths.len,
        .too_large = report.too_large_paths.len,
        .unreadable = report.unreadable_paths.len,
        .too_large_paths = try relativePaths(allocator, report.too_large_paths),
        .unreadable_paths = try relativePaths(allocator, report.unreadable_paths),
        .documents = report.documents,
        .terms = report.terms,
        .postings = report.postings,
        .pruned_files = report.pruned_files,
        .prune_failures = report.prune_failures,
        .recovered = report.recovered,
    };
}

fn relativePaths(allocator: std.mem.Allocator, refs: []const apply.PathRef) ![][]const u8 {
    const out = try allocator.alloc([]const u8, refs.len);
    for (refs, out) |ref, *path| path.* = ref.path;
    return out;
}

/// Caps applied to a single `indexFolder` or `indexFolderIncremental` run
/// alike (S1-T5, round-E rework: `indexFolder` did not enforce
/// `max_total_bytes` at all before this). Both come from the caller's
/// `opts` (CLI flags or `ss_index_folder`'s `opts` JSON object) -- see
/// `docs/tasks/S1-T3.md` criterion 2.
pub const Caps = struct {
    filename_index: bool = false,
    /// S2-T5, opt-in (`null`, the default, deletes nothing): after a
    /// successful publish, delete the section files of generations older
    /// than the newest `keep_generations` (>= 1). Carried here because
    /// `Caps` already travels from every caller (CLI, `ss_index_folder`)
    /// through `indexFolder`/`indexFolderIncremental` to the publish call.
    keep_generations: ?usize = null,
    /// A file larger than this (bytes) is never read; it is excluded from
    /// the index and counted under the report's `too_large`.
    max_file_bytes: u64 = 10 * 1024 * 1024,
    /// Once this many bytes have been read from disk in this run, remaining
    /// unprocessed candidate files are left untouched for this generation
    /// and counted under the report's `budget_exhausted`. On
    /// `indexFolderIncremental`, a left-over file's previous chunks (if any)
    /// are carried forward unchanged; `indexFolder` (a full rebuild) has no
    /// previous generation to carry anything forward from, so a left-over
    /// file there is simply absent from the new generation, the same as a
    /// file over `max_file_bytes`. Guards worst-case run time on an enormous
    /// folder; a later `--update` run picks up where this one left off.
    max_total_bytes: u64 = 512 * 1024 * 1024,
    /// S3-T1 (CAP-19 FR-22, implementation section 4): keep every indexed
    /// file's original bytes in the generation's source section so
    /// `read_span` is byte-exact. Default true for `index_folder` in this
    /// task (ruling 4); false writes no source section and `read_span`
    /// answers `CAPACITY` "re-index required: source absent".
    retain_source: bool = true,
};

pub const IncrementalReport = struct {
    generation: u64,
    analyzer_id: []const u8,
    added: usize,
    changed: usize,
    removed: usize,
    /// Unchanged since the previous generation (content hash matched
    /// `INDEX-STATE.json`) -- nothing to do. S1-T4 criterion 3 splits this
    /// out of the old, ambiguous `skipped` (round-B non-blocking finding 5):
    /// a caller can no longer confuse "finished, nothing changed" with
    /// "ran out of budget, try again".
    unchanged: usize,
    /// Left untouched for this generation because `caps.max_total_bytes`
    /// was exhausted first; the file's previous chunks (if any) are carried
    /// forward unchanged and it is eligible again on the next run.
    budget_exhausted: usize,
    too_large: usize,
    unreadable: usize,
    /// Relative paths of every file counted under `too_large` -- S1-T4
    /// criterion 3. A file that grows past `caps.max_file_bytes` is
    /// tombstoned (its previous chunks are not carried forward: see the
    /// call site in `indexFolderIncremental`), never silently kept, and
    /// this path list is what keeps that tombstoning from being silent
    /// about *which* file it happened to.
    too_large_paths: [][]const u8,
    /// Relative paths of every file counted under `unreadable` -- S1-T4
    /// criterion 3 (round-B non-blocking finding 6). Unlike `too_large`,
    /// an unreadable file's previous chunks (if any) are carried forward.
    unreadable_paths: [][]const u8,
    documents: usize,
    terms: usize,
    postings: usize,
    /// S2-T5: superseded section files deleted by `caps.keep_generations`
    /// after this publish, and deletions that failed (the publish itself
    /// still succeeded). Both 0 when the option is off.
    pruned_files: usize = 0,
    prune_failures: usize = 0,
    /// Non-null when `INDEX-STATE.json` was discarded and every file
    /// re-indexed into a full generation: `"missing_section"` (S2-T5:
    /// `MANIFEST` named a section that could not be read) or
    /// `"missing_manifest"` (S2-T12: no `MANIFEST`, but a state file exists).
    recovered: ?[]const u8 = null,
};

/// Incremental folder indexing (S1-T3, `docs/incremental-indexing.md`):
/// re-walks `root` and applies the walk as one batch over the current
/// generation in `out_dir`. Every candidate file is read and hashed; a file
/// whose hash and chunker match its `INDEX-STATE.json` entry keeps its
/// chunks (re-tokenized from the previous postings, not re-chunked); a file
/// no longer in the walk is removed; an unreadable file, or one left over by
/// `caps.max_total_bytes`, keeps its previous chunks; a file over
/// `caps.max_file_bytes` loses them (`too_large`). A `MANIFEST` naming a lost
/// section, or a lost `MANIFEST` beside a state file, re-indexes every file
/// and says so in `recovered`. Fails closed (`error.AnalyzerMismatch`) on a
/// generation published with another analyzer. Publishes the next free
/// generation, then writes `INDEX-STATE.json`.
///
/// S3-T3: the walk builds an `apply_changes` batch (`apply.applyBatch`).
pub fn indexFolderIncremental(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    out_dir: std.Io.Dir,
    analyzer: AnalyzerId,
    max_chars: usize,
    overlap_lines: usize,
    caps: Caps,
) !IncrementalReport {
    return walkAndApply(allocator, io, root, out_dir, analyzer, max_chars, overlap_lines, caps, false, null);
}

test "indexFolder publishes a queryable generation from a real folder" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "note.md", .data = "search evidence combines lexical and semantic ranks\n" });
    try tmp.dir.createDir(io, "out", .default_dir);
    var out_dir = try tmp.dir.openDir(io, "out", .{});
    defer out_dir.close(io);

    const report = try indexFolder(arena, io, tmp.dir, out_dir, .v2, 1, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    try std.testing.expectEqual(@as(usize, 1), report.added);
    try std.testing.expect(report.documents >= 1);
    try std.testing.expectEqualStrings("analyzer-v2", report.analyzer_id);
}

test "indexFolder publishes an empty generation for an empty folder instead of NoDocuments" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.createDir(io, "root", .default_dir);
    var root = try tmp.dir.openDir(io, "root", .{ .iterate = true });
    defer root.close(io);
    try tmp.dir.createDir(io, "out", .default_dir);
    var out_dir = try tmp.dir.openDir(io, "out", .{});
    defer out_dir.close(io);

    const report = try indexFolder(arena, io, root, out_dir, .v2, 1, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    try std.testing.expectEqual(@as(usize, 0), report.added);
    try std.testing.expectEqual(@as(usize, 0), report.documents);
    try std.testing.expectEqual(@as(usize, 0), report.terms);
    try std.testing.expectEqual(@as(usize, 0), report.postings);
    try std.testing.expectEqual(@as(usize, 0), report.unreadable_paths.len);

    // The empty generation is durably published and queryable (0 results,
    // never an open failure).
    const opened = try snapshot_open.open(arena, io, out_dir);
    try std.testing.expectEqual(@as(u64, 1), opened.generation);
    try std.testing.expectEqual(@as(usize, 0), opened.documents.len);
}

test "indexFolder lists the paths of files it could not read" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "good.md", .data = "search evidence combines lexical and semantic ranks\n" });
    // Invalid UTF-8 -- rejected the same way a genuinely unreadable file is.
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.md", .data = &[_]u8{ 0xff, 0xfe, 0x00 } });
    try tmp.dir.createDir(io, "out", .default_dir);
    var out_dir = try tmp.dir.openDir(io, "out", .{});
    defer out_dir.close(io);

    const report = try indexFolder(arena, io, tmp.dir, out_dir, .v2, 1, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    try std.testing.expectEqual(@as(usize, 1), report.added);
    try std.testing.expectEqual(@as(usize, 1), report.unreadable);
    try std.testing.expectEqual(@as(usize, 1), report.unreadable_paths.len);
    try std.testing.expectEqualStrings("bad.md", report.unreadable_paths[0]);
}

test "hasAllowedExtension matches DEFAULT_EXTENSIONS case-insensitively" {
    try std.testing.expect(hasAllowedExtension("README.MD"));
    try std.testing.expect(hasAllowedExtension("main.zig"));
    try std.testing.expect(!hasAllowedExtension("image.png"));
    try std.testing.expect(!hasAllowedExtension("noext"));
}

test "isIgnoredPath skips dotfiles and ignored directories" {
    try std.testing.expect(isIgnoredPath(".git/config"));
    try std.testing.expect(isIgnoredPath("node_modules/pkg/index.js"));
    try std.testing.expect(isIgnoredPath("src/.hidden.md"));
    try std.testing.expect(!isIgnoredPath("src/main.md"));
}

test "indexFolder applies max_file_bytes cap on a full rebuild (S1-T5 criterion 1)" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    // A 41-byte file with a 10-byte cap should be reported too_large and
    // not indexed -- S1-T5 criterion 1 example.
    try tmp.dir.writeFile(io, .{ .sub_path = "oversized.md", .data = "123456789\n123456789\n123456789\n123456789\na" });
    try tmp.dir.createDir(io, "out", .default_dir);
    var out_dir = try tmp.dir.openDir(io, "out", .{});
    defer out_dir.close(io);

    const caps = Caps{ .max_file_bytes = 10 };
    const report = try indexFolder(arena, io, tmp.dir, out_dir, .v2, 1, chunker.default_max_chars, chunker.default_overlap_lines, caps);
    try std.testing.expectEqual(@as(usize, 0), report.added);
    try std.testing.expectEqual(@as(usize, 1), report.too_large);
    try std.testing.expectEqual(@as(usize, 1), report.too_large_paths.len);
    try std.testing.expectEqualStrings("oversized.md", report.too_large_paths[0]);
    try std.testing.expectEqual(@as(usize, 0), report.documents);

    // The generation is published but empty (0 documents), and queryable.
    const opened = try snapshot_open.open(arena, io, out_dir);
    try std.testing.expectEqual(@as(u64, 1), opened.generation);
    try std.testing.expectEqual(@as(usize, 0), opened.documents.len);
}

test "indexFolder applies max_total_bytes cap on a full rebuild (S1-T5 criterion 1 rework)" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    // Three ~41-byte files and a 50-byte budget: only the first (sorted by
    // path) fits, the other two are left out and counted budget_exhausted --
    // same fixture shape the round-D tester's own rejection probe used.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.md", .data = "123456789\n123456789\n123456789\n123456789\na" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.md", .data = "123456789\n123456789\n123456789\n123456789\na" });
    try tmp.dir.writeFile(io, .{ .sub_path = "c.md", .data = "123456789\n123456789\n123456789\n123456789\na" });
    try tmp.dir.createDir(io, "out", .default_dir);
    var out_dir = try tmp.dir.openDir(io, "out", .{});
    defer out_dir.close(io);

    const caps = Caps{ .max_total_bytes = 50 };
    const report = try indexFolder(arena, io, tmp.dir, out_dir, .v2, 1, chunker.default_max_chars, chunker.default_overlap_lines, caps);
    try std.testing.expectEqual(@as(usize, 1), report.added);
    try std.testing.expectEqual(@as(usize, 2), report.budget_exhausted);
    try std.testing.expectEqual(@as(usize, 0), report.too_large);
    try std.testing.expectEqual(@as(usize, 1), report.documents);

    // Only the processed file's state entry is persisted -- the two left
    // over by the budget are eligible again on the next run, exactly like
    // `indexFolderIncremental`'s budget_exhausted files.
    const state = try incremental_state.load(arena, io, out_dir);
    try std.testing.expect(state != null);
    if (state) |s| try std.testing.expectEqual(@as(usize, 1), s.files.len);
}

test "full rebuild writes INDEX-STATE.json, first --update reports unchanged (S1-T5 criterion 2)" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    // `root` and `out_dir` are siblings, not nested (an --out directory
    // living inside the folder it indexes would see its own INDEX-STATE.json
    // as a candidate .json file to index -- a hazard for a real caller who
    // nests them, not something this test should also fall into).
    try tmp.dir.createDir(io, "notes", .default_dir);
    var root = try tmp.dir.openDir(io, "notes", .{ .iterate = true });
    defer root.close(io);
    try root.writeFile(io, .{ .sub_path = "note.md", .data = "hybrid ranking combines lexical and semantic evidence\n" });
    try tmp.dir.createDir(io, "out", .default_dir);
    var out_dir = try tmp.dir.openDir(io, "out", .{});
    defer out_dir.close(io);

    // Full rebuild (generation 1).
    const report1 = try indexFolder(arena, io, root, out_dir, .v2, 1, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    try std.testing.expectEqual(@as(usize, 1), report1.added);
    try std.testing.expectEqual(@as(usize, 1), report1.documents);

    // Verify that INDEX-STATE.json was written with the correct state.
    const state = try incremental_state.load(arena, io, out_dir);
    try std.testing.expect(state != null);
    if (state) |s| {
        try std.testing.expectEqual(@as(usize, 1), s.files.len);
        try std.testing.expectEqualStrings("note.md", s.files[0].path);
    }

    // The criterion's own wording ("first --update reports unchanged"): run
    // an actual --update (indexFolderIncremental) against the same
    // directory and check it reports the file unchanged, not added --
    // round-D's test never ran this part despite its name claiming to
    // (round-D tester's Verdict, criterion 2).
    const report2 = try indexFolderIncremental(arena, io, root, out_dir, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    try std.testing.expectEqual(@as(usize, 0), report2.added);
    try std.testing.expectEqual(@as(usize, 1), report2.unchanged);
    try std.testing.expectEqual(@as(u64, 2), report2.generation);
}

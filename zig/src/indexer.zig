//! Native folder indexing (S1-T1 acceptance criterion 3): walks a folder,
//! chunks UTF-8 text/markdown/source files with `chunker.zig`
//! (`line-window-v1`), tokenizes with the selected analyzer, builds a
//! lexical-only (no embeddings) index, and publishes it through the
//! existing `segment`/`lexical_segment`/`manifest`/`lifecycle` machinery --
//! no Python involved. Extension list and ignored-directory set mirror
//! `search_platform.core.DEFAULT_EXTENSIONS`/`IGNORED_DIRECTORIES` exactly,
//! so the same folder produces the same candidate file set as the Python
//! reference.
const std = @import("std");
const analysis = @import("analysis.zig");
const analyzer_v2 = @import("analyzer_v2.zig");
const chunker = @import("chunker.zig");
const hybrid = @import("hybrid.zig");
const lexical_build = @import("lexical_build.zig");
const lexical_segment = @import("lexical_segment.zig");
const lifecycle = @import("lifecycle.zig");
const manifest = @import("manifest.zig");
const segment = @import("segment.zig");

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

/// Walk `root`, chunk and tokenize every matching file, and publish a fresh
/// generation into `out_dir`. `allocator` is expected to be an arena: every
/// document, token list, and encoded buffer this function produces is freed
/// together when the caller tears the arena down.
pub fn indexFolder(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    out_dir: std.Io.Dir,
    analyzer: AnalyzerId,
    generation: u64,
    max_chars: usize,
    overlap_lines: usize,
) !IndexReport {
    var paths = std.ArrayList([]const u8).empty;
    {
        var walker = try root.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (isIgnoredPath(entry.path)) continue;
            if (!hasAllowedExtension(entry.basename)) continue;
            try paths.append(allocator, try allocator.dupe(u8, entry.path));
        }
    }
    std.mem.sort([]const u8, paths.items, {}, lessThanPath);

    var documents = std.ArrayList(hybrid.Document).empty;
    var files_skipped: usize = 0;

    for (paths.items) |relative_path| {
        const stat = root.statFile(io, relative_path, .{}) catch {
            files_skipped += 1;
            continue;
        };
        const size = std.math.cast(usize, stat.size) orelse {
            files_skipped += 1;
            continue;
        };
        const buffer = try allocator.alloc(u8, size);
        const content = root.readFile(io, relative_path, buffer) catch {
            files_skipped += 1;
            continue;
        };
        if (!std.unicode.utf8ValidateSlice(content)) {
            files_skipped += 1;
            continue;
        }

        const spans = chunker.chunk(allocator, content, max_chars, overlap_lines) catch {
            files_skipped += 1;
            continue;
        };
        for (spans) |span| {
            var id_hex: [20]u8 = undefined;
            chunker.chunkId(&id_hex, relative_path, span.start_line, span.end_line, span.text);
            const owned_id = try allocator.dupe(u8, &id_hex);
            try documents.append(allocator, .{
                .id = owned_id,
                .text = span.text,
                .vector = &.{},
                .path = relative_path,
                .start_line = span.start_line,
                .end_line = span.end_line,
            });
        }
    }

    if (documents.items.len == 0) return error.NoDocuments;

    var token_lists = try allocator.alloc([][]const u8, documents.items.len);
    for (documents.items, 0..) |document, i| {
        token_lists[i] = try tokenize(allocator, analyzer, document.text);
    }

    const lexical_index = try lexical_build.build(allocator, documents.items, token_lists);

    const documents_encoded_len = try segment.encodedLength(documents.items);
    const documents_buffer = try allocator.alloc(u8, documents_encoded_len);
    const documents_encoded = try segment.encode(documents.items, documents_buffer);

    const lexical_encoded_len = try lexical_segment.encodedLength(lexical_index);
    const lexical_buffer = try allocator.alloc(u8, lexical_encoded_len);
    const lexical_encoded = try lexical_segment.encode(lexical_index, lexical_buffer);

    const documents_file = try std.fmt.allocPrint(allocator, "documents-{d}.hybseg", .{generation});
    const lexical_file = try std.fmt.allocPrint(allocator, "lexical-{d}.hyblex", .{generation});

    const metadata = try manifest.create(
        generation,
        analyzer.label(),
        "none",
        documents_file,
        lexical_file,
        documents_encoded,
        lexical_encoded,
    );
    const manifest_len = try manifest.encodedLength(metadata);
    const manifest_buffer = try allocator.alloc(u8, manifest_len);
    const manifest_encoded = try manifest.encode(metadata, manifest_buffer);

    try lifecycle.publishSerialized(out_dir, io, manifest_encoded, documents_encoded, lexical_encoded);

    return .{
        .generation = generation,
        .analyzer_id = analyzer.label(),
        .files_indexed = paths.items.len - files_skipped,
        .files_skipped = files_skipped,
        .documents = documents.items.len,
        .terms = lexical_index.terms.len,
        .postings = lexical_index.postings.len,
    };
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

    const report = try indexFolder(arena, io, tmp.dir, out_dir, .v2, 1, chunker.default_max_chars, chunker.default_overlap_lines);
    try std.testing.expectEqual(@as(usize, 1), report.files_indexed);
    try std.testing.expect(report.documents >= 1);
    try std.testing.expectEqualStrings("analyzer-v2", report.analyzer_id);
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

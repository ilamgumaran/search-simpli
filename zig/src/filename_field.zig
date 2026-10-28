const analyzer_v2 = @import("analyzer_v2.zig");
const hybrid = @import("hybrid.zig");
const lexical_build = @import("lexical_build.zig");
const lexical_segment = @import("lexical_segment.zig");
const postings = @import("postings.zig");
const segment = @import("segment.zig");
const scoring = @import("scoring.zig");
const std = @import("std");

pub const policy_id = "filename-field-v1";
pub const Field = enum { content, filename, both };
pub const Built = struct { catalog: []const u8, lexical: []const u8 };
pub const Hit = struct {
    document_index: usize,
    body_score: f32 = 0,
    body_rank: ?usize = null,
    filename_score: f32 = 0,
    filename_rank: ?usize = null,
    fused_score: f32 = 0,
};

const Candidate = struct { path: []const u8, body_index: usize, score: f32 = 0, rank: ?usize = null, catalog_index: usize = 0 };

fn pathLess(_: void, a: hybrid.Document, b: hybrid.Document) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}
fn anchorLess(a: hybrid.Document, b: hybrid.Document) bool {
    if (a.start_line != b.start_line) return a.start_line < b.start_line;
    if (a.end_line != b.end_line) return a.end_line < b.end_line;
    return std.mem.order(u8, a.id, b.id) == .lt;
}
fn basename(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
}
fn stem(path: []const u8) []const u8 {
    const name = basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return name[0..dot];
}
fn validPath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfAny(u8, path, "\x00\r\n") != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    return std.unicode.utf8ValidateSlice(path);
}
fn labelsAllowed(labels: []const u8, required: []const []const u8) bool {
    if (labels.len == 0) return true;
    var it = std.mem.splitScalar(u8, labels, '\n');
    while (it.next()) |label| {
        var found = false;
        for (required) |candidate| if (std.mem.eql(u8, label, candidate)) {
            found = true;
            break;
        };
        if (!found) return false;
    }
    return true;
}
fn inScope(document: hybrid.Document, options: hybrid.SearchOptions) bool {
    if (options.path_prefix) |prefix| {
        if (!std.mem.startsWith(u8, document.path, prefix)) return false;
    }
    return labelsAllowed(document.required_labels, options.principal_labels);
}
pub fn tokenize(allocator: std.mem.Allocator, analyzer_id: []const u8, text: []const u8) ![][]const u8 {
    if (std.mem.eql(u8, analyzer_id, analyzer_v2.analyzer_id)) return analyzer_v2.tokenize(allocator, text);
    var list = std.ArrayList([]const u8).empty;
    var it = @import("analysis.zig").TokenIterator.init(text);
    while (it.next()) |token| {
        const out = try allocator.dupe(u8, token.bytes);
        for (out) |*c| c.* = std.ascii.toLower(c.*);
        try list.append(allocator, out);
    }
    return list.toOwnedSlice(allocator);
}

fn buildDecoded(allocator: std.mem.Allocator, documents: []const hybrid.Document, analyzer_id: []const u8) !struct { catalog: []hybrid.Document, lexical: postings.Index } {
    const sorted = try allocator.dupe(hybrid.Document, documents);
    std.mem.sort(hybrid.Document, sorted, {}, pathLess);
    var catalog = std.ArrayList(hybrid.Document).empty;
    var i: usize = 0;
    while (i < sorted.len) {
        const start = i;
        const path = sorted[i].path;
        if (!validPath(path)) return error.InvalidFilenamePath;
        var anchor = sorted[i];
        while (i < sorted.len and std.mem.eql(u8, sorted[i].path, path)) : (i += 1) {
            if (!std.mem.eql(u8, sorted[start].required_labels, sorted[i].required_labels)) return error.InconsistentLabels;
            if (anchorLess(sorted[i], anchor)) anchor = sorted[i];
        }
        try catalog.append(allocator, .{ .id = anchor.id, .path = path, .text = try allocator.dupe(u8, stem(path)), .vector = &.{}, .start_line = anchor.start_line, .end_line = anchor.end_line, .required_labels = anchor.required_labels });
    }
    const docs = try catalog.toOwnedSlice(allocator);
    const token_lists = try allocator.alloc([][]const u8, docs.len);
    for (docs, 0..) |doc, j| token_lists[j] = try tokenize(allocator, analyzer_id, doc.text);
    return .{ .catalog = docs, .lexical = try lexical_build.build(allocator, docs, token_lists) };
}

pub fn build(allocator: std.mem.Allocator, documents: []const hybrid.Document, analyzer_id: []const u8) !Built {
    const decoded = try buildDecoded(allocator, documents, analyzer_id);
    const catalog_len = try segment.encodedLength(decoded.catalog);
    const catalog_buffer = try allocator.alloc(u8, catalog_len);
    const catalog = try segment.encode(decoded.catalog, catalog_buffer);
    const lexical_len = try lexical_segment.encodedLength(decoded.lexical);
    const lexical_buffer = try allocator.alloc(u8, lexical_len);
    const lexical = try lexical_segment.encode(decoded.lexical, lexical_buffer);
    return .{ .catalog = catalog, .lexical = lexical };
}

pub fn validate(allocator: std.mem.Allocator, body_documents: []const hybrid.Document, catalog_encoded: []const u8, lexical_encoded: []const u8, analyzer_id: []const u8) !void {
    const expected = try buildDecoded(allocator, body_documents, analyzer_id);
    const ch = try segment.inspect(catalog_encoded);
    const catalog_storage = try allocator.alloc(hybrid.Document, ch.document_count);
    const catalog = try segment.decode(catalog_encoded, catalog_storage, &.{});
    const lh = try lexical_segment.inspect(lexical_encoded);
    const lex_terms = try allocator.alloc(postings.TermEntry, lh.term_count);
    const lex_posts = try allocator.alloc(postings.Posting, lh.posting_count);
    const lex_lengths = try allocator.alloc(u32, lh.document_count);
    const lexical = try lexical_segment.decode(lexical_encoded, lex_terms, lex_posts, lex_lengths);
    if (expected.catalog.len != catalog.len or lexical.document_lengths.len != catalog.len) return error.FilenameCatalogMismatch;
    for (catalog, expected.catalog) |actual, want| {
        if (!validPath(actual.path) or actual.vector.len != 0 or !std.mem.eql(u8, actual.path, want.path) or !std.mem.eql(u8, actual.id, want.id) or !std.mem.eql(u8, actual.text, want.text) or actual.start_line != want.start_line or actual.end_line != want.end_line or !std.mem.eql(u8, actual.required_labels, want.required_labels)) return error.FilenameCatalogMismatch;
    }
    if (lexical.postings.len != expected.lexical.postings.len or lexical.terms.len != expected.lexical.terms.len) return error.FilenameLexicalMismatch;
    if (lexical.average_document_length != expected.lexical.average_document_length) return error.FilenameLexicalMismatch;
    for (lexical.document_lengths, expected.lexical.document_lengths) |a, b| if (a != b) return error.FilenameLexicalMismatch;
    for (lexical.terms, expected.lexical.terms) |a, b| if (!std.mem.eql(u8, a.term, b.term) or a.document_frequency != b.document_frequency or a.postings_length != b.postings_length or a.postings_start != b.postings_start) return error.FilenameLexicalMismatch;
    for (lexical.postings, expected.lexical.postings) |a, b| if (a.document_index != b.document_index or a.term_frequency != b.term_frequency) return error.FilenameLexicalMismatch;
}

fn termIndex(index: postings.Index, term: []const u8) ?usize {
    for (index.terms, 0..) |entry, i| if (std.mem.eql(u8, entry.term, term)) return i;
    return null;
}
fn lessCandidate(a: Candidate, b: Candidate, docs: []const hybrid.Document) bool {
    if (a.score != b.score) return a.score > b.score;
    const order = std.mem.order(u8, a.path, b.path);
    if (order != .eq) return order == .lt;
    return std.mem.order(u8, docs[a.body_index].id, docs[b.body_index].id) == .lt;
}
fn sortCandidates(items: []Candidate, docs: []const hybrid.Document) void {
    std.mem.sort(Candidate, items, docs, struct {
        fn less(d: []const hybrid.Document, a: Candidate, b: Candidate) bool {
            return lessCandidate(a, b, d);
        }
    }.less);
}
pub fn query(allocator: std.mem.Allocator, body_docs: []const hybrid.Document, body_index: postings.Index, catalog_encoded: []const u8, lexical_encoded: []const u8, analyzer_id: []const u8, query_text: []const u8, field: Field, options: hybrid.SearchOptions) ![]Hit {
    if (field == .content) return error.ContentQueryUseLegacy;
    if (options.retrieval_mode != .lexical) return error.InvalidRetrievalMode;
    if (options.candidate_k < options.top_k) return error.CandidateDepthTooSmall;
    const ch = try segment.inspect(catalog_encoded);
    const catalog_storage = try allocator.alloc(hybrid.Document, ch.document_count);
    const catalog = try segment.decode(catalog_encoded, catalog_storage, &.{});
    const lh = try lexical_segment.inspect(lexical_encoded);
    const lex_terms = try allocator.alloc(postings.TermEntry, lh.term_count);
    const lex_posts = try allocator.alloc(postings.Posting, lh.posting_count);
    const lex_lengths = try allocator.alloc(u32, lh.document_count);
    const lexical = try lexical_segment.decode(lexical_encoded, lex_terms, lex_posts, lex_lengths);
    const qt = try tokenize(allocator, analyzer_id, query_text);
    var filename = try allocator.alloc(Candidate, catalog.len);
    var fn_count: usize = 0;
    for (catalog, 0..) |doc, i| if (inScope(doc, options)) {
        filename[fn_count] = .{ .path = doc.path, .body_index = findAnchor(body_docs, doc) orelse return error.FilenameAnchorNotFound, .score = 0, .catalog_index = i };
        fn_count += 1;
    };
    const body_visible = try allocator.alloc(bool, body_docs.len);
    var visible_count: usize = 0;
    var total_len: usize = 0;
    for (body_docs, 0..) |doc, i| {
        body_visible[i] = inScope(doc, options);
        if (body_visible[i]) {
            visible_count += 1;
            total_len += body_index.document_lengths[i];
        }
    }
    const avg = if (visible_count == 0) 0 else @as(f32, @floatFromInt(total_len)) / @as(f32, @floatFromInt(visible_count));
    var body_scores = try allocator.alloc(f32, body_docs.len);
    @memset(body_scores, 0);
    var fname_scores = try allocator.alloc(f32, catalog.len);
    @memset(fname_scores, 0);
    for (qt, 0..) |term, qi| {
        var repeated = false;
        for (qt[0..qi]) |previous| if (std.mem.eql(u8, previous, term)) {
            repeated = true;
            break;
        };
        if (repeated) continue;
        if (termIndex(lexical, term)) |ti| {
            const ent = lexical.terms[ti];
            var df: u32 = 0;
            for (lexical.postings[ent.postings_start .. ent.postings_start + ent.postings_length]) |p| if (inScope(catalog[p.document_index], options)) {
                df += 1;
            };
            for (lexical.postings[ent.postings_start .. ent.postings_start + ent.postings_length]) |p| if (inScope(catalog[p.document_index], options)) {
                fname_scores[p.document_index] += scoring.bm25Contribution(@floatFromInt(p.term_frequency), @floatFromInt(lexical.document_lengths[p.document_index]), scopedAvg(lexical, catalog, options), df, @intCast(fn_count), options.bm25);
            };
        }
        if (termIndex(body_index, term)) |ti| {
            const ent = body_index.terms[ti];
            var df: u32 = 0;
            for (body_index.postings[ent.postings_start .. ent.postings_start + ent.postings_length]) |p| if (body_visible[p.document_index]) {
                df += 1;
            };
            for (body_index.postings[ent.postings_start .. ent.postings_start + ent.postings_length]) |p| if (body_visible[p.document_index]) {
                body_scores[p.document_index] += scoring.bm25Contribution(@floatFromInt(p.term_frequency), @floatFromInt(body_index.document_lengths[p.document_index]), avg, df, @intCast(visible_count), options.bm25);
            };
        }
    }
    var positive_count: usize = 0;
    for (filename[0..fn_count]) |c| {
        const score = fname_scores[c.catalog_index];
        if (score <= 0) continue;
        filename[positive_count] = c;
        filename[positive_count].score = score;
        positive_count += 1;
    }
    fn_count = positive_count;
    sortCandidates(filename[0..fn_count], body_docs);
    var body = std.ArrayList(Candidate).empty;
    if (field == .both) {
        for (body_docs, body_scores, 0..) |doc, score, bi| if (score > 0 and body_visible[bi]) {
            const found = blk: {
                for (body.items, 0..) |*x, ix| if (std.mem.eql(u8, x.path, doc.path)) break :blk ix;
                break :blk null;
            };
            if (found) |ix| {
                if (score > body.items[ix].score or (score == body.items[ix].score and std.mem.order(u8, doc.id, body_docs[body.items[ix].body_index].id) == .lt)) body.items[ix] = .{ .path = doc.path, .body_index = bi, .score = score };
            } else try body.append(allocator, .{ .path = doc.path, .body_index = bi, .score = score });
        };
        sortCandidates(body.items, body_docs);
    }
    const fn_limit = @min(fn_count, options.candidate_k);
    const body_limit = @min(body.items.len, options.candidate_k);
    var out = std.ArrayList(Hit).empty;
    if (field == .filename) {
        for (filename[0..fn_limit], 0..) |c, rank| if (c.score > 0 and out.items.len < options.top_k) try out.append(allocator, .{ .document_index = c.body_index, .filename_score = c.score, .filename_rank = rank + 1, .fused_score = c.score });
    } else {
        for (body.items[0..body_limit], 0..) |c, rank| try mergeHit(allocator, &out, body_docs, c, true, rank + 1, 60);
        for (filename[0..fn_limit], 0..) |c, rank| if (c.score > 0) try mergeHit(allocator, &out, body_docs, c, false, rank + 1, 60);
        std.mem.sort(Hit, out.items, body_docs, hitLess);
        out.items = out.items[0..@min(out.items.len, options.top_k)];
    }
    return out.toOwnedSlice(allocator);
}
fn scopedAvg(index: postings.Index, docs: []const hybrid.Document, options: hybrid.SearchOptions) f32 {
    var n: usize = 0;
    var total: usize = 0;
    for (docs, 0..) |doc, i| if (inScope(doc, options)) {
        n += 1;
        total += index.document_lengths[i];
    };
    return if (n == 0) 0 else @as(f32, @floatFromInt(total)) / @as(f32, @floatFromInt(n));
}
fn findAnchor(body: []const hybrid.Document, catalog_doc: hybrid.Document) ?usize {
    for (body, 0..) |d, i| if (std.mem.eql(u8, d.id, catalog_doc.id) and std.mem.eql(u8, d.path, catalog_doc.path)) return i;
    return null;
}
fn mergeHit(a: std.mem.Allocator, out: *std.ArrayList(Hit), docs: []const hybrid.Document, c: Candidate, is_body: bool, rank: usize, k: f32) !void {
    for (out.items) |*h| if (std.mem.eql(u8, docs[h.document_index].path, c.path)) {
        if (is_body) {
            h.body_rank = rank;
            h.body_score = c.score;
            h.fused_score += 1 / (k + @as(f32, @floatFromInt(rank)));
        } else {
            h.filename_rank = rank;
            h.filename_score = c.score;
            h.fused_score += 1 / (k + @as(f32, @floatFromInt(rank)));
        }
        return;
    };
    try out.append(a, .{ .document_index = c.body_index, .body_score = if (is_body) c.score else 0, .body_rank = if (is_body) rank else null, .filename_score = if (is_body) 0 else c.score, .filename_rank = if (is_body) null else rank, .fused_score = 1 / (k + @as(f32, @floatFromInt(rank))) });
}
fn hitLess(docs: []const hybrid.Document, a: Hit, b: Hit) bool {
    if (a.fused_score != b.fused_score) return a.fused_score > b.fused_score;
    const x = std.mem.order(u8, docs[a.document_index].path, docs[b.document_index].path);
    if (x != .eq) return x == .lt;
    return std.mem.order(u8, docs[a.document_index].id, docs[b.document_index].id) == .lt;
}

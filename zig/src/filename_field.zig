const analyzer_v2 = @import("analyzer_v2.zig");
const hybrid = @import("hybrid.zig");
const lexical_build = @import("lexical_build.zig");
const lexical_segment = @import("lexical_segment.zig");
const manifest = @import("manifest.zig");
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
fn inScope(document: hybrid.Document, index: usize, options: hybrid.SearchOptions) bool {
    return hybrid.inScope(document, index, options);
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
    const empty = postings.Index{ .terms = &.{}, .postings = &.{}, .document_lengths = &.{}, .average_document_length = 0 };
    const decoded = try decode(allocator, body_documents, empty, catalog_encoded, lexical_encoded);
    try validateDecoded(allocator, decoded, analyzer_id);
}

/// Verify the canonical postings one file at a time, without rebuilding a
/// second complete catalog/index. The decoder already checked real anchors.
pub fn validateDecoded(allocator: std.mem.Allocator, decoded: Decoded, analyzer_id: []const u8) !void {
    const lexical = decoded.lexical;
    const seen = try allocator.alloc(bool, lexical.terms.len);
    @memset(seen, false);
    const frequencies = try allocator.alloc(u32, lexical.terms.len);
    @memset(frequencies, 0);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var next_term: usize = 0;
    var total_length: usize = 0;
    var posting_start: usize = 0;
    for (lexical.terms) |term| {
        if (term.postings_start != posting_start) return error.FilenameLexicalMismatch;
        posting_start += term.postings_length;
    }
    if (posting_start != lexical.postings.len) return error.FilenameLexicalMismatch;
    for (decoded.catalog, 0..) |doc, i| {
        _ = scratch.reset(.retain_capacity);
        const a = scratch.allocator();
        const tokens = try tokenize(a, analyzer_id, doc.text);
        if (tokens.len != lexical.document_lengths[i]) return error.FilenameLexicalMismatch;
        total_length += tokens.len;
        // Same canonical first-seen dictionary order as lexical_build.build.
        var counts = std.StringHashMap(u32).init(a);
        for (tokens) |token| {
            const slot = try counts.getOrPut(token);
            if (!slot.found_existing) slot.value_ptr.* = 0;
            slot.value_ptr.* += 1;
        }
        var it = counts.iterator();
        while (it.next()) |entry| {
            const ti = decoded.filenameTerm(entry.key_ptr.*) orelse return error.FilenameLexicalMismatch;
            if (!seen[ti]) {
                if (ti != next_term) return error.FilenameLexicalMismatch;
                next_term += 1;
                seen[ti] = true;
            }
            frequencies[ti] += 1;
            const term = lexical.terms[ti];
            const list = lexical.postings[term.postings_start .. term.postings_start + term.postings_length];
            var low: usize = 0;
            var high = list.len;
            while (low < high) {
                const mid = low + (high - low) / 2;
                if (list[mid].document_index < i) low = mid + 1 else high = mid;
            }
            if (low == list.len or list[low].document_index != i or list[low].term_frequency != entry.value_ptr.*) return error.FilenameLexicalMismatch;
        }
    }
    if (next_term != lexical.terms.len) return error.FilenameLexicalMismatch;
    for (lexical.terms, frequencies) |term, expected| if (term.document_frequency != expected) return error.FilenameLexicalMismatch;
    const avg: f32 = if (decoded.catalog.len == 0) 0 else @as(f32, @floatFromInt(total_length)) / @as(f32, @floatFromInt(decoded.catalog.len));
    if (avg != lexical.average_document_length) return error.FilenameLexicalMismatch;
}

fn catalogIndex(catalog: []const hybrid.Document, path: []const u8) ?usize {
    var low: usize = 0;
    var high = catalog.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, catalog[mid].path, path)) {
            .eq => return mid,
            .lt => low = mid + 1,
            .gt => high = mid,
        }
    }
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
pub const Decoded = struct {
    catalog: []const hybrid.Document,
    lexical: postings.Index,
    anchors: []const usize,
    /// The filename dictionary's indices in byte order of their terms (the
    /// dictionary itself is in first-seen order, `lexical_build`), for a
    /// binary-search lookup. The body dictionary is looked up in place
    /// (`postings.lookupExact`), not copied.
    term_order: []const u32,

    pub fn filenameTerm(decoded: Decoded, term: []const u8) ?usize {
        const terms = decoded.lexical.terms;
        var low: usize = 0;
        var high = decoded.term_order.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            switch (std.mem.order(u8, terms[decoded.term_order[middle]].term, term)) {
                .eq => return decoded.term_order[middle],
                .lt => low = middle + 1,
                .gt => high = middle,
            }
        }
        return null;
    }
};

/// The bytes `load` needs for `metadata`'s filename sections: both encoded
/// sections and every decoded table, with alignment slack. The open
/// reserves them (not reads them) in its one section slab, as PR #21 did
/// for the source section, so the first filename query never grows the
/// handle's arena by another geometric step (S4-T2 R4).
pub fn loadReservation(metadata: manifest.Manifest) usize {
    const f = metadata.filename orelse return 0;
    const slack = 64;
    var total: usize = f.catalog_bytes + f.lexical_bytes + 6 * slack;
    total += f.file_count * (@sizeOf(hybrid.Document) + @sizeOf(u32) + @sizeOf(usize));
    total += f.term_count * (@sizeOf(postings.TermEntry) + @sizeOf(u32));
    total += f.posting_count * @sizeOf(postings.Posting);
    return total;
}
pub fn decode(allocator: std.mem.Allocator, body_docs: []const hybrid.Document, body_index: postings.Index, catalog_encoded: []const u8, lexical_encoded: []const u8) !Decoded {
    _ = body_index;
    return decodeInspected(allocator, body_docs, catalog_encoded, try segment.inspect(catalog_encoded), lexical_encoded, try lexical_segment.inspect(lexical_encoded));
}

/// `decode` with both headers already inspected (each checksum computed
/// once, by `load`).
fn decodeInspected(allocator: std.mem.Allocator, body_docs: []const hybrid.Document, catalog_encoded: []const u8, ch: segment.Header, lexical_encoded: []const u8, lh: lexical_segment.Header) !Decoded {
    const catalog_storage = try allocator.alloc(hybrid.Document, ch.document_count);
    const catalog = try segment.decodeInspected(catalog_encoded, ch, catalog_storage, &.{});
    const lex_terms = try allocator.alloc(postings.TermEntry, lh.term_count);
    const lex_posts = try allocator.alloc(postings.Posting, lh.posting_count);
    const lex_lengths = try allocator.alloc(u32, lh.document_count);
    const lexical = try lexical_segment.decodeWith(lexical_encoded, lex_terms, lex_posts, lex_lengths, .{ .inspected = lh });
    if (lexical.document_lengths.len != catalog.len) return error.FilenameCatalogMismatch;
    for (catalog, 0..) |doc, i| {
        if (!validPath(doc.path) or doc.vector.len != 0 or !std.mem.eql(u8, doc.text, stem(doc.path))) return error.FilenameCatalogMismatch;
        if (i > 0 and std.mem.order(u8, catalog[i - 1].path, doc.path) != .lt) return error.FilenameCatalogMismatch;
    }
    const anchors = try allocator.alloc(usize, catalog.len);
    @memset(anchors, std.math.maxInt(usize));
    for (body_docs, 0..) |doc, i| {
        const ci = catalogIndex(catalog, doc.path) orelse return error.FilenameCatalogMismatch;
        if (!std.mem.eql(u8, doc.required_labels, catalog[ci].required_labels)) return error.FilenameCatalogMismatch;
        if (anchors[ci] == std.math.maxInt(usize) or anchorLess(doc, body_docs[anchors[ci]])) anchors[ci] = i;
    }
    for (catalog, anchors) |doc, anchor| {
        if (anchor == std.math.maxInt(usize)) return error.FilenameAnchorNotFound;
        const body = body_docs[anchor];
        if (!std.mem.eql(u8, doc.id, body.id) or doc.start_line != body.start_line or doc.end_line != body.end_line) return error.FilenameCatalogMismatch;
    }
    const term_order = try allocator.alloc(u32, lexical.terms.len);
    for (term_order, 0..) |*slot, i| slot.* = @intCast(i);
    std.mem.sort(u32, term_order, lexical.terms, struct {
        fn less(terms: []const postings.TermEntry, a: u32, b: u32) bool {
            return std.mem.order(u8, terms[a].term, terms[b].term) == .lt;
        }
    }.less);
    for (term_order[0..term_order.len -| 1], term_order[@min(1, term_order.len)..]) |a, b| {
        if (std.mem.eql(u8, lexical.terms[a].term, lexical.terms[b].term)) return error.FilenameLexicalMismatch;
    }
    return .{ .catalog = catalog, .lexical = lexical, .anchors = anchors, .term_order = term_order };
}
/// S4-T2 R4: read, check and decode the v2.2 filename sections `metadata`
/// binds, from the two files the open kept (not read) for them. The first
/// filename or both query of an opened generation calls this once
/// (`scope.Loads`); `ss_open` reads neither section. Checks, each section's
/// checksum computed once: the manifest's lengths, checksums and counts
/// (`manifest.validateFilenameSections`' rules), then the structural walk of
/// `decode` (paths unique and ordered, every catalog entry anchored to its
/// file's first body chunk with equal labels). The writer already
/// re-tokenized every name and checked the postings against them before it
/// published (`validate`), so a reader does not repeat that.
pub fn load(allocator: std.mem.Allocator, io: std.Io, catalog_file: std.Io.File, lexical_file: std.Io.File, metadata: manifest.Manifest, body_docs: []const hybrid.Document, body_index: postings.Index) !Decoded {
    const f = metadata.filename orelse return error.FilenameIndexUnavailable;
    if ((try catalog_file.stat(io)).size != f.catalog_bytes) return error.FilenameCatalogSizeMismatch;
    if ((try lexical_file.stat(io)).size != f.lexical_bytes) return error.FilenameLexicalSizeMismatch;
    const total = std.math.add(usize, f.catalog_bytes, f.lexical_bytes) catch return error.IndexTooLarge;
    const buffer = try allocator.alloc(u8, total);
    const catalog_encoded = buffer[0..f.catalog_bytes];
    const lexical_encoded = buffer[f.catalog_bytes..];
    if (try catalog_file.readPositionalAll(io, catalog_encoded, 0) != f.catalog_bytes) return error.FilenameCatalogSizeMismatch;
    if (try lexical_file.readPositionalAll(io, lexical_encoded, 0) != f.lexical_bytes) return error.FilenameLexicalSizeMismatch;
    const catalog = segment.inspect(catalog_encoded) catch |err| return switch (err) {
        error.ChecksumMismatch => error.FilenameCatalogChecksumMismatch,
        else => error.InvalidFilenameCatalog,
    };
    const lexical = lexical_segment.inspect(lexical_encoded) catch |err| return switch (err) {
        error.ChecksumMismatch => error.FilenameLexicalChecksumMismatch,
        else => error.InvalidFilenameLexicalSection,
    };
    if (!metadata.xxh3_sections and (catalog.checksum_kind != .fnv1a64 or lexical.checksum_kind != .fnv1a64)) return error.InvalidFilenameCatalog;
    if (catalog.checksum != f.catalog_checksum) return error.FilenameCatalogChecksumMismatch;
    if (lexical.checksum != f.lexical_checksum) return error.FilenameLexicalChecksumMismatch;
    if (catalog.document_count != f.file_count or lexical.document_count != f.file_count) return error.FilenameCountMismatch;
    if (catalog.vector_dimensions != 0) return error.InvalidFilenameCatalog;
    if (lexical.term_count != f.term_count) return error.FilenameTermCountMismatch;
    if (lexical.posting_count != f.posting_count) return error.FilenamePostingCountMismatch;
    _ = body_index;
    return decodeInspected(allocator, body_docs, catalog_encoded, catalog, lexical_encoded, lexical);
}

pub fn query(allocator: std.mem.Allocator, body_docs: []const hybrid.Document, body_index: postings.Index, catalog_encoded: []const u8, lexical_encoded: []const u8, analyzer_id: []const u8, query_text: []const u8, field: Field, options: hybrid.SearchOptions) ![]Hit {
    return queryDecoded(allocator, body_docs, body_index, try decode(allocator, body_docs, body_index, catalog_encoded, lexical_encoded), analyzer_id, query_text, field, options);
}
pub fn queryDecoded(allocator: std.mem.Allocator, body_docs: []const hybrid.Document, body_index: postings.Index, decoded: Decoded, analyzer_id: []const u8, query_text: []const u8, field: Field, options: hybrid.SearchOptions) ![]Hit {
    if (field == .content) return error.ContentQueryUseLegacy;
    if (options.retrieval_mode != .lexical) return error.InvalidRetrievalMode;
    if (options.candidate_k < options.top_k) return error.CandidateDepthTooSmall;
    const catalog = decoded.catalog;
    const lexical = decoded.lexical;
    const qt = try tokenize(allocator, analyzer_id, query_text);
    var filename = try allocator.alloc(Candidate, catalog.len);
    var fn_count: usize = 0;
    const filename_visible = try allocator.alloc(bool, catalog.len);
    var filename_total_len: usize = 0;
    for (catalog, 0..) |doc, i| {
        filename_visible[i] = inScope(doc, decoded.anchors[i], options);
        if (!filename_visible[i]) continue;
        filename_total_len += lexical.document_lengths[i];
        filename[fn_count] = .{ .path = doc.path, .body_index = decoded.anchors[i], .score = 0, .catalog_index = i };
        fn_count += 1;
    }
    const filename_avg = if (fn_count == 0) 0 else @as(f32, @floatFromInt(filename_total_len)) / @as(f32, @floatFromInt(fn_count));
    const body_visible = try allocator.alloc(bool, body_docs.len);
    var visible_count: usize = 0;
    var total_len: usize = 0;
    for (body_docs, 0..) |doc, i| {
        body_visible[i] = inScope(doc, i, options);
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
        if (decoded.filenameTerm(term)) |ti| {
            const ent = lexical.terms[ti];
            var df: u32 = 0;
            for (lexical.postings[ent.postings_start .. ent.postings_start + ent.postings_length]) |p| if (filename_visible[p.document_index]) {
                df += 1;
            };
            for (lexical.postings[ent.postings_start .. ent.postings_start + ent.postings_length]) |p| if (filename_visible[p.document_index]) {
                fname_scores[p.document_index] += scoring.bm25Contribution(@floatFromInt(p.term_frequency), @floatFromInt(lexical.document_lengths[p.document_index]), filename_avg, df, @intCast(fn_count), options.bm25);
            };
        }
        if (postings.lookupExact(body_index, term)) |ti| {
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
        var by_path: std.StringHashMapUnmanaged(usize) = .empty;
        defer by_path.deinit(allocator);
        for (body_docs, body_scores, 0..) |doc, score, bi| if (score > 0 and body_visible[bi]) {
            const slot = try by_path.getOrPut(allocator, doc.path);
            if (slot.found_existing) {
                const ix = slot.value_ptr.*;
                if (score > body.items[ix].score or (score == body.items[ix].score and std.mem.order(u8, doc.id, body_docs[body.items[ix].body_index].id) == .lt)) body.items[ix] = .{ .path = doc.path, .body_index = bi, .score = score };
            } else {
                slot.value_ptr.* = body.items.len;
                try body.append(allocator, .{ .path = doc.path, .body_index = bi, .score = score });
            }
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

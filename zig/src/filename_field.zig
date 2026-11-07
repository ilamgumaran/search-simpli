const analyzer_v2 = @import("analyzer_v2.zig");
const hybrid = @import("hybrid.zig");
const title_field = @import("title_field.zig");
const fuzzy = @import("fuzzy.zig");
const lexical_build = @import("lexical_build.zig");
const lexical_segment = @import("lexical_segment.zig");
const manifest = @import("manifest.zig");
const postings = @import("postings.zig");
const segment = @import("segment.zig");
const scoring = @import("scoring.zig");
const std = @import("std");

pub const policy_id = "filename-field-v1";
pub const Field = enum { content, filename, both };
pub const Built = struct {
    catalog: []const u8,
    lexical: []const u8,
    /// S4-T4 ruling 4: the structures the two sections were encoded from,
    /// for the writer's check (`validateBuilt`).
    decoded_catalog: []const hybrid.Document = &.{},
    decoded_lexical: ?postings.Index = null,
    /// S4-T13 ruling 4: set when `lexical` is the previous generation's
    /// filename lexical section, carried (`buildCarried`): its header and
    /// the previous manifest's values it was checked against.
    carried: ?CarriedLexical = null,
};

/// S4-T13 ruling 4: a previous generation's filename lexical section that
/// the next generation carries byte for byte, as `carryLexical` checked it.
pub const CarriedLexical = struct {
    header: lexical_segment.Header,
    /// The previous manifest's `FilenameMetadata` values.
    checksum: u64,
    file_count: usize,
    term_count: usize,
    posting_count: usize,
};
pub const Hit = struct {
    document_index: usize,
    body_score: f32 = 0,
    body_rank: ?usize = null,
    filename_score: f32 = 0,
    filename_rank: ?usize = null,
    fused_score: f32 = 0,
    /// S5-T2: the title part inside `fused_score` (the merge of `both`), or
    /// null when the file's title took no part.
    title_score: ?f32 = null,
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

/// The catalog of `documents`: one entry per path, in path order, anchored
/// to the file's first body chunk (`anchorLess`), with the file's labels
/// and its stem as text.
pub fn group(allocator: std.mem.Allocator, documents: []const hybrid.Document) ![]hybrid.Document {
    // S4-T4 ruling 4: a writer's documents already come in path order (its
    // files are sorted by record path, each file's chunks adjacent), so the
    // copy and the stable sort are skipped when they would change nothing.
    const sorted: []const hybrid.Document = if (std.sort.isSorted(hybrid.Document, documents, {}, pathLess)) documents else blk: {
        const copy = try allocator.dupe(hybrid.Document, documents);
        std.mem.sort(hybrid.Document, copy, {}, pathLess);
        break :blk copy;
    };
    // S4-T13 ruling 4: one exact allocation (a first pass counts the paths),
    // not a list grown as it fills.
    var files: usize = 0;
    for (sorted, 0..) |document, k| {
        if (k == 0 or !std.mem.eql(u8, sorted[k - 1].path, document.path)) files += 1;
    }
    var catalog = try std.ArrayList(hybrid.Document).initCapacity(allocator, files);
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
        // The stem is a slice of the path (the documents outlive the catalog).
        catalog.appendAssumeCapacity(.{ .id = anchor.id, .path = path, .text = stem(path), .vector = &.{}, .start_line = anchor.start_line, .end_line = anchor.end_line, .required_labels = anchor.required_labels });
    }
    return catalog.items;
}

/// `buildMarked` without marks.
pub const NoMarks = struct {
    pub fn mark(_: NoMarks, comptime _: []const u8) void {}
};

pub fn build(allocator: std.mem.Allocator, documents: []const hybrid.Document, analyzer_id: []const u8) !Built {
    return buildMarked(allocator, documents, analyzer_id, NoMarks{});
}

/// `build`, calling `marks.mark(name)` after each part (S4-T13 ruling 1,
/// the writer's stage profile): `grouping`, `tokenize`, `lexical_build`,
/// `encode_catalog`, `encode_lexical`.
pub fn buildMarked(allocator: std.mem.Allocator, documents: []const hybrid.Document, analyzer_id: []const u8, marks: anytype) !Built {
    const catalog_documents = try group(allocator, documents);
    marks.mark("grouping");
    return buildFromCatalog(allocator, catalog_documents, analyzer_id, marks);
}

/// S4-T13 ruling 4: whether `catalog` (this generation's `group`) lists the
/// same files as `previous_documents` (the previous generation's body
/// documents, the ones its catalog was built from and checked against):
/// the same paths in the same order, each with the same packed labels, every
/// file's chunks adjacent. The filename lexical section depends only on the
/// paths' stems (and the analyzer, which a writer never changes), so when
/// this holds the previous section is the one a full build would write. A
/// rename, an add, a remove or a file left with no chunk fails it.
pub fn samePaths(catalog: []const hybrid.Document, previous_documents: []const hybrid.Document) bool {
    var i: usize = 0;
    for (catalog) |entry| {
        if (i == previous_documents.len) return false;
        const first = previous_documents[i];
        if (!std.mem.eql(u8, first.path, entry.path) or !std.mem.eql(u8, first.required_labels, entry.required_labels)) return false;
        while (i < previous_documents.len and std.mem.eql(u8, previous_documents[i].path, entry.path)) i += 1;
    }
    return i == previous_documents.len;
}

/// S4-T13 ruling 4: the previous generation's filename lexical section
/// `bytes`, checked for carrying against the previous manifest's `metadata`
/// and this generation's catalog length: its size, its checksum (computed
/// once here, against its header's value, which must equal the manifest's),
/// `HYBLEX01` with the checksum kind the encoder writes for it, its file,
/// term and posting counts. Null when any check fails: then the full build
/// runs, as it did before this task (a writer never read these sections), so
/// a damaged previous section is rebuilt, never refused.
pub fn carryLexical(bytes: []const u8, metadata: manifest.FilenameMetadata, catalog_len: usize) ?CarriedLexical {
    if (!std.mem.eql(u8, metadata.policy_id, policy_id)) return null;
    if (bytes.len != metadata.lexical_bytes) return null;
    const header = lexical_segment.inspect(bytes) catch return null;
    if (header.checksum != metadata.lexical_checksum) return null;
    if (header.hasPositions() or header.checksum_kind != .fnv1a64) return null;
    if (header.document_count != catalog_len or metadata.file_count != catalog_len) return null;
    if (header.term_count != metadata.term_count or header.posting_count != metadata.posting_count) return null;
    return .{ .header = header, .checksum = metadata.lexical_checksum, .file_count = metadata.file_count, .term_count = metadata.term_count, .posting_count = metadata.posting_count };
}

/// S4-T13 ruling 4: the sections for `catalog` (from `group`) with the
/// previous generation's filename lexical section `lexical` carried as it
/// is (`carryLexical` checked it): only the catalog, whose anchors move with
/// a changed file's chunks, is encoded.
pub fn buildCarried(allocator: std.mem.Allocator, catalog_documents: []hybrid.Document, lexical: []const u8, carried: CarriedLexical, marks: anytype) !Built {
    marks.mark("lexical_carried");
    const catalog_len = try segment.encodedLength(catalog_documents);
    const catalog_buffer = try allocator.alloc(u8, catalog_len);
    const catalog = try segment.encode(catalog_documents, catalog_buffer);
    marks.mark("encode_catalog");
    return .{ .catalog = catalog, .lexical = lexical, .decoded_catalog = catalog_documents, .carried = carried };
}

/// The full build from a catalog `group` returned: every stem tokenized,
/// the filename lexical index built, both sections encoded.
pub fn buildFromCatalog(allocator: std.mem.Allocator, docs: []hybrid.Document, analyzer_id: []const u8, marks: anytype) !Built {
    const token_lists = try allocator.alloc([][]const u8, docs.len);
    for (docs, 0..) |doc, j| token_lists[j] = try tokenize(allocator, analyzer_id, doc.text);
    marks.mark("tokenize");
    const lexical_index = try lexical_build.build(allocator, docs, token_lists);
    marks.mark("lexical_build");
    const catalog_len = try segment.encodedLength(docs);
    const catalog_buffer = try allocator.alloc(u8, catalog_len);
    const catalog = try segment.encode(docs, catalog_buffer);
    marks.mark("encode_catalog");
    const lexical = try lexical_segment.encodeAlloc(allocator, lexical_index);
    marks.mark("encode_lexical");
    return .{ .catalog = catalog, .lexical = lexical, .decoded_catalog = docs, .decoded_lexical = lexical_index };
}

/// S4-T4 ruling 4: the writer's check of the two sections `build` just
/// encoded, before they are published. The sections are decoded with the
/// reader's structural walk (`decode`: checksums, counts, paths unique and
/// in order, every entry anchored to its file's first body chunk with equal
/// labels, the dictionary free of duplicates), then compared field by field
/// with the catalog and the lexical index `build` encoded them from (the same
/// tokens, the same postings). `validate`, which re-tokenizes every name from
/// the catalog text, stays the check of the tests and of `import-json`.
pub fn validateBuilt(allocator: std.mem.Allocator, body_documents: []const hybrid.Document, built: Built) !void {
    if (built.carried) |carried| return validateCarried(allocator, built, carried);
    const expected = built.decoded_lexical orelse return error.FilenameLexicalMismatch;
    const empty = postings.Index{ .terms = &.{}, .postings = &.{}, .document_lengths = &.{}, .average_document_length = 0 };
    const decoded = try decode(allocator, body_documents, empty, built.catalog, built.lexical);
    if (decoded.catalog.len != built.decoded_catalog.len) return error.FilenameCatalogMismatch;
    for (decoded.catalog, built.decoded_catalog) |have, want| {
        if (!std.mem.eql(u8, have.id, want.id) or !std.mem.eql(u8, have.path, want.path) or !std.mem.eql(u8, have.text, want.text) or
            have.start_line != want.start_line or have.end_line != want.end_line or !std.mem.eql(u8, have.required_labels, want.required_labels))
            return error.FilenameCatalogMismatch;
    }
    const have = decoded.lexical;
    if (have.terms.len != expected.terms.len or have.postings.len != expected.postings.len or
        !std.mem.eql(u32, have.document_lengths, expected.document_lengths) or
        have.average_document_length != expected.average_document_length or
        (have.positions == null) != (expected.positions == null)) return error.FilenameLexicalMismatch;
    for (have.terms, expected.terms) |a, b| {
        if (!std.mem.eql(u8, a.term, b.term) or a.document_frequency != b.document_frequency or
            a.postings_start != b.postings_start or a.postings_length != b.postings_length) return error.FilenameLexicalMismatch;
    }
    for (have.postings, expected.postings) |a, b| {
        if (a.document_index != b.document_index or a.term_frequency != b.term_frequency) return error.FilenameLexicalMismatch;
    }
}

/// S4-T13 ruling 4: `validateBuilt` for a carried filename lexical section.
/// The catalog is decoded (its checksum, the reader's rules for each entry:
/// valid paths in strict order, no vectors, the stem as text) and compared
/// field by field with the grouping it was encoded from, which anchors each
/// file to its first body chunk. The carried section is checked by its
/// checksum and its header's counts, against the catalog and the previous
/// manifest (`carryLexical` computed that checksum once, when it was read),
/// not decoded a second time.
fn validateCarried(allocator: std.mem.Allocator, built: Built, carried: CarriedLexical) !void {
    const header = segment.inspect(built.catalog) catch return error.FilenameCatalogMismatch;
    if (header.vector_dimensions != 0 or header.document_count != built.decoded_catalog.len) return error.FilenameCatalogMismatch;
    const catalog = try segment.decodeInspected(built.catalog, header, try allocator.alloc(hybrid.Document, header.document_count), &.{});
    for (catalog, built.decoded_catalog, 0..) |have, want, i| {
        if (!validPath(have.path) or have.vector.len != 0 or !std.mem.eql(u8, have.text, stem(have.path))) return error.FilenameCatalogMismatch;
        if (i > 0 and std.mem.order(u8, catalog[i - 1].path, have.path) != .lt) return error.FilenameCatalogMismatch;
        if (!std.mem.eql(u8, have.id, want.id) or !std.mem.eql(u8, have.path, want.path) or !std.mem.eql(u8, have.text, want.text) or
            have.start_line != want.start_line or have.end_line != want.end_line or !std.mem.eql(u8, have.required_labels, want.required_labels))
            return error.FilenameCatalogMismatch;
    }
    const lexical = carried.header;
    if (lexical.checksum != carried.checksum or storedLexicalChecksum(built.lexical) != carried.checksum) return error.FilenameLexicalMismatch;
    if (lexical.document_count != catalog.len or carried.file_count != catalog.len) return error.FilenameLexicalMismatch;
    if (lexical.term_count != carried.term_count or lexical.posting_count != carried.posting_count) return error.FilenameLexicalMismatch;
}

fn storedLexicalChecksum(bytes: []const u8) u64 {
    if (bytes.len < lexical_segment.header_length) return 0;
    return std.mem.readInt(u64, bytes[lexical_segment.header_length - 8 ..][0..8], .little);
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
    // Sorting may compare an entry with itself. Its id cannot break a tie
    // with itself, and cached filename ranking need not read a body record.
    if (a.body_index == b.body_index) return false;
    return std.mem.order(u8, docs[a.body_index].id, docs[b.body_index].id) == .lt;
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
    /// S4-T2 R5, the anchor ordinal map: each body chunk's file, as its
    /// catalog index, so a query groups chunks by file through an array.
    file_of: []const u32,
    /// Sums of the stored lengths, for the unscoped query's BM25 averages
    /// (the same float division a scoped query does over its visible set).
    filename_total_length: usize,
    body_total_length: usize,
    /// Any file carries a required label (then every query checks scope).
    labeled: bool,
    /// The highest root ordinal of any chunk when every chunk lies under a
    /// root (set by `scope.Loads` after the load; null: unknown, or some
    /// chunk under no root). A root mask that allows every ordinal up to it
    /// hides nothing, so such a query is unscoped (S4-T2 R5: the servers pass
    /// a mask on every request).
    max_document_root: ?u16 = null,

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
/// sections and every decoded table, with alignment slack. S4-T2 R4 had the
/// open reserve them in its one section slab, so the first filename query
/// never grew the handle's arena by another geometric step; since S4-T9 the
/// open reserves nothing and this is the size of the one exact block the
/// first filename query allocates from the handle's parent allocator
/// (`scope.Folder.filenameDecoded`), for the same reason.
pub fn loadReservation(metadata: manifest.Manifest) usize {
    const f = metadata.filename orelse return 0;
    const slack = 64;
    var total: usize = f.catalog_bytes + f.lexical_bytes + 6 * slack;
    total += f.file_count * (@sizeOf(hybrid.Document) + @sizeOf(u32) + @sizeOf(usize));
    total += metadata.document_count * @sizeOf(u32);
    total += f.term_count * (@sizeOf(postings.TermEntry) + @sizeOf(u32));
    total += f.posting_count * @sizeOf(postings.Posting);
    return total;
}
pub fn decode(allocator: std.mem.Allocator, body_docs: []const hybrid.Document, body_index: postings.Index, catalog_encoded: []const u8, lexical_encoded: []const u8) !Decoded {
    return decodeInspected(allocator, body_docs, body_index, catalog_encoded, try segment.inspect(catalog_encoded), lexical_encoded, try lexical_segment.inspect(lexical_encoded));
}

/// `decode` with both headers already inspected (each checksum computed
/// once, by `load`).
fn decodeInspected(allocator: std.mem.Allocator, body_docs: []const hybrid.Document, body_index: postings.Index, catalog_encoded: []const u8, ch: segment.Header, lexical_encoded: []const u8, lh: lexical_segment.Header) !Decoded {
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
    const file_of = try allocator.alloc(u32, body_docs.len);
    var body_total_length: usize = 0;
    for (body_index.document_lengths) |length| body_total_length += length; // empty for `validate`
    // Chunks of one file are adjacent and files usually come in path order,
    // so the previous entry or the next one is tried before a search.
    var last: usize = 0;
    for (body_docs, 0..) |doc, i| {
        const ci = if (catalog.len != 0 and std.mem.eql(u8, catalog[last].path, doc.path))
            last
        else if (last + 1 < catalog.len and std.mem.eql(u8, catalog[last + 1].path, doc.path))
            last + 1
        else
            catalogIndex(catalog, doc.path) orelse return error.FilenameCatalogMismatch;
        last = ci;
        file_of[i] = @intCast(ci);
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
    var filename_total_length: usize = 0;
    for (lexical.document_lengths) |length| filename_total_length += length;
    var labeled = false;
    for (catalog) |doc| if (doc.required_labels.len != 0) {
        labeled = true;
    };
    return .{ .catalog = catalog, .lexical = lexical, .anchors = anchors, .term_order = term_order, .file_of = file_of, .filename_total_length = filename_total_length, .body_total_length = body_total_length, .labeled = labeled };
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
    return decodeInspected(allocator, body_docs, body_index, catalog_encoded, catalog, lexical_encoded, lexical);
}

pub fn query(allocator: std.mem.Allocator, body_docs: []const hybrid.Document, body_index: postings.Index, catalog_encoded: []const u8, lexical_encoded: []const u8, analyzer_id: []const u8, query_text: []const u8, field: Field, options: hybrid.SearchOptions) ![]Hit {
    return queryDecoded(allocator, body_docs, body_index, try decode(allocator, body_docs, body_index, catalog_encoded, lexical_encoded), analyzer_id, query_text, field, options);
}
/// A filename or both query over the decoded sections (S4-T2 R5): linear
/// in the postings of the query's terms plus, for a scoped query, one pass
/// over the catalog and the chunks to count the visible set. An unscoped
/// query (no root mask, no path prefix, no labelled file) uses the totals
/// the load summed, so it touches only the postings it scores; chunks are
/// grouped by file through the anchor ordinal map (`file_of`), not by path.
/// Results equal PR #21's query exactly: the same candidates, BM25 inputs,
/// tie-breaks, candidate depth and RRF fusion. S4-T15: each channel keeps a
/// bounded top `candidate_k` (`rankChannels`) instead of sorting every
/// candidate; its first `candidate_k` are the full sort's.
pub fn queryDecoded(allocator: std.mem.Allocator, body_docs: []const hybrid.Document, body_index: postings.Index, decoded: Decoded, analyzer_id: []const u8, query_text: []const u8, field: Field, options: hybrid.SearchOptions) ![]Hit {
    if (field == .content) return error.ContentQueryUseLegacy;
    if (options.retrieval_mode != .lexical) return error.InvalidRetrievalMode;
    if (options.candidate_k < options.top_k) return error.CandidateDepthTooSmall;
    const scored = try scoreQuery(allocator, body_docs, body_index, decoded, analyzer_id, query_text, field, options);
    const ranked = try rankChannels(allocator, body_docs, decoded, scored, field, options.candidate_k);
    if (field == .both) if (options.title) |title| return merge(allocator, body_docs, decoded, scored, ranked, title, query_text, options);
    return fuse(allocator, body_docs, ranked, field, options);
}

/// One file of the S5-T2 merge: its cited chunk and merged score.
const Merged = struct { chunk: u32, score: f32 };

/// The merge's order: score, then path, then chunk id. Its values are
/// distinct files, and the catalog's paths are strictly ascending
/// (`decode` refuses any other), so the path order is the file ordinal's
/// (`Decoded.file_of`) and no path is compared.
const MergedOrder = struct { docs: []const hybrid.Document, file_of: []const u32 };

fn mergedBefore(order: MergedOrder, a: Merged, b: Merged) bool {
    if (a.score != b.score) return a.score > b.score;
    const fa = order.file_of[a.chunk];
    const fb = order.file_of[b.chunk];
    if (fa != fb) return fa < fb;
    return std.mem.order(u8, order.docs[a.chunk].id, order.docs[b.chunk].id) == .lt;
}
const MergedTop = hybrid.BoundedTop(Merged, MergedOrder, mergedBefore);

/// S5-T2 (ruling 3): `both` as a score-level merge, one result per file:
/// the file's best body chunk's BM25 plus its title part
/// (`title_field.scoreQuery`), the cited chunk the best body chunk or the
/// file's first chunk, ordered by score, then path, then chunk id, cut to
/// `top_k` by a bounded top. No channel is cut before the sum; the stem
/// channel only reports (`filename_score`, `filename_rank` within its first
/// `candidate_k`, as `body_rank` is).
fn merge(allocator: std.mem.Allocator, body_docs: []const hybrid.Document, decoded: Decoded, scored: Scored, ranked: Ranked, title: *const title_field.Field, query_text: []const u8, options: hybrid.SearchOptions) ![]Hit {
    const parts = try title_field.scoreQuery(allocator, title, body_docs, query_text, options);
    defer if (parts) |p| p.deinit(allocator);
    var top = MergedTop{ .items = try allocator.alloc(Merged, options.top_k), .context = .{ .docs = body_docs, .file_of = decoded.file_of } };
    if (parts) |p| {
        // Files with a body match: the best chunk (`rankChannels` left it
        // in `slot_of_file`, over every body match) plus the file's part.
        for (scored.body_touched) |bi| {
            if (ranked.slot_of_file[decoded.file_of[bi]] != bi) continue;
            const score = scored.body_scores[bi] + p.scores[title.file_of[bi]];
            if (score > 0) top.offer(.{ .chunk = @intCast(bi), .score = score });
        }
        // Title-only files, at their first chunk, when the request may see
        // them.
        for (p.touched) |f| {
            const chunk = title.files[f].first_chunk;
            if (ranked.slot_of_file[decoded.file_of[chunk]] != no_slot) continue;
            if (!inScope(body_docs[chunk], chunk, options)) continue;
            top.offer(.{ .chunk = chunk, .score = p.scores[f] });
        }
    } else {
        // No query word is in any title: each file's score is its best
        // body chunk's, which the body channel already holds in this order
        // (score, then path) over its first `candidate_k >= top_k`.
        for (ranked.body[0..@min(options.top_k, ranked.body.len)], 0..) |c, i| top.items[i] = .{ .chunk = @intCast(c.body_index), .score = c.score };
        top.count = @min(options.top_k, ranked.body.len);
    }
    const kept = if (parts == null) top.items[0..top.count] else top.sorted();
    const hits = try allocator.alloc(Hit, kept.len);
    for (kept, hits) |m, *hit| {
        const file = decoded.file_of[m.chunk];
        const has_body = ranked.slot_of_file[file] == m.chunk;
        hit.* = .{ .document_index = m.chunk, .fused_score = m.score };
        if (has_body) {
            hit.body_score = scored.body_scores[m.chunk];
            for (ranked.body, 0..) |c, rank| if (c.catalog_index == file) {
                hit.body_rank = rank + 1;
                break;
            };
        }
        if (scored.fname_scores[file] > 0) {
            hit.filename_score = scored.fname_scores[file];
            for (ranked.filename, 0..) |c, rank| if (c.catalog_index == file) {
                hit.filename_rank = rank + 1;
                break;
            };
        }
        if (parts) |p| {
            const part = p.scores[title.file_of[m.chunk]];
            if (part > 0) hit.title_score = part;
        }
    }
    return hits;
}

/// S4-T15: what `scoreQuery` leaves for the selections: each catalog
/// entry's and each chunk's summed score, and the entries and chunks
/// scored, each once, in first-scored order.
const Scored = struct {
    fname_scores: []const f32,
    fname_touched: []const u32,
    body_scores: []const f32 = &.{},
    body_touched: []const u32 = &.{},
};

/// The BM25 walks of a filename or both query: the visible set per field
/// (scoped queries only), then each distinct query term's postings in
/// each field.
fn scoreQuery(allocator: std.mem.Allocator, body_docs: []const hybrid.Document, body_index: postings.Index, decoded: Decoded, analyzer_id: []const u8, query_text: []const u8, field: Field, options: hybrid.SearchOptions) !Scored {
    const catalog = decoded.catalog;
    const lexical = decoded.lexical;
    const qt = try tokenize(allocator, analyzer_id, query_text);
    const scoped = maskHides(decoded, options.visible_roots) or options.path_prefix != null or decoded.labeled;

    // The visible set's size and average length, per field.
    var filename_visible: ?[]bool = null;
    var filename_n: usize = catalog.len;
    var filename_total = decoded.filename_total_length;
    var body_visible: ?[]bool = null;
    var body_n: usize = body_docs.len;
    var body_total = decoded.body_total_length;
    if (scoped) {
        const visible = try allocator.alloc(bool, catalog.len);
        filename_n = 0;
        filename_total = 0;
        for (catalog, visible, 0..) |doc, *flag, i| {
            flag.* = inScope(doc, decoded.anchors[i], options);
            if (!flag.*) continue;
            filename_n += 1;
            filename_total += lexical.document_lengths[i];
        }
        filename_visible = visible;
        if (field == .both) {
            const body_flags = try allocator.alloc(bool, body_docs.len);
            body_n = 0;
            body_total = 0;
            for (body_docs, body_flags, 0..) |doc, *flag, i| {
                flag.* = inScope(doc, i, options);
                if (!flag.*) continue;
                body_n += 1;
                body_total += body_index.document_lengths[i];
            }
            body_visible = body_flags;
        }
    }
    const filename_avg = if (filename_n == 0) 0 else @as(f32, @floatFromInt(filename_total)) / @as(f32, @floatFromInt(filename_n));
    const body_avg = if (body_n == 0) 0 else @as(f32, @floatFromInt(body_total)) / @as(f32, @floatFromInt(body_n));

    // Scores accumulate per catalog entry and per chunk; `touched` lists
    // each entry once, in first-scored order.
    const fname_scores = try allocator.alloc(f32, catalog.len);
    @memset(fname_scores, 0);
    const fname_seen = try allocator.alloc(bool, catalog.len);
    @memset(fname_seen, false);
    var fname_touched = std.ArrayList(u32).empty;
    var body_scores: []f32 = &.{};
    var body_seen: []bool = &.{};
    var body_touched = std.ArrayList(u32).empty;
    if (field == .both) {
        body_scores = try allocator.alloc(f32, body_docs.len);
        @memset(body_scores, 0);
        body_seen = try allocator.alloc(bool, body_docs.len);
        @memset(body_seen, false);
    }
    for (qt, 0..) |term, qi| {
        var repeated = false;
        for (qt[0..qi]) |previous| if (std.mem.eql(u8, previous, term)) {
            repeated = true;
            break;
        };
        if (repeated) continue;
        if (decoded.filenameTerm(term)) |ti| {
            const ent = lexical.terms[ti];
            const list = lexical.postings[ent.postings_start .. ent.postings_start + ent.postings_length];
            var df: u32 = 0;
            if (filename_visible) |visible| {
                for (list) |p| if (visible[p.document_index]) {
                    df += 1;
                };
            } else df = @intCast(list.len);
            for (list) |p| {
                if (filename_visible) |visible| if (!visible[p.document_index]) continue;
                if (!fname_seen[p.document_index]) {
                    fname_seen[p.document_index] = true;
                    try fname_touched.append(allocator, p.document_index);
                }
                fname_scores[p.document_index] += scoring.bm25Contribution(@floatFromInt(p.term_frequency), @floatFromInt(lexical.document_lengths[p.document_index]), filename_avg, df, @intCast(filename_n), options.bm25);
            }
        }
        if (field == .both) if (options.fuzzy_groups) |groups| if (groups.of(term)) |fuzzy_group| {
            // S5-T3: the term's fuzzy-v1 group, at one df (the largest of
            // the members' in this walk's visible set), each chunk its best
            // weighted member; the filename channel above is not expanded.
            try scoreBodyGroup(allocator, body_index, fuzzy_group, body_visible, body_avg, @intCast(body_n), options, body_scores, body_seen, &body_touched);
            continue;
        };
        if (field == .both) if (postings.lookupExact(body_index, term)) |ti| {
            const ent = body_index.terms[ti];
            const list = body_index.postings[ent.postings_start .. ent.postings_start + ent.postings_length];
            var df: u32 = 0;
            if (body_visible) |visible| {
                for (list) |p| if (visible[p.document_index]) {
                    df += 1;
                };
            } else df = @intCast(list.len);
            for (list) |p| {
                if (body_visible) |visible| if (!visible[p.document_index]) continue;
                if (!body_seen[p.document_index]) {
                    body_seen[p.document_index] = true;
                    try body_touched.append(allocator, p.document_index);
                }
                body_scores[p.document_index] += scoring.bm25Contribution(@floatFromInt(p.term_frequency), @floatFromInt(body_index.document_lengths[p.document_index]), body_avg, df, @intCast(body_n), options.bm25);
            }
        };
    }
    return .{ .fname_scores = fname_scores, .fname_touched = fname_touched.items, .body_scores = body_scores, .body_touched = body_touched.items };
}

fn scoreBodyGroup(allocator: std.mem.Allocator, body_index: postings.Index, fuzzy_group: fuzzy.Group, body_visible: ?[]const bool, body_avg: f32, body_n: u32, options: hybrid.SearchOptions, body_scores: []f32, body_seen: []bool, body_touched: *std.ArrayList(u32)) !void {
    // S5-T4: a fold-groups-v1 group may hold more than fuzzy-v1's three.
    var list_buffer: [fuzzy.max_expansions][]const postings.Posting = undefined;
    var weight_buffer: [fuzzy.max_expansions]f32 = undefined;
    var cursor_buffer: [fuzzy.max_expansions]usize = @splat(0);
    const many = fuzzy_group.members.len > fuzzy.max_expansions;
    const lists: [][]const postings.Posting = if (many) try allocator.alloc([]const postings.Posting, fuzzy_group.members.len) else &list_buffer;
    defer if (many) allocator.free(lists);
    const weights: []f32 = if (many) try allocator.alloc(f32, fuzzy_group.members.len) else &weight_buffer;
    defer if (many) allocator.free(weights);
    const cursors: []usize = if (many) try allocator.alloc(usize, fuzzy_group.members.len) else &cursor_buffer;
    defer if (many) allocator.free(cursors);
    @memset(cursors, 0);
    var len: usize = 0;
    var df: u32 = 0;
    for (fuzzy_group.members) |member| if (member.body) |ent| {
        const list = body_index.postings[ent.postings_start .. ent.postings_start + ent.postings_length];
        var member_df: u32 = 0;
        if (body_visible) |visible| {
            for (list) |p| if (visible[p.document_index]) {
                member_df += 1;
            };
        } else member_df = @intCast(list.len);
        df = @max(df, member_df);
        lists[len] = list;
        weights[len] = member.weight;
        len += 1;
    };
    while (true) {
        var chunk: ?u32 = null;
        for (lists[0..len], cursors[0..len]) |list, cursor| {
            if (cursor < list.len and (chunk == null or list[cursor].document_index < chunk.?)) chunk = list[cursor].document_index;
        }
        const d = chunk orelse break;
        var best: ?f32 = null;
        for (lists[0..len], cursors[0..len], weights[0..len]) |list, *cursor, w| {
            if (cursor.* >= list.len or list[cursor.*].document_index != d) continue;
            const part = w * scoring.bm25Contribution(@floatFromInt(list[cursor.*].term_frequency), @floatFromInt(body_index.document_lengths[d]), body_avg, df, body_n, options.bm25);
            if (best == null or part > best.?) best = part;
            cursor.* += 1;
        }
        if (body_visible) |visible| if (!visible[d]) continue;
        if (!body_seen[d]) {
            body_seen[d] = true;
            try body_touched.append(allocator, d);
        }
        body_scores[d] += best.?;
    }
}

/// S4-T15: the two channels' candidates in `lessCandidate` order, each cut
/// to `candidate_k`, and (both) the per-file array the merge reuses.
const Ranked = struct {
    filename: []Candidate,
    body: []Candidate = &.{},
    slot_of_file: []u32 = &.{},
};

fn candidateBefore(docs: []const hybrid.Document, a: Candidate, b: Candidate) bool {
    return lessCandidate(a, b, docs);
}
const CandidateTop = hybrid.BoundedTop(Candidate, []const hybrid.Document, candidateBefore);
const no_slot = std.math.maxInt(u32);

/// S4-T15: each channel keeps a bounded top `candidate_k` (`hybrid.BoundedTop`)
/// instead of sorting every candidate. Within one channel no two candidates
/// share a path (one per catalog entry, and `decode` refuses a catalog whose
/// paths are not strictly ascending), and every score is finite and
/// positive, so `lessCandidate` is a strict total order on them: the kept
/// candidates, sorted, are the first `candidate_k` of the full sort, element
/// for element.
fn rankChannels(allocator: std.mem.Allocator, body_docs: []const hybrid.Document, decoded: Decoded, scored: Scored, field: Field, candidate_k: usize) !Ranked {
    const catalog = decoded.catalog;
    // Filename candidates: every visible file with a positive score.
    var filename_top = CandidateTop{ .items = try allocator.alloc(Candidate, @min(candidate_k, scored.fname_touched.len)), .context = body_docs };
    for (scored.fname_touched) |i| {
        const score = scored.fname_scores[i];
        if (score <= 0) continue;
        filename_top.offer(.{ .path = catalog[i].path, .body_index = decoded.anchors[i], .score = score, .catalog_index = i });
    }
    var ranked = Ranked{ .filename = filename_top.sorted() };
    if (field != .both) return ranked;

    // Body candidates: each file's best chunk, the higher score and then the
    // smaller chunk id (the first scored on an exact tie), grouped by the
    // anchor ordinal map. A file's chunks are not adjacent in the touched
    // list, so the best chunk per file is found first (`slot_of_file`) and
    // each file is offered once after.
    const slot_of_file = try allocator.alloc(u32, catalog.len);
    @memset(slot_of_file, no_slot);
    var files: usize = 0;
    for (scored.body_touched) |bi| {
        const score = scored.body_scores[bi];
        if (score <= 0) continue;
        const best = &slot_of_file[decoded.file_of[bi]];
        if (best.* == no_slot) {
            best.* = bi;
            files += 1;
            continue;
        }
        const held = scored.body_scores[best.*];
        if (score > held or (score == held and std.mem.order(u8, body_docs[bi].id, body_docs[best.*].id) == .lt)) best.* = bi;
    }
    var body_top = CandidateTop{ .items = try allocator.alloc(Candidate, @min(candidate_k, files)), .context = body_docs };
    for (scored.body_touched) |bi| {
        const file = decoded.file_of[bi];
        if (slot_of_file[file] != bi) continue;
        body_top.offer(.{ .path = body_docs[bi].path, .body_index = bi, .score = scored.body_scores[bi], .catalog_index = file });
    }
    ranked.body = body_top.sorted();
    ranked.slot_of_file = slot_of_file;
    return ranked;
}

/// The hits: the filename channel's first `top_k`, or (both) the two
/// channels fused per file by RRF (k = 60), sorted and cut to `top_k`.
fn fuse(allocator: std.mem.Allocator, body_docs: []const hybrid.Document, ranked: Ranked, field: Field, options: hybrid.SearchOptions) ![]Hit {
    var out = std.ArrayList(Hit).empty;
    if (field == .filename) {
        for (ranked.filename, 0..) |c, rank| if (out.items.len < options.top_k) try out.append(allocator, .{ .document_index = c.body_index, .filename_score = c.score, .filename_rank = rank + 1, .fused_score = c.score });
    } else {
        // Reuse the per-file array as each file's hit slot.
        @memset(ranked.slot_of_file, no_slot);
        for (ranked.body, 0..) |c, rank| try mergeHit(allocator, &out, ranked.slot_of_file, c, true, rank + 1, 60);
        for (ranked.filename, 0..) |c, rank| try mergeHit(allocator, &out, ranked.slot_of_file, c, false, rank + 1, 60);
        std.mem.sort(Hit, out.items, body_docs, hitLess);
        out.items = out.items[0..@min(out.items.len, options.top_k)];
    }
    return out.toOwnedSlice(allocator);
}

fn maskHides(decoded: Decoded, visible_roots: ?hybrid.RootMask) bool {
    const mask = visible_roots orelse return false;
    const highest = decoded.max_document_root orelse return true;
    if (mask.allowed.len <= highest) return true;
    for (mask.allowed[0 .. @as(usize, highest) + 1]) |allowed| if (!allowed) return true;
    return false;
}

fn mergeHit(a: std.mem.Allocator, out: *std.ArrayList(Hit), slot_of_file: []u32, c: Candidate, is_body: bool, rank: usize, k: f32) !void {
    const slot = &slot_of_file[c.catalog_index];
    if (slot.* != std.math.maxInt(u32)) {
        const h = &out.items[slot.*];
        if (is_body) {
            h.body_rank = rank;
            h.body_score = c.score;
        } else {
            h.filename_rank = rank;
            h.filename_score = c.score;
        }
        h.fused_score += 1 / (k + @as(f32, @floatFromInt(rank)));
        return;
    }
    slot.* = @intCast(out.items.len);
    try out.append(a, .{ .document_index = c.body_index, .body_score = if (is_body) c.score else 0, .body_rank = if (is_body) rank else null, .filename_score = if (is_body) 0 else c.score, .filename_rank = if (is_body) null else rank, .fused_score = 1 / (k + @as(f32, @floatFromInt(rank))) });
}
fn hitLess(docs: []const hybrid.Document, a: Hit, b: Hit) bool {
    if (a.fused_score != b.fused_score) return a.fused_score > b.fused_score;
    const x = std.mem.order(u8, docs[a.document_index].path, docs[b.document_index].path);
    if (x != .eq) return x == .lt;
    return std.mem.order(u8, docs[a.document_index].id, docs[b.document_index].id) == .lt;
}

// --- S4-T15 ruling 2(a): the bounded selections against today's full sort ---

/// The comparator `sortCandidates` used before S4-T15, copied: the
/// reference keeps the full order even when `lessCandidate` is planted.
fn referenceLess(docs: []const hybrid.Document, a: Candidate, b: Candidate) bool {
    if (a.score != b.score) return a.score > b.score;
    const order = std.mem.order(u8, a.path, b.path);
    if (order != .eq) return order == .lt;
    if (a.body_index == b.body_index) return false;
    return std.mem.order(u8, docs[a.body_index].id, docs[b.body_index].id) == .lt;
}

/// The selection before S4-T15, copied: every positive candidate of each
/// channel, the body channel grouped per file into a list, each list fully
/// sorted with `std.mem.sort`. Not cut: the caller cuts to `candidate_k`.
fn referenceFull(allocator: std.mem.Allocator, body_docs: []const hybrid.Document, decoded: Decoded, scored: Scored, field: Field) !Ranked {
    const catalog = decoded.catalog;
    var filename = try allocator.alloc(Candidate, scored.fname_touched.len);
    var fn_count: usize = 0;
    for (scored.fname_touched) |i| {
        const score = scored.fname_scores[i];
        if (score <= 0) continue;
        filename[fn_count] = .{ .path = catalog[i].path, .body_index = decoded.anchors[i], .score = score, .catalog_index = i };
        fn_count += 1;
    }
    std.mem.sort(Candidate, filename[0..fn_count], body_docs, referenceLess);
    var ranked = Ranked{ .filename = filename[0..fn_count] };
    if (field != .both) return ranked;
    var body = std.ArrayList(Candidate).empty;
    const slot_of_file = try allocator.alloc(u32, catalog.len);
    @memset(slot_of_file, no_slot);
    for (scored.body_touched) |bi| {
        const score = scored.body_scores[bi];
        if (score <= 0) continue;
        const file = decoded.file_of[bi];
        const doc = body_docs[bi];
        if (slot_of_file[file] != no_slot) {
            const ix = slot_of_file[file];
            if (score > body.items[ix].score or (score == body.items[ix].score and std.mem.order(u8, doc.id, body_docs[body.items[ix].body_index].id) == .lt)) body.items[ix] = .{ .path = doc.path, .body_index = bi, .score = score, .catalog_index = file };
        } else {
            slot_of_file[file] = @intCast(body.items.len);
            try body.append(allocator, .{ .path = doc.path, .body_index = bi, .score = score, .catalog_index = file });
        }
    }
    std.mem.sort(Candidate, body.items, body_docs, referenceLess);
    ranked.body = body.items;
    ranked.slot_of_file = slot_of_file;
    return ranked;
}

const RandomCorpus = struct {
    body: []hybrid.Document,
    index: postings.Index,
    decoded: Decoded,
    /// Each chunk's root (its top folder), for the root masks.
    roots: []u16,
    catalog_len: usize,
};

const test_folders = [_][]const u8{ "school", "home", "laptop", "private" };
const test_subfolders = [_][]const u8{ "", "trips/", "old/" };
const test_stems = [_][]const u8{ "notes", "plan", "budget", "tide", "list", "harbour", "diary", "copper" };
const test_words = [_][]const u8{ "harbour", "tide", "ledger", "garden", "budget", "lantern", "orchard", "copper", "pond", "maple" };

/// `files` files (each 0 to 6 chunks: a file drawn with no chunk is absent),
/// with paths drawn from few folders and stems (equal filename scores broken
/// by path), a third of the chunk texts copied from an earlier chunk (equal body
/// scores), and chunk ids random and unique, unrelated to line order.
fn randomCorpus(a: std.mem.Allocator, random: std.Random, files: usize, labelled: bool) !RandomCorpus {
    var docs = std.ArrayList(hybrid.Document).empty;
    var roots = std.ArrayList(u16).empty;
    var paths: std.StringHashMapUnmanaged(void) = .empty;
    var texts = std.ArrayList([]const u8).empty;
    var id_counter: usize = 0;
    const suffixes: usize = @max(4, files / 40);
    var made: usize = 0;
    while (made < files) {
        const folder = random.uintLessThan(usize, test_folders.len);
        const sub = test_subfolders[random.uintLessThan(usize, test_subfolders.len)];
        const stem_name = test_stems[random.uintLessThan(usize, test_stems.len)];
        const suffix = random.uintLessThan(usize, suffixes + 1);
        const ext: []const u8 = if (random.boolean()) "md" else "txt";
        const path = if (suffix == 0)
            try std.fmt.allocPrint(a, "{s}/{s}{s}.{s}", .{ test_folders[folder], sub, stem_name, ext })
        else
            try std.fmt.allocPrint(a, "{s}/{s}{s}-{d}.{s}", .{ test_folders[folder], sub, stem_name, suffix, ext });
        const slot = try paths.getOrPut(a, path);
        if (slot.found_existing) continue;
        made += 1;
        const labels: []const u8 = if (labelled and folder == 3) "family" else "";
        const chunks = random.uintAtMost(usize, 6);
        for (0..chunks) |chunk| {
            const text = if (texts.items.len > 0 and random.uintLessThan(u8, 3) == 0)
                texts.items[random.uintLessThan(usize, texts.items.len)]
            else blk: {
                var words = std.ArrayList(u8).empty;
                for (0..1 + random.uintLessThan(usize, 10)) |w| {
                    if (w > 0) try words.append(a, ' ');
                    try words.appendSlice(a, test_words[random.uintLessThan(usize, test_words.len)]);
                }
                break :blk words.items;
            };
            try texts.append(a, text);
            id_counter += 1;
            try docs.append(a, .{
                .id = try std.fmt.allocPrint(a, "{x:0>8}-{d}", .{ random.int(u32), id_counter }),
                .path = path,
                .text = text,
                .start_line = @intCast(1 + chunk * 10),
                .end_line = @intCast(9 + chunk * 10),
                .required_labels = labels,
            });
            try roots.append(a, @intCast(folder));
        }
    }
    // A writer's order (path order, chunks adjacent) or a shuffled one.
    if (random.boolean()) {
        const order = try a.alloc(usize, docs.items.len);
        for (order, 0..) |*o, i| o.* = i;
        random.shuffle(usize, order);
        const shuffled = try a.alloc(hybrid.Document, docs.items.len);
        const shuffled_roots = try a.alloc(u16, docs.items.len);
        for (order, shuffled, shuffled_roots) |from, *doc, *root| {
            doc.* = docs.items[from];
            root.* = roots.items[from];
        }
        docs.items = shuffled;
        roots.items = shuffled_roots;
    } else {
        const Pair = struct { doc: hybrid.Document, root: u16 };
        const pairs = try a.alloc(Pair, docs.items.len);
        for (pairs, docs.items, roots.items) |*pair, doc, root| pair.* = .{ .doc = doc, .root = root };
        std.mem.sort(Pair, pairs, {}, struct {
            fn less(_: void, x: Pair, y: Pair) bool {
                return std.mem.order(u8, x.doc.path, y.doc.path) == .lt;
            }
        }.less);
        for (pairs, docs.items, roots.items) |pair, *doc, *root| {
            doc.* = pair.doc;
            root.* = pair.root;
        }
    }
    const body = docs.items;
    const built = try build(a, body, analyzer_v2.analyzer_id);
    const token_lists = try a.alloc([][]const u8, body.len);
    for (body, token_lists) |doc, *tokens| tokens.* = try analyzer_v2.tokenize(a, doc.text);
    const index = try lexical_build.build(a, body, token_lists);
    const decoded = try decode(a, body, index, built.catalog, built.lexical);
    return .{ .body = body, .index = index, .decoded = decoded, .roots = roots.items, .catalog_len = decoded.catalog.len };
}

fn expectSameCandidates(expected: []const Candidate, actual: []const Candidate) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, got| {
        try std.testing.expectEqualStrings(e.path, got.path);
        try std.testing.expectEqual(e.body_index, got.body_index);
        try std.testing.expectEqual(e.catalog_index, got.catalog_index);
        try std.testing.expectEqual(@as(u32, @bitCast(e.score)), @as(u32, @bitCast(got.score)));
    }
}

/// Whether the cut at `depth` falls inside a run of equal scores.
fn tieAtCut(list: []const Candidate, depth: usize) bool {
    return depth > 0 and depth < list.len and list[depth - 1].score == list[depth].score;
}

test "S4-T15 ruling 2(a): the bounded selections are the full sort's first candidate_k, element for element" {
    const seeds = [_]u64{
        0x5415_0001, 0x5415_0002, 0x5415_0003, 0x9e37_79b9, 0x7f4a_7c15, 0x2545_f491, 0x0bad_cafe, 0x1357_9bdf,
        0x2468_ace0, 0x0f0f_1e1e, 0x3c3c_5a5a, 0x6996_9669, 0x1111_2222, 0x3333_4444, 0x5555_6666, 0x7777_8888,
        0x9999_aaaa, 0xbbbb_cccc, 0xdddd_eeee, 0x0123_4567, 0x89ab_cdef, 0xfeed_beef, 0xdead_10cc, 0xc0ff_ee00,
        0x0dd5_eed5, 0x5eed_0f15, 0xa5a5_5a5a, 0x1020_3040, 0x5060_7080, 0x90a0_b0c0,
    };
    var compared: usize = 0;
    var cut_runs: usize = 0;
    var ties_at_cut: usize = 0;
    var distinct_at_cut: usize = 0;
    for (seeds, 0..) |seed, round| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        // The edges 1, 2 and 3,000 first, then log-uniform in 1..3,000.
        const files: usize = switch (round) {
            0 => 1,
            1 => 2,
            2 => 3000,
            else => @intFromFloat(@round(@exp(random.float(f64) * @log(3000.0)))),
        };
        const labelled = random.boolean();
        const corpus = try randomCorpus(a, random, @max(1, files), labelled);
        try std.testing.expectEqual(labelled and corpus.body.len > 0 and blk: {
            for (corpus.body) |doc| if (doc.required_labels.len != 0) break :blk true;
            break :blk false;
        }, corpus.decoded.labeled);
        var rooted = corpus.decoded;
        rooted.max_document_root = test_folders.len - 1;
        for (0..16) |_| {
            // 1-3 words from the body words, the stems, a number or an absent word.
            var words = std.ArrayList(u8).empty;
            for (0..1 + random.uintLessThan(usize, 3)) |w| {
                if (w > 0) try words.append(a, ' ');
                const pick = random.uintLessThan(usize, test_words.len + test_stems.len + 2);
                const word: []const u8 = if (pick < test_words.len)
                    test_words[pick]
                else if (pick < test_words.len + test_stems.len)
                    test_stems[pick - test_words.len]
                else if (pick == test_words.len + test_stems.len)
                    "2"
                else
                    "absent";
                try words.appendSlice(a, word);
            }
            // Half the requests shallow (1-10), so that small corpora are cut too.
            const top_k = 1 + random.uintLessThan(usize, if (random.boolean()) 10 else 100);
            const n = corpus.catalog_len;
            const depths = [_]usize{ top_k, top_k + 1, 20, 100, n / 2, n -| 1, n, n + 1, 10_000, top_k + random.uintLessThan(usize, @max(1, n)) };
            var options = hybrid.SearchOptions{ .retrieval_mode = .lexical, .top_k = top_k, .candidate_k = @max(top_k, depths[random.uintLessThan(usize, depths.len)]) };
            var decoded = corpus.decoded;
            if (random.uintLessThan(u8, 3) == 0) options.path_prefix = switch (random.uintLessThan(u8, 4)) {
                0 => "school/",
                1 => "home/trips/",
                2 => "sc",
                else => "zz/",
            };
            if (random.boolean()) options.principal_labels = &.{"family"};
            if (random.uintLessThan(u8, 3) == 0) {
                const allowed = try a.alloc(bool, if (random.uintLessThan(u8, 4) == 0) test_folders.len - 1 else test_folders.len);
                for (allowed) |*flag| flag.* = random.uintLessThan(u8, 4) != 0;
                options.visible_roots = .{ .document_roots = corpus.roots, .allowed = allowed };
                decoded = rooted;
            }
            for ([_]Field{ .filename, .both }) |field| {
                const scored = try scoreQuery(a, corpus.body, corpus.index, decoded, analyzer_v2.analyzer_id, words.items, field, options);
                const full = try referenceFull(a, corpus.body, decoded, scored, field);
                const ranked = try rankChannels(a, corpus.body, decoded, scored, field, options.candidate_k);
                const fn_depth = @min(options.candidate_k, full.filename.len);
                const body_depth = @min(options.candidate_k, full.body.len);
                try expectSameCandidates(full.filename[0..fn_depth], ranked.filename);
                try expectSameCandidates(full.body[0..body_depth], ranked.body);
                for ([_][]const Candidate{ full.filename, full.body }) |list| {
                    if (options.candidate_k < list.len) cut_runs += 1;
                    if (tieAtCut(list, options.candidate_k)) ties_at_cut += 1 else if (options.candidate_k < list.len) distinct_at_cut += 1;
                }
                compared += ranked.filename.len + ranked.body.len;
                // The hits: the merge over the reference's cut lists against the query.
                const reference = Ranked{ .filename = full.filename[0..fn_depth], .body = full.body[0..body_depth], .slot_of_file = full.slot_of_file };
                const expected = try fuse(a, corpus.body, reference, field, options);
                const actual = try queryDecoded(a, corpus.body, corpus.index, decoded, analyzer_v2.analyzer_id, words.items, field, options);
                try std.testing.expectEqual(expected.len, actual.len);
                for (expected, actual) |e, got| try std.testing.expectEqual(e, got);
            }
        }
    }
    std.debug.print("S4-T15 ruling 2(a): {d} corpora, {d} candidates compared, {d} lists cut ({d} inside equal scores, {d} between different scores)\n", .{ seeds.len, compared, cut_runs, ties_at_cut, distinct_at_cut });
    // The corpora must exercise what the order decides: cuts inside a list,
    // and cuts that fall inside a run of equal scores.
    try std.testing.expect(compared > 10_000);
    try std.testing.expect(cut_runs >= 100);
    try std.testing.expect(ties_at_cut >= 20);
    try std.testing.expect(distinct_at_cut >= 20);
}

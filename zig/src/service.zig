const engine_module = @import("engine.zig");
const find_module = @import("find.zig");
const scoring = @import("scoring.zig");
const hybrid = @import("hybrid.zig");
const postings = @import("postings.zig");
const scope = @import("scope.zig");
const source_section = @import("source.zig");
const std = @import("std");

pub const Chunk = struct {
    chunk_id: []const u8,
    path: []const u8,
    start_line: u32,
    end_line: u32,
    content: []const u8,
};

pub const Source = struct {
    path: []const u8,
    chunks: usize,
};

pub const Status = struct {
    ready: bool,
    generation: u64,
    analyzer_id: []const u8,
    embedding_model_id: []const u8,
    vector_dimensions: usize,
    documents: usize,
    terms: usize,
    postings: usize,
};

pub const ServiceError = error{
    EvidenceCapacityTooSmall,
    SourceCapacityTooSmall,
};

/// S3-T3: `index_status` over a request's visible scope (implementation
/// section 8): counts of visible documents, terms, postings and files only,
/// the visible roots, pending files, chunkers and whether visible files have
/// retained source. A hidden file, term or root is indistinguishable from an
/// absent one.
pub const ScopedStatus = struct {
    ready: bool,
    generation: u64,
    analyzer_id: []const u8,
    embedding_model_id: []const u8,
    vector_dimensions: usize,
    documents: usize,
    terms: usize,
    postings: usize,
    files: usize,
    pending: usize,
    /// A visible file was given but not indexed in full (`meta.skipped`).
    truncated: bool,
    roots: []const RootStatus,
    pending_paths: []const FileRef,
    has_source: bool,
    has_positions: bool,
    chunkers: []const []const u8,
    /// S4-T1 (contract 2.1.0): the source section's state without loading
    /// it: `absent`, `unverified` (bound, not read yet), `verified` or
    /// `unavailable` (lost or damaged).
    source: []const u8 = "absent",
};

pub const RootStatus = struct {
    root_id: []const u8,
    label: []const u8,
    kind: []const u8,
    files: usize,
    documents: usize,
    pending: usize,
};

pub const FileRef = struct { root_id: []const u8, path: []const u8 };

/// S3-T3: one visible file (implementation section 8, `list_files`).
pub const FileListing = struct {
    root_id: []const u8,
    path: []const u8,
    status: []const u8,
    chunks: usize,
    chunker: ?[]const u8,
};

pub const ScopeError = error{ NoFolder, OutOfMemory };

pub const Service = struct {
    engine: engine_module.Engine,
    /// S3-T3: the generation's roots, pending files, statistics and source
    /// section (`snapshot_open.openScoped`). The scoped operations need it;
    /// the unscoped ones above (RPC and C ABI until S3-T4) do not.
    folder: ?*const scope.Folder = null,

    pub fn searchKnowledge(
        service: Service,
        allocator: std.mem.Allocator,
        query_text: []const u8,
        query_vector: []const f32,
        options: hybrid.SearchOptions,
        result_output: []hybrid.Result,
        evidence_output: []engine_module.Evidence,
    ) ![]engine_module.Evidence {
        return service.searchKnowledgeTraced(allocator, query_text, query_vector, options, result_output, evidence_output, null);
    }

    /// `searchKnowledge` that also fills `trace` (S2-T4).
    pub fn searchKnowledgeTraced(
        service: Service,
        allocator: std.mem.Allocator,
        query_text: []const u8,
        query_vector: []const f32,
        options: hybrid.SearchOptions,
        result_output: []hybrid.Result,
        evidence_output: []engine_module.Evidence,
        trace: ?*hybrid.Trace,
    ) ![]engine_module.Evidence {
        // S4-T1: the statistics groups load at the first scored query that
        // can hide a document (a root mask, or labelled records); without
        // them a scoped query would count its scope exactly, with equal
        // scores.
        var engine = service.engine;
        var titled_options = options;
        if (service.folder) |folder| {
            if (engine.statistics == null and (options.visible_roots != null or (engine.labeled_documents orelse true)))
                engine.statistics = try folder.statistics();
            // S5-T2 (ruling 3): every scoped entry point ranks with the
            // generation's title field, derived at its first lexical query.
            if (titled_options.title == null and options.retrieval_mode != .vector)
                titled_options.title = try folder.titleField();
        }
        const results = try engine.queryTraced(
            allocator,
            query_text,
            query_vector,
            result_output,
            titled_options,
            trace,
        );
        if (evidence_output.len < results.len) return error.EvidenceCapacityTooSmall;
        for (results, evidence_output[0..results.len]) |result, *evidence| {
            evidence.* = service.engine.evidence(result);
        }
        return evidence_output[0..results.len];
    }

    pub fn readChunk(
        service: Service,
        chunk_id: []const u8,
        path_prefix: ?[]const u8,
        principal_labels: []const []const u8,
    ) ?Chunk {
        for (service.engine.documents) |document| {
            if (!std.mem.eql(u8, document.id, chunk_id)) continue;
            if (path_prefix) |prefix| {
                if (!std.mem.startsWith(u8, document.path, prefix)) return null;
            }
            if (!hybrid.isAuthorized(document.required_labels, principal_labels)) return null;
            return .{
                .chunk_id = document.id,
                .path = document.path,
                .start_line = document.start_line,
                .end_line = document.end_line,
                .content = document.text,
            };
        }
        return null;
    }

    pub fn listSources(
        service: Service,
        path_prefix: ?[]const u8,
        principal_labels: []const []const u8,
        source_output: []Source,
    ) ServiceError![]Source {
        var count: usize = 0;
        for (service.engine.documents) |document| {
            if (document.path.len == 0) continue;
            if (path_prefix) |prefix| {
                if (!std.mem.startsWith(u8, document.path, prefix)) continue;
            }
            if (!hybrid.isAuthorized(document.required_labels, principal_labels)) continue;
            var existing: ?usize = null;
            for (source_output[0..count], 0..) |source, index| {
                if (std.mem.eql(u8, source.path, document.path)) {
                    existing = index;
                    break;
                }
            }
            if (existing) |index| {
                source_output[index].chunks += 1;
            } else {
                if (count >= source_output.len) return error.SourceCapacityTooSmall;
                source_output[count] = .{ .path = document.path, .chunks = 1 };
                count += 1;
            }
        }
        sortSources(source_output[0..count]);
        return source_output[0..count];
    }

    pub fn indexStatus(service: Service) Status {
        return .{
            .ready = true,
            .generation = service.engine.generation,
            .analyzer_id = service.engine.analyzer_id,
            .embedding_model_id = service.engine.embedding_model_id,
            .vector_dimensions = service.engine.vector_dimensions,
            .documents = service.engine.documents.len,
            .terms = service.engine.lexical_index.terms.len,
            .postings = service.engine.lexical_index.postings.len,
        };
    }
};

// ------------------------------------------------------------ S3-T3 scope ---

/// The resolved scope of one request: which roots it may see and the mask
/// that applies them to documents.
pub const Resolved = struct {
    folder: *const scope.Folder,
    allowed: []bool,
    labels: []const []const u8,

    pub fn mask(resolved: Resolved) hybrid.RootMask {
        return resolved.folder.mask(resolved.allowed);
    }

    pub fn documentVisible(resolved: Resolved, documents: []const hybrid.Document, index: usize) bool {
        return resolved.mask().allows(index) and hybrid.isAuthorized(documents[index].required_labels, resolved.labels);
    }

    fn rootVisible(resolved: Resolved, root_id: []const u8) bool {
        return resolved.folder.visibleRoot(resolved.allowed, root_id) != null;
    }

    /// A pending or unchunked file: its root is visible and the caller holds
    /// the file's own labels (the root's are in `allowed`).
    fn listedVisible(resolved: Resolved, entry: anytype) bool {
        return resolved.rootVisible(entry.root_id) and scope.holdsAll(entry.required_labels, resolved.labels);
    }

    pub fn deinit(resolved: Resolved, allocator: std.mem.Allocator) void {
        allocator.free(resolved.allowed);
    }
};

pub fn resolve(service: Service, allocator: std.mem.Allocator, request: scope.Request) ScopeError!Resolved {
    const folder = service.folder orelse return error.NoFolder;
    return .{ .folder = folder, .allowed = try folder.allowedRoots(allocator, request), .labels = request.principal_labels };
}

fn lessThanFileListing(_: void, a: FileListing, b: FileListing) bool {
    const order = std.mem.order(u8, a.root_id, b.root_id);
    if (order != .eq) return order == .lt;
    return std.mem.order(u8, a.path, b.path) == .lt;
}

pub const ScopedService = struct {
    service: Service,

    /// `search_knowledge` over the request's scope: roots and labels filter
    /// before candidates and BM25 uses the visible scope's statistics.
    pub fn searchKnowledge(
        scoped: ScopedService,
        allocator: std.mem.Allocator,
        query_text: []const u8,
        query_vector: []const f32,
        options: hybrid.SearchOptions,
        request: scope.Request,
        result_output: []hybrid.Result,
        evidence_output: []engine_module.Evidence,
        trace: ?*hybrid.Trace,
    ) ![]engine_module.Evidence {
        const resolved = try resolve(scoped.service, allocator, request);
        defer resolved.deinit(allocator);
        var scoped_options = options;
        scoped_options.principal_labels = request.principal_labels;
        scoped_options.visible_roots = resolved.mask();
        return scoped.service.searchKnowledgeTraced(allocator, query_text, query_vector, scoped_options, result_output, evidence_output, trace);
    }

    /// `read_chunk`: a hidden chunk and an unknown chunk are both null.
    pub fn readChunk(scoped: ScopedService, allocator: std.mem.Allocator, chunk_id: []const u8, path_prefix: ?[]const u8, request: scope.Request) !?Chunk {
        const resolved = try resolve(scoped.service, allocator, request);
        defer resolved.deinit(allocator);
        const documents = scoped.service.engine.documents;
        for (documents, 0..) |document, index| {
            if (!std.mem.eql(u8, document.id, chunk_id)) continue;
            if (!resolved.documentVisible(documents, index)) return null;
            if (path_prefix) |prefix| if (!std.mem.startsWith(u8, document.path, prefix)) return null;
            return .{ .chunk_id = document.id, .path = document.path, .start_line = document.start_line, .end_line = document.end_line, .content = document.text };
        }
        return null;
    }

    /// `list_sources` over the visible scope (owned by `allocator`).
    pub fn listSources(scoped: ScopedService, allocator: std.mem.Allocator, path_prefix: ?[]const u8, request: scope.Request) ![]Source {
        const resolved = try resolve(scoped.service, allocator, request);
        defer resolved.deinit(allocator);
        const documents = scoped.service.engine.documents;
        var list = std.ArrayList(Source).empty;
        var by_path = std.StringHashMapUnmanaged(usize).empty;
        defer by_path.deinit(allocator);
        for (documents, 0..) |document, index| {
            if (document.path.len == 0 or !resolved.documentVisible(documents, index)) continue;
            if (path_prefix) |prefix| if (!std.mem.startsWith(u8, document.path, prefix)) continue;
            const gop = try by_path.getOrPut(allocator, document.path);
            if (gop.found_existing) {
                list.items[gop.value_ptr.*].chunks += 1;
            } else {
                gop.value_ptr.* = list.items.len;
                try list.append(allocator, .{ .path = document.path, .chunks = 1 });
            }
        }
        const sources = try list.toOwnedSlice(allocator);
        sortSources(sources);
        return sources;
    }

    /// `list_files`: visible indexed files (with their chunk counts and
    /// chunker) and visible pending files, ordered by root then path.
    pub fn listFiles(scoped: ScopedService, allocator: std.mem.Allocator, request: scope.Request, root_id: ?[]const u8, path_prefix: ?[]const u8) ![]FileListing {
        const resolved = try resolve(scoped.service, allocator, request);
        defer resolved.deinit(allocator);
        const folder = resolved.folder;
        const engine = scoped.service.engine;
        var list = std.ArrayList(FileListing).empty;
        var by_path = std.StringHashMapUnmanaged(usize).empty;
        defer by_path.deinit(allocator);
        for (engine.documents, 0..) |document, index| {
            if (!resolved.documentVisible(engine.documents, index)) continue;
            const root = folder.roots[folder.document_roots[index]];
            const relative = scope.relativePath(root, document.path);
            if (root_id) |wanted| if (!std.mem.eql(u8, wanted, root.root_id)) continue;
            if (path_prefix) |prefix| if (!std.mem.startsWith(u8, relative, prefix)) continue;
            const gop = try by_path.getOrPut(allocator, document.path);
            if (gop.found_existing) {
                list.items[gop.value_ptr.*].chunks += 1;
            } else {
                gop.value_ptr.* = list.items.len;
                const chunker_id: ?[]const u8 = if (document.chunker_index < folder.chunkers.len) folder.chunkers[document.chunker_index].id else if (folder.chunkers.len == 0) "line-window-v1" else null;
                try list.append(allocator, .{ .root_id = root.root_id, .path = relative, .status = "indexed", .chunks = 1, .chunker = chunker_id });
            }
        }
        for (folder.unchunked) |entry| {
            if (!resolved.listedVisible(entry)) continue;
            if (root_id) |wanted| if (!std.mem.eql(u8, wanted, entry.root_id)) continue;
            if (path_prefix) |prefix| if (!std.mem.startsWith(u8, entry.path, prefix)) continue;
            try list.append(allocator, .{ .root_id = entry.root_id, .path = entry.path, .status = "indexed", .chunks = 0, .chunker = null });
        }
        for (folder.pending) |entry| {
            if (!resolved.listedVisible(entry)) continue;
            if (root_id) |wanted| if (!std.mem.eql(u8, wanted, entry.root_id)) continue;
            if (path_prefix) |prefix| if (!std.mem.startsWith(u8, entry.path, prefix)) continue;
            try list.append(allocator, .{ .root_id = entry.root_id, .path = entry.path, .status = "pending", .chunks = 0, .chunker = null });
        }
        const files = try list.toOwnedSlice(allocator);
        std.mem.sort(FileListing, files, {}, lessThanFileListing);
        return files;
    }

    /// `index_status` over the visible scope (`ScopedStatus`).
    pub fn indexStatus(scoped: ScopedService, allocator: std.mem.Allocator, request: scope.Request) !ScopedStatus {
        const resolved = try resolve(scoped.service, allocator, request);
        defer resolved.deinit(allocator);
        const folder = resolved.folder;
        const engine = scoped.service.engine;
        const index = engine.lexical_index;
        const mask = resolved.mask();

        const roots = try allocator.alloc(RootStatus, folder.roots.len);
        var root_count: usize = 0;
        const root_slot = try allocator.alloc(?usize, folder.roots.len);
        defer allocator.free(root_slot);
        for (folder.roots, resolved.allowed, root_slot) |root, allowed, *slot| {
            slot.* = null;
            if (!allowed) continue;
            slot.* = root_count;
            roots[root_count] = .{ .root_id = root.root_id, .label = root.label, .kind = root.kind, .files = 0, .documents = 0, .pending = 0 };
            root_count += 1;
        }

        var documents: usize = 0;
        // S4-T1: whether visible files have retained bytes, from the
        // records and the roots' retention, without reading the source
        // section; a section known to be lost or damaged retains nothing.
        const source_state = folder.sourceState();
        const source_readable = folder.source_bound and source_state != .unavailable;
        var has_source = false;
        var uses_chunker = [_]bool{ false, false };
        var seen = std.StringHashMapUnmanaged(void).empty;
        defer seen.deinit(allocator);
        for (engine.documents, 0..) |document, i| {
            if (!resolved.documentVisible(engine.documents, i)) continue;
            documents += 1;
            const slot = root_slot[folder.document_roots[i]].?;
            roots[slot].documents += 1;
            if (document.source_doc_index != hybrid.no_source_doc and source_readable) has_source = true;
            const chunker_id = if (document.chunker_index < folder.chunkers.len) folder.chunkers[document.chunker_index].id else "line-window-v1";
            if (std.mem.eql(u8, chunker_id, "md-section-v1")) uses_chunker[1] = true else uses_chunker[0] = true;
            const gop = try seen.getOrPut(allocator, document.path);
            if (!gop.found_existing) roots[slot].files += 1;
        }
        var files = seen.count();
        for (folder.unchunked) |entry| {
            if (!resolved.listedVisible(entry)) continue;
            files += 1;
            const root_index = folder.rootIndex(entry.root_id).?;
            roots[root_slot[root_index].?].files += 1;
            if (source_readable and folder.roots[root_index].retain_source) has_source = true;
        }
        var pending_paths = std.ArrayList(FileRef).empty;
        for (folder.pending) |entry| {
            if (!resolved.listedVisible(entry)) continue;
            roots[root_slot[folder.rootIndex(entry.root_id).?].?].pending += 1;
            try pending_paths.append(allocator, .{ .root_id = entry.root_id, .path = entry.path });
        }

        // Terms and postings in the visible scope.
        var terms: usize = 0;
        var posting_count: usize = 0;
        var view = try scope.visibleCollection(allocator, index, engine.documents, engine.statistics orelse folder.loadedStatistics(), engine.labeled_documents, mask, resolved.labels);
        if (view) |*v| {
            defer v.deinit(allocator);
            for (index.terms, 0..) |entry, term_index| {
                _ = term_index;
                const frequency = scope.documentFrequency(v.*, index, engine.documents, entry);
                if (frequency != 0) terms += 1;
                posting_count += frequency;
            }
        } else {
            terms = index.terms.len;
            posting_count = index.postings.len;
        }

        var chunkers = std.ArrayList([]const u8).empty;
        if (uses_chunker[0]) try chunkers.append(allocator, "line-window-v1");
        if (uses_chunker[1]) try chunkers.append(allocator, "md-section-v1");
        return .{
            .ready = true,
            .generation = engine.generation,
            .analyzer_id = engine.analyzer_id,
            .embedding_model_id = engine.embedding_model_id,
            .vector_dimensions = engine.vector_dimensions,
            .documents = documents,
            .terms = terms,
            .postings = posting_count,
            .files = files,
            .pending = pending_paths.items.len,
            .truncated = try anySkippedVisible(resolved),
            .roots = roots[0..root_count],
            .pending_paths = try pending_paths.toOwnedSlice(allocator),
            .has_source = has_source,
            .has_positions = folder.has_positions,
            .chunkers = try chunkers.toOwnedSlice(allocator),
            .source = source_state.label(),
        };
    }

    /// Whether the root-relative file `path` of root `root_id` is visible to
    /// the request; its record path when it is.
    fn visibleFile(scoped: ScopedService, allocator: std.mem.Allocator, resolved: Resolved, root_id: []const u8, path: []const u8) !?[]const u8 {
        if (!resolved.rootVisible(root_id)) return null;
        const record = try scope.recordPath(allocator, root_id, path);
        const documents = scoped.service.engine.documents;
        for (documents, 0..) |document, index| {
            if (std.mem.eql(u8, document.path, record)) {
                if (resolved.documentVisible(documents, index)) return record;
                return null;
            }
        }
        for (resolved.folder.unchunked) |entry| {
            if (std.mem.eql(u8, entry.root_id, root_id) and std.mem.eql(u8, entry.path, path)) {
                return if (resolved.listedVisible(entry)) record else null;
            }
        }
        return null;
    }

    /// `read_span` gated by the scope: a hidden file answers exactly what an
    /// absent one does (`not_found`, the same message).
    pub fn readSpan(scoped: ScopedService, allocator: std.mem.Allocator, request: scope.Request, root_id: []const u8, path: []const u8, start_line: u32, end_line: u32, context_lines: u32) !source_section.SpanResult {
        const resolved = try resolve(scoped.service, allocator, request);
        defer resolved.deinit(allocator);
        const section = try resolved.folder.sourceSection();
        if (section == null) return .{ .failed = try sourceUnavailable(allocator, resolved.folder.*) };
        const record = (try scoped.visibleFile(allocator, resolved, root_id, path)) orelse {
            const shown = try scope.recordPath(allocator, root_id, path);
            return .{ .failed = .{ .code = .not_found, .message = try std.fmt.allocPrint(allocator, "not indexed or not retained: {s}", .{shown}) } };
        };
        return source_section.readSpan(allocator, section, record, start_line, end_line, context_lines);
    }

    /// `find` (S3-T2) over the request's scope: roots and labels filter
    /// before candidates and bound prefix expansion, BM25 uses the visible
    /// scope's statistics, and the answer's `pending_files` and `truncated`
    /// count the scope's pending files and say whether a visible file was
    /// given but not indexed in full (too large, unreadable, over budget).
    pub fn find(scoped: ScopedService, allocator: std.mem.Allocator, request: find_module.Request, scope_request: scope.Request) !find_module.Outcome {
        const resolved = try resolve(scoped.service, allocator, scope_request);
        defer resolved.deinit(allocator);
        const folder = resolved.folder;
        // S4-T1: the statistics groups and the position tables (with the
        // validation of the positions and offsets) load at the first find.
        var engine = scoped.service.engine;
        if (engine.statistics == null) engine.statistics = try folder.statistics();
        if (engine.position_tables == null) engine.position_tables = try folder.positionTables();
        var scoped_request = request;
        scoped_request.principal_labels = scope_request.principal_labels;
        scoped_request.visible_roots = resolved.mask();
        // `find.splitRoot` gives unprefixed paths to the first id: the legacy root.
        var ids = std.ArrayList([]const u8).empty;
        for (folder.roots) |root| if (scope.isLegacy(root.root_id)) try ids.append(allocator, root.root_id);
        for (folder.roots) |root| if (!scope.isLegacy(root.root_id)) try ids.append(allocator, root.root_id);
        if (ids.items.len != 0) scoped_request.root_ids = ids.items;
        var view = try scope.visibleCollection(allocator, engine.lexical_index, engine.documents, engine.statistics, engine.labeled_documents, resolved.mask(), resolved.labels);
        defer if (view) |*v| v.deinit(allocator);
        const provider = try allocator.create(FrequencyProvider);
        if (view) |v| {
            provider.* = .{ .view = v, .engine = engine };
            scoped_request.statistics = .{
                .document_count = v.collection.document_count,
                .average_document_length = v.collection.average_document_length,
                .context = provider,
                .document_frequency_fn = FrequencyProvider.frequency,
            };
        }
        const complete = try completenessOf(resolved);
        scoped_request.pending_files = complete.pending_files;
        scoped_request.truncated = complete.truncated;
        return find_module.find(allocator, engine, scoped_request);
    }

    /// S3-T6: `find`'s `pending_files` and `truncated` for any operation over
    /// the request's scope (`search_knowledge` carries them since S3-T6).
    pub fn completeness(scoped: ScopedService, allocator: std.mem.Allocator, request: scope.Request) !Completeness {
        const resolved = try resolve(scoped.service, allocator, request);
        defer resolved.deinit(allocator);
        return completenessOf(resolved);
    }

    /// `outline` gated by the scope, like `readSpan`.
    pub fn outline(scoped: ScopedService, allocator: std.mem.Allocator, request: scope.Request, root_id: []const u8, path: []const u8) !source_section.OutlineResult {
        const resolved = try resolve(scoped.service, allocator, request);
        defer resolved.deinit(allocator);
        const section = try resolved.folder.sourceSection();
        if (section == null) return .{ .failed = try sourceUnavailable(allocator, resolved.folder.*) };
        const record = (try scoped.visibleFile(allocator, resolved, root_id, path)) orelse {
            const shown = try scope.recordPath(allocator, root_id, path);
            return .{ .failed = .{ .code = .not_found, .message = try std.fmt.allocPrint(allocator, "not indexed or not retained: {s}", .{shown}) } };
        };
        return source_section.outline(allocator, section, record);
    }
};

const FrequencyProvider = struct {
    view: scope.View,
    engine: engine_module.Engine,

    fn frequency(context: ?*const anyopaque, term_index: usize, global: u32) u32 {
        _ = global;
        const self: *const FrequencyProvider = @ptrCast(@alignCast(context.?));
        const index = self.engine.lexical_index;
        return scope.documentFrequency(self.view, index, self.engine.documents, index.terms[term_index]);
    }
};

/// S3-T4: why `read_span`/`outline` cannot answer from this generation:
/// it retains no source bytes, or (S3-T1 finding 2) it binds a source
/// section that could not be opened. Both are `CAPACITY`; a hidden or
/// unknown file in such a generation gets the same answer, so it reveals
/// nothing.
pub fn sourceUnavailable(allocator: std.mem.Allocator, folder: scope.Folder) !source_section.Failure {
    if (folder.sourceError()) |name| return .{ .code = .capacity, .message = try std.fmt.allocPrint(allocator, "re-index required: source section unavailable ({s})", .{name}) };
    return .{ .code = .capacity, .message = source_section.source_absent_message };
}

/// How complete the visible scope is: its pending files, and whether a
/// visible file was given but not indexed in full (section 7).
pub const Completeness = struct { pending_files: usize, truncated: bool };

fn completenessOf(resolved: Resolved) !Completeness {
    var pending: usize = 0;
    for (resolved.folder.pending) |entry| if (resolved.listedVisible(entry)) {
        pending += 1;
    };
    return .{ .pending_files = pending, .truncated = try anySkippedVisible(resolved) };
}

fn anySkippedVisible(resolved: Resolved) !bool {
    for (resolved.folder.skipped) |entry| if (resolved.listedVisible(entry)) return true;
    return false;
}

/// The section 8 `index_status` additions as JSON.
pub fn writeScopedStatusJson(json: *std.json.Stringify, status: ScopedStatus) !void {
    try json.beginObject();
    inline for (.{ "ready", "generation", "analyzer_id", "embedding_model_id", "vector_dimensions", "documents", "terms", "postings", "files", "pending", "truncated" }) |name| {
        try json.objectField(name);
        try json.write(@field(status, name));
    }
    try json.objectField("roots");
    try json.beginArray();
    for (status.roots) |root| try json.write(root);
    try json.endArray();
    try json.objectField("pending_paths");
    try json.beginArray();
    for (status.pending_paths) |ref| try json.write(ref);
    try json.endArray();
    try json.objectField("has_source");
    try json.write(status.has_source);
    try json.objectField("has_positions");
    try json.write(status.has_positions);
    try json.objectField("chunkers");
    try json.write(status.chunkers);
    try json.objectField("source");
    try json.write(status.source);
    try json.endObject();
}

/// `list_files` as JSON (`{"files":[…],"next_cursor":null}`; paging is S3-T4's).
pub fn writeFilesJson(json: *std.json.Stringify, files: []const FileListing) !void {
    try json.beginObject();
    try json.objectField("files");
    try json.beginArray();
    for (files) |file| try json.write(file);
    try json.endArray();
    try json.objectField("next_cursor");
    try json.write(null);
    try json.endObject();
}

fn sortSources(sources: []Source) void {
    var index: usize = 1;
    while (index < sources.len) : (index += 1) {
        const value = sources[index];
        var insertion = index;
        while (insertion > 0 and std.mem.order(u8, value.path, sources[insertion - 1].path) == .lt) : (insertion -= 1) {
            sources[insertion] = sources[insertion - 1];
        }
        sources[insertion] = value;
    }
}

test "service exposes scoped search read list and status operations" {
    const documents = [_]hybrid.Document{
        .{ .id = "public-lexical", .text = "exact search phrase", .vector = &.{ 0, 1 }, .path = "public/a.md", .start_line = 1, .end_line = 2 },
        .{ .id = "public-vector", .text = "different wording", .vector = &.{ 1, 0 }, .path = "public/b.md", .start_line = 3, .end_line = 4 },
        .{ .id = "private", .text = "exact search phrase private", .vector = &.{ 1, 0 }, .path = "private/secret.md", .start_line = 1, .end_line = 1 },
    };
    var terms: [16]@import("postings.zig").TermEntry = undefined;
    var posting_storage: [24]@import("postings.zig").Posting = undefined;
    var lengths: [documents.len]u32 = undefined;
    var fills: [16]usize = undefined;
    const lexical_index = try @import("postings.zig").build(&documents, &terms, &posting_storage, &lengths, &fills);
    const service = Service{ .engine = .{
        .generation = 3,
        .analyzer_id = "ascii-alnum-v1",
        .embedding_model_id = "manual-v1",
        .vector_dimensions = 2,
        .documents = &documents,
        .lexical_index = lexical_index,
    } };

    var result_storage: [documents.len]hybrid.Result = undefined;
    var evidence_storage: [documents.len]engine_module.Evidence = undefined;
    const lexical = try service.searchKnowledge(std.testing.allocator, "exact search", &.{ 1, 0 }, .{
        .path_prefix = "public/",
        .retrieval_mode = .lexical,
    }, &result_storage, &evidence_storage);
    try std.testing.expectEqualStrings("public-lexical", lexical[0].chunk_id);
    for (lexical) |evidence| try std.testing.expect(std.mem.startsWith(u8, evidence.path, "public/"));

    const vector = try service.searchKnowledge(std.testing.allocator, "exact search", &.{ 1, 0 }, .{
        .path_prefix = "public/",
        .retrieval_mode = .vector,
    }, &result_storage, &evidence_storage);
    try std.testing.expectEqualStrings("public-vector", vector[0].chunk_id);

    try std.testing.expect(service.readChunk("private", "public/", &.{}) == null);
    const read = service.readChunk("public-lexical", "public/", &.{}).?;
    try std.testing.expectEqualStrings("public/a.md", read.path);

    var source_storage: [3]Source = undefined;
    const sources = try service.listSources("public/", &.{}, &source_storage);
    try std.testing.expectEqual(@as(usize, 2), sources.len);
    try std.testing.expectEqualStrings("public/a.md", sources[0].path);
    try std.testing.expectEqualStrings("public/b.md", sources[1].path);

    const status = service.indexStatus();
    try std.testing.expect(status.ready);
    try std.testing.expectEqual(@as(u64, 3), status.generation);
    try std.testing.expectEqual(@as(usize, 3), status.documents);
    try std.testing.expectEqual(@as(usize, 2), status.vector_dimensions);
}

test "service reports evidence and source capacity errors" {
    const document = [_]hybrid.Document{.{ .id = "one", .text = "search", .path = "one.md", .start_line = 1, .end_line = 1 }};
    var terms: [2]@import("postings.zig").TermEntry = undefined;
    var posting_storage: [2]@import("postings.zig").Posting = undefined;
    var lengths: [1]u32 = undefined;
    var fills: [2]usize = undefined;
    const index = try @import("postings.zig").build(&document, &terms, &posting_storage, &lengths, &fills);
    const service = Service{ .engine = .{
        .generation = 1,
        .analyzer_id = "ascii-v1",
        .embedding_model_id = "none",
        .vector_dimensions = 0,
        .documents = &document,
        .lexical_index = index,
    } };
    var results: [1]hybrid.Result = undefined;
    var no_evidence: [0]engine_module.Evidence = .{};
    try std.testing.expectError(error.EvidenceCapacityTooSmall, service.searchKnowledge(std.testing.allocator, "search", &.{}, .{}, &results, &no_evidence));
    var no_sources: [0]Source = .{};
    try std.testing.expectError(error.SourceCapacityTooSmall, service.listSources(null, &.{}, &no_sources));
}

test "service applies required labels to search read and source listing" {
    const documents = [_]hybrid.Document{
        .{ .id = "public", .text = "launch guide", .path = "public.md", .start_line = 1, .end_line = 1 },
        .{ .id = "private", .text = "confidential launch", .path = "private.md", .start_line = 1, .end_line = 1, .required_labels = "tenant:acme" },
    };
    var terms: [8]@import("postings.zig").TermEntry = undefined;
    var posting_storage: [8]@import("postings.zig").Posting = undefined;
    var lengths: [documents.len]u32 = undefined;
    var fills: [8]usize = undefined;
    const index = try @import("postings.zig").build(&documents, &terms, &posting_storage, &lengths, &fills);
    const service = Service{ .engine = .{
        .generation = 1,
        .analyzer_id = "ascii-v1",
        .embedding_model_id = "none",
        .vector_dimensions = 0,
        .documents = &documents,
        .lexical_index = index,
    } };
    var results: [documents.len]hybrid.Result = undefined;
    var evidence: [documents.len]engine_module.Evidence = undefined;
    const anonymous = try service.searchKnowledge(std.testing.allocator, "confidential launch", &.{}, .{}, &results, &evidence);
    try std.testing.expectEqual(@as(usize, 1), anonymous.len);
    try std.testing.expectEqualStrings("public", anonymous[0].chunk_id);
    const tenant = try service.searchKnowledge(std.testing.allocator, "confidential launch", &.{}, .{
        .principal_labels = &.{"tenant:acme"},
    }, &results, &evidence);
    try std.testing.expectEqualStrings("private", tenant[0].chunk_id);
    try std.testing.expect(service.readChunk("private", null, &.{}) == null);
    try std.testing.expect(service.readChunk("private", null, &.{"tenant:acme"}) != null);
    var sources_storage: [documents.len]Source = undefined;
    const anonymous_sources = try service.listSources(null, &.{}, &sources_storage);
    try std.testing.expectEqual(@as(usize, 1), anonymous_sources.len);
    const tenant_sources = try service.listSources(null, &.{"tenant:acme"}, &sources_storage);
    try std.testing.expectEqual(@as(usize, 2), tenant_sources.len);
}

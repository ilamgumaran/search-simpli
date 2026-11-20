//! The core layer as one module, `core` (S6-T14; docs/layers.md). zig/build.zig
//! builds zig/src/core/ as this module. Operations, interfaces and the tests in
//! zig/src/tests/ reach a core file as `@import("core").<file name>`, never by a
//! path into core/. Every core file but fastmem.zig (an object of its own in
//! zig/build.zig) and the core tests that another folder names.

pub const analysis = @import("analysis.zig");
pub const analyzer_v2 = @import("analyzer_v2.zig");
pub const apply = @import("apply.zig");
pub const benchmark = @import("benchmark.zig");
pub const bm25_conformance_test = @import("bm25_conformance_test.zig");
pub const both_view_test = @import("both_view_test.zig");
pub const checksum = @import("checksum.zig");
pub const chunker = @import("chunker.zig");
pub const chunker_md = @import("chunker_md.zig");
pub const chunker_md_test = @import("chunker_md_test.zig");
pub const chunker_test = @import("chunker_test.zig");
pub const engine = @import("engine.zig");
pub const filename_complexity_test = @import("filename_complexity_test.zig");
pub const filename_field = @import("filename_field.zig");
pub const filename_field_test = @import("filename_field_test.zig");
pub const find = @import("find.zig");
pub const find_fixture_test = @import("find_fixture_test.zig");
pub const fold = @import("fold.zig");
pub const fold_test = @import("fold_test.zig");
pub const fuzzy = @import("fuzzy.zig");
pub const generation_alloc = @import("generation_alloc.zig");
pub const hybrid = @import("hybrid.zig");
pub const import_analyzer_test = @import("import_analyzer_test.zig");
pub const import_build_timing_test = @import("import_build_timing_test.zig");
pub const importer = @import("importer.zig");
pub const incremental_indexing_test = @import("incremental_indexing_test.zig");
pub const incremental_state = @import("incremental_state.zig");
pub const indexer = @import("indexer.zig");
pub const lexical_build = @import("lexical_build.zig");
pub const lexical_segment = @import("lexical_segment.zig");
pub const lifecycle = @import("lifecycle.zig");
pub const manifest = @import("manifest.zig");
pub const manifest_inplace_test = @import("manifest_inplace_test.zig");
pub const manifest_read_test = @import("manifest_read_test.zig");
pub const nfc = @import("nfc.zig");
pub const nfc_timing_test = @import("nfc_timing_test.zig");
pub const postings = @import("postings.zig");
pub const publication = @import("publication.zig");
pub const scope = @import("scope.zig");
pub const scoring = @import("scoring.zig");
pub const segment = @import("segment.zig");
pub const segment_v5 = @import("segment_v5.zig");
pub const snapshot_open = @import("snapshot_open.zig");
pub const source = @import("source.zig");
pub const source_v2 = @import("source_v2.zig");
pub const state_section = @import("state_section.zig");
pub const title_field = @import("title_field.zig");
pub const unicode_tables = @import("unicode_tables.zig");
pub const verb_form_groups_test = @import("verb_form_groups_test.zig");
pub const verb_forms = @import("verb_forms.zig");
pub const verb_forms_test = @import("verb_forms_test.zig");

// `zig build test` runs this module's tests in a step of their own (zig/build.zig):
// a test build only collects the tests of its root module's files. The reference
// below is made in a test build only, and adds no test of its own.
comptime {
    if (@import("builtin").is_test) {
        _ = analysis;
        _ = analyzer_v2;
        _ = apply;
        _ = benchmark;
        _ = bm25_conformance_test;
        _ = both_view_test;
        _ = checksum;
        _ = chunker;
        _ = chunker_md;
        _ = chunker_md_test;
        _ = chunker_test;
        _ = engine;
        _ = filename_complexity_test;
        _ = filename_field;
        _ = filename_field_test;
        _ = find;
        _ = find_fixture_test;
        _ = fold;
        _ = fold_test;
        _ = fuzzy;
        _ = generation_alloc;
        _ = hybrid;
        _ = import_analyzer_test;
        _ = import_build_timing_test;
        _ = importer;
        _ = incremental_indexing_test;
        _ = incremental_state;
        _ = indexer;
        _ = lexical_build;
        _ = lexical_segment;
        _ = lifecycle;
        _ = manifest;
        _ = manifest_inplace_test;
        _ = manifest_read_test;
        _ = nfc;
        _ = nfc_timing_test;
        _ = postings;
        _ = publication;
        _ = scope;
        _ = scoring;
        _ = segment;
        _ = segment_v5;
        _ = snapshot_open;
        _ = source;
        _ = source_v2;
        _ = state_section;
        _ = title_field;
        _ = unicode_tables;
        _ = verb_form_groups_test;
        _ = verb_forms;
        _ = verb_forms_test;
    }
}

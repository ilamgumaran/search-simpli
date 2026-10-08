//! S2-T4: the additive tail of an `ss_query` report -- `warnings`, `request`
//! and (only on request) `profile`. They are appended after `answer_policy`,
//! so everything the report carried before is untouched and in the same
//! order; removing these three top-level keys gives the previous output.
//!
//! Emission per retrieval mode (terms are only used, and only warned about,
//! where the mode uses them):
//!
//! | code                         | lexical | hybrid | vector |
//! | ---------------------------- | ------- | ------ | ------ |
//! | `query_term_unmatched`       | yes     | yes    | no     |
//! | `query_empty_after_analysis` | yes     | yes    | no     |
//! | `vector_ignored`             | when a vector was passed | when passed and the snapshot has no vectors | same |
//! | `candidate_depth_cut`        | lexical list | each channel | semantic list |

const hybrid = @import("hybrid.zig");
const std = @import("std");

pub const Extras = struct {
    trace: *const hybrid.Trace,
    mode: hybrid.RetrievalMode,
    analyzer_id: []const u8,
    top_k: usize,
    candidate_k: usize,
    path_prefix: ?[]const u8,
    /// Set when the caller passed a query vector that was not used.
    vector_ignored: ?VectorIgnored = null,
    /// `trace.stamp` taken when serialization began (0 with profile off).
    serialize_start: u64 = 0,
};

pub const VectorIgnored = enum {
    lexical_mode,
    no_vectors_in_snapshot,

    fn message(reason: VectorIgnored) []const u8 {
        return switch (reason) {
            .lexical_mode => "the query vector was ignored: retrieval_mode is lexical",
            .no_vectors_in_snapshot => "the query vector was ignored: this snapshot stores no vectors",
        };
    }
};

fn warning(json: *std.json.Stringify, code: []const u8, message: []const u8, term: ?[]const u8) !void {
    try json.beginObject();
    try json.objectField("code");
    try json.write(code);
    try json.objectField("message");
    try json.write(message);
    if (term) |value| {
        try json.objectField("term");
        try json.write(value);
    }
    try json.endObject();
}

fn depthCut(json: *std.json.Stringify, channel: []const u8, offered: usize, extras: Extras) !void {
    const depth = extras.trace.depth;
    if (offered <= depth) return;
    var buffer: [160]u8 = undefined;
    const message = try std.fmt.bufPrint(&buffer, "candidate_k {d} kept {d} of {d} {s} candidates", .{ extras.candidate_k, depth, offered, channel });
    try warning(json, "candidate_depth_cut", message, null);
}

/// Write `warnings`, `request` and, if the trace profiles, `profile` as
/// further fields of the report object that `json` is inside.
pub fn write(json: *std.json.Stringify, extras: Extras) !void {
    const trace = extras.trace;
    try json.objectField("warnings");
    try json.beginArray();
    if (extras.mode != .vector) {
        if (trace.unique_terms == 0) {
            try warning(json, "query_empty_after_analysis", "the query has no searchable terms after analysis", null);
        }
        for (trace.unmatched.items) |item| {
            try warning(
                json,
                "query_term_unmatched",
                if (item.in_dictionary) "the term matches no chunk in the searched scope" else "the term matches no chunk",
                item.term,
            );
        }
    }
    if (extras.vector_ignored) |reason| try warning(json, "vector_ignored", reason.message(), null);
    if (extras.mode != .vector) try depthCut(json, "lexical", trace.lexical_candidates, extras);
    if (extras.mode != .lexical) try depthCut(json, "vector", trace.semantic_candidates, extras);
    try json.endArray();

    try json.objectField("request");
    try json.beginObject();
    try json.objectField("analyzer_id");
    try json.write(extras.analyzer_id);
    try json.objectField("retrieval_mode");
    try json.write(@tagName(extras.mode));
    try json.objectField("top_k");
    try json.write(extras.top_k);
    try json.objectField("candidate_k");
    try json.write(extras.candidate_k);
    try json.objectField("path_prefix");
    try json.write(extras.path_prefix);
    try json.endObject();

    if (trace.profile) {
        // `serialize_us` is the time to write everything before this field;
        // the profile cannot time its own serialization.
        const serialize_ns = hybrid.Trace.stamp(trace) - extras.serialize_start;
        try json.objectField("profile");
        try json.beginObject();
        try json.objectField("tokenize_us");
        try json.write(trace.tokenize_ns / 1000);
        try json.objectField("score_us");
        try json.write(trace.score_ns / 1000);
        try json.objectField("rank_us");
        try json.write(trace.rank_ns / 1000);
        try json.objectField("serialize_us");
        try json.write(serialize_ns / 1000);
        try json.objectField("matched_chunks");
        try json.write(trace.matched_chunks);
        try json.endObject();
    }
}

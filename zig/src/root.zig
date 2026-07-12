pub const analysis = @import("analysis.zig");
pub const scoring = @import("scoring.zig");
pub const hybrid = @import("hybrid.zig");
pub const segment = @import("segment.zig");
pub const postings = @import("postings.zig");
pub const lexical_segment = @import("lexical_segment.zig");
pub const manifest = @import("manifest.zig");
pub const publication = @import("publication.zig");
pub const lifecycle = @import("lifecycle.zig");
pub const engine = @import("engine.zig");
pub const service = @import("service.zig");
pub const rpc = @import("rpc.zig");
pub const importer = @import("importer.zig");
pub const benchmark = @import("benchmark.zig");

pub const Bm25Parameters = scoring.Bm25Parameters;
pub const bm25Contribution = scoring.bm25Contribution;
pub const cosineSimilarity = scoring.cosineSimilarity;
pub const reciprocalRankContribution = scoring.reciprocalRankContribution;

comptime {
    _ = analysis.TokenIterator;
    _ = scoring.cosineSimilarity;
    _ = hybrid.search;
    _ = segment.encode;
    _ = postings.build;
    _ = lexical_segment.encode;
    _ = manifest.encode;
    _ = publication.publish;
    _ = lifecycle.scan;
    _ = engine.Engine;
    _ = service.Service;
    _ = rpc.handleLine;
    _ = importer.importJson;
    _ = benchmark.run;
}

test "load every engine module test suite" {
    _ = analysis;
    _ = scoring;
    _ = hybrid;
    _ = segment;
    _ = postings;
    _ = lexical_segment;
    _ = manifest;
    _ = publication;
    _ = lifecycle;
    _ = engine;
    _ = service;
    _ = rpc;
    _ = importer;
    _ = benchmark;
}

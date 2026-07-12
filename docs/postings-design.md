# Inverted postings design

Status: allocation-free in-memory implementation in `zig/src/postings.zig`, with exact persistence in `zig/src/lexical_segment.zig`; compression and top-k pruning remain.

## Why postings replace document scans

The scan oracle asks every document how often each query term appears. That is easy to verify but its work grows with the entire corpus. An inverted index reverses the relationship:

```text
term -> [(document_index, term_frequency), ...]
```

A query now visits the dictionary terms it contains and only the postings for documents containing those terms. BM25 also needs document frequency, individual document length, average document length, and total document count; the index stores or derives each.

## Current build

The builder makes two passes over caller-supplied documents:

1. Analyze each document, collect first-seen unique terms, calculate document frequency and document lengths.
2. Assign a contiguous range to each term and fill postings with document index and term frequency.

All arrays belong to the caller. Capacity errors are explicit for terms, postings, lengths, and temporary fill counters. Term text borrows the original stored text, so the document/segment bytes must outlive the index.

## Current query

For each unique query term:

1. case-fold and look it up in the dictionary;
2. iterate only its postings;
3. calculate its BM25 contribution using stored corpus statistics;
4. add the contribution to that document’s score.

The resulting lexical score array is passed to the same hybrid fusion path used by the scan oracle. This prevents the optimized retrieval structure from silently changing rank semantics.

## Verified invariants

- repeated terms create one posting per document with the correct term frequency;
- document frequency and document length match the analyzer;
- postings-derived BM25 scores match scan-derived scores within floating-point tolerance;
- hybrid ids, lexical ranks, semantic ranks, and fused scores match the scan oracle;
- decoding a binary segment, rebuilding postings, and querying still preserves those results.

## Known limits and next form

The dictionary is currently a linear first-seen array. Building still uses repeated scans to suppress duplicate terms. This is acceptable as a correctness oracle but not as the final indexing algorithm.

The `HYBLEX01` format now persists document lengths, dictionary terms/ranges, and fixed-width postings with versioning and a metadata-plus-payload checksum. It round-trips through the same `postings.Index` view and golden scoring tests.

The next optimized version should add:

- lexicographically sorted term bytes plus offsets, or an FST after measurement;
- contiguous posting blocks encoded as document-id gaps and term frequencies;
- per-block maximum score metadata for safe top-k pruning;
- optional positions only for phrase/proximity features;
- an atomic manifest binding lexical and document/vector section checksums;
- tokenizer/analyzer version in segment metadata;
- tombstone/update semantics across immutable segment generations.

Compression and WAND-style pruning must be benchmarked against the uncompressed exact implementation. They are optimizations, not changes to relevance truth.

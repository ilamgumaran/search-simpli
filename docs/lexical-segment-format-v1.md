# Immutable lexical segment format v1

Status: implemented and fully round-trip tested in `zig/src/lexical_segment.zig`.

Magic: `HYBLEX01`. All integers and `f32` bit patterns are little-endian. The section persists the exact information required for BM25 without re-tokenizing stored document text after restart.

## Header

| Offset | Size | Field | Meaning |
|---:|---:|---|---|
| 0 | 8 | magic | ASCII `HYBLEX01` |
| 8 | 2 | version | format version, currently `1` |
| 10 | 2 | flags | reserved; nonzero is rejected |
| 12 | 4 | document count | number of indexed chunks |
| 16 | 4 | term count | dictionary entries |
| 20 | 8 | posting count | total term/document pairs |
| 28 | 4 | average document length | IEEE-754 `f32` bits |
| 32 | 8 | document-length bytes | size of the first payload section |
| 40 | 8 | dictionary bytes | size of the second payload section |
| 48 | 8 | postings bytes | size of the third payload section |
| 56 | 8 | checksum | FNV-1a over header bytes 0–55 followed by all payload bytes |

The 64-byte fixed header makes section boundaries available before payload parsing. Counts, byte lengths, and average length are covered by the checksum.

## Section 1: document lengths

One unsigned 32-bit token count per document, in document-index order. Its byte length must equal `document_count * 4`.

## Section 2: term dictionary

Each term record is a 24-byte fixed prefix followed by term bytes:

| Size | Field |
|---:|---|
| 4 | term byte length |
| 4 | document frequency |
| 8 | posting start index |
| 8 | posting count for this term |
| variable | term bytes borrowed by the decoded dictionary |

Terms are currently stored in first-seen order. The decoder rejects empty or case-insensitive duplicate terms, ranges outside the posting section, and disagreement between document frequency and posting count.

## Section 3: postings

Each fixed eight-byte posting contains:

| Size | Field |
|---:|---|
| 4 | document index |
| 4 | term frequency |

Within each term range, document indexes must be strictly increasing. Document indexes outside the declared corpus and zero term frequencies are rejected.

## Decode ownership

- Term bytes are zero-copy slices into the encoded section.
- Term-entry structs, posting structs, and document lengths are decoded into caller-owned aligned arrays.
- The returned `postings.Index` borrows all four lifetimes, making capacity and ownership visible.

## Validation order

The reader validates magic/version/flags and declared total size, then verifies the metadata-plus-payload checksum before trusting count-derived section invariants. This order was chosen after a corruption test initially returned `InvalidSectionLength` before noticing that the header checksum had changed.

## Golden invariants

Tests establish that:

- persisted and in-memory postings produce identical BM25 scores within `0.000001`;
- persisted lexical scores preserve final hybrid ids, component ranks, and fused scores;
- metadata and payload corruption are detected;
- insufficient caller workspaces are explicit errors;
- inconsistent document frequency and duplicate document postings are rejected.

## Deliberate limitations

V1 is exact and uncompressed. It does not yet use sorted-term binary search/FSTs, document-id gap encoding, variable integers, block maxima, skip data, positions, tombstones, or cryptographic authentication. It is a durable correctness baseline for measuring those later changes.

The lexical section and document/vector section are still independent byte blobs. An atomic manifest must bind their filenames, checksums, shared document count, analyzer version, embedding model, and generation before they constitute a crash-safe published snapshot.

# Immutable lexical segment format v2 (`HYBLEX02`)

Status: implemented by S3-T2 in `zig/src/lexical_segment.zig` (reader and
writer), `zig/src/lexical_build.zig` (`buildPositional`) and
`zig/src/postings.zig` (varints, position tables). Written by `searchd index`
(full and `--update`); `import-json` keeps writing `HYBLEX01` under its v1
manifest. Companion to [`lexical-segment-format-v1.md`](lexical-segment-format-v1.md)
and [`folder-knowledge-implementation.md`](folder-knowledge-implementation.md) §3.

V2 keeps v1's three sections and its validation, sorts the dictionary, and adds
two sections: the token ordinals of every posting (phrase adjacency) and the
codepoint offsets of every token (highlighting). All integers are
little-endian; varints are unsigned LEB128.

## Header (80 bytes)

| Offset | Size | Field | Meaning |
|---:|---:|---|---|
| 0 | 8 | magic | ASCII `HYBLEX02` |
| 8 | 2 | version | `2` |
| 10 | 2 | flags | bit 0: XXH3-64 checksum (S4-T1); other bits rejected |
| 12 | 4 | document count | as v1 |
| 16 | 4 | term count | as v1 |
| 20 | 8 | posting count | as v1 |
| 28 | 4 | average document length | IEEE-754 `f32` bits, as v1 |
| 32 | 8 | document-length bytes | section 1 |
| 40 | 8 | dictionary bytes | section 2 |
| 48 | 8 | postings bytes | section 3 |
| 56 | 8 | positions bytes | section 4 |
| 64 | 8 | offsets bytes | section 5 |
| 72 | 8 | checksum | FNV-1a 64, or XXH3-64 when flags bit 0 is set, over header bytes 0–71 followed by all payload bytes |

The reader accepts both magics: `HYBLEX01` (64-byte header, sections 1–3) and
`HYBLEX02`. As in v1 it checks magic, version, flags and the declared total
size, then the checksum, before any count-derived rule.

### Flags bit 0: XXH3-64 (S4-T1)

Since S4-T1 every `HYBLEX02` writer sets bit 0 and checksums with XXH3-64
(seed 0) instead of FNV-1a 64, the same bytes covered; the binding manifest
sets `xxh3_sections` ([manifest v2.1](manifest-format-v2.md#v21-xxh3-section-checksums-s4-t1)).
`HYBLEX02` sections written before S4-T1 (flags zero) read as before.
`HYBLEX01` keeps flags zero and FNV-1a; a nonzero `HYBLEX01` flag is rejected.

## Sections 1–3

Byte for byte the v1 layouts (document lengths; 24-byte term records plus
term bytes; 8-byte postings), with two v2 rules:

- **Sorted dictionary.** Terms are strictly increasing by bytes
  (`std.mem.order`), which also rules out duplicates, so the v2 reader needs
  no hash set. Lookups binary-search; a prefix is one contiguous range.
- **Contiguous term ranges.** Term *i*'s postings start where term *i − 1*'s
  end (the first at 0) and the last ends at the posting count, so postings
  are term-major in dictionary order and a term's ordinals are one run of
  section 4.

Term bytes stay zero-copy slices into the encoded section. Sorting changes no
score: postings, document frequencies, document lengths and the average length
equal v1's for the same chunks (`buildPositional` versus `build`, tested), and
BM25 sums over query terms in query order, not dictionary order.

## Section 4: positions

For each posting in posting order: `term_frequency` varints, the term's token
ordinals in that document (0-based index in the document's token sequence),
delta-coded: the first absolute, every later one a gap ≥ 1. Every ordinal is
below the document's length. No byte is left over.

## Section 5: offsets

For each document in document order: a `u32` token count, equal to the
document's length, then per token two varints: the start as a delta from the
previous token's start (the first from 0) and the length (≥ 1). Both count
Unicode codepoints of the chunk's stored text (the document record's `text`,
which is what a hit's `content` is). Starts never decrease; every end fits a
`u32`. No byte is left over.

Offsets point into the **original** chunk text, not its NFC form. The analyzer
normalizes before tokenizing; the writer maps every normalized codepoint back
with `nfc.MappedIterator`: NFC works on regions (an inert codepoint, ASCII or
a precomposed Hangul syllable, before a run of non-inert ones), and a region
NFC leaves unchanged maps one to one, while a region NFC changes maps every
output codepoint to the whole region (so `e` + U+0301 is one token codepoint
covering two text codepoints). A token's range is the smallest range covering
its codepoints. Variation selectors are dropped before tokenizing, as before.

## Reading

`decode` validates sections 4 and 5 completely (every rule above) without
allocating, and returns them as byte slices in `postings.Index.positions`,
with `sorted_terms` true. `postings.buildPositionTables` (run once by
`snapshot_open.open`) records where each term's ordinals and each document's
offset table begin, one `usize` per term and per document, so a query reads
only its own terms' ordinals and its hits' offsets.

## Manifest binding

A v2 manifest (`HYBMAN02`) sets flag bit 1 `has_positions` exactly when its
lexical section is `HYBLEX02`; `manifest.validateSnapshot` refuses a mismatch,
and a v1 manifest cannot bind a `HYBLEX02` section (`manifest.create` refuses
it). A generation without positions answers `find` `phrase` with `CAPACITY`
`"re-index required: positions absent"`; `words` and `prefix` still work and
their highlights are recomputed by re-tokenizing the hit's text.

## `--update`

Unchanged documents are carried with their exact token sequence and spans,
read back from the previous `HYBLEX02` section (`lexical_build.reconstructPositioned`),
not re-analyzed; a previous `HYBLEX01` generation is re-tokenized once, which
upgrades it. A test checks that an update writes sections 4 and 5 byte for
byte as a full rebuild of the same folder.

## Size (S3-T2, measured)

On the 10k-file benchmark corpus (19,959 chunks) the section is 12,487,753
bytes against `HYBLEX01`'s 9,000,597 (1.39×; CAP-19 NFR-11 allows 2.5×):
section 4 is 1,135,768 bytes for 1,135,768 tokens (one byte per token, 1.11
per posting), section 5 2,351,372 (four bytes per chunk plus exactly two per
token). Full tables: [`scale-benchmark.md`](scale-benchmark.md)
and `docs/tasks/S3-T2.md`.

## Deliberate limitations

Positions are per chunk (CAP-19 open decision 1): a phrase that only exists
across a chunk boundary is not found. No skip data or block maxima; a phrase
query walks each query term's run of section 4 once.

# Generation manifest format v2

Status: implemented in `zig/src/manifest.zig` (S3-T1). Magic: `HYBMAN02`.
Written by `searchd index` / `ss_index_folder` (`zig/src/indexer.zig`).
`import-json` still writes [v1](manifest-format-v1.md), and every reader opens
both. Design: [`folder-knowledge-implementation.md`](folder-knowledge-implementation.md) §1.

The manifest stays the single atomic visibility point of a generation. v2 adds
a third bound section, the [source section](source-section-v1.md), two flags,
and a `meta` JSON object that names the chunkers and roots that produced the
generation (CAP-19 FR-18, CFT-09).

## Header (104 bytes, little-endian)

| Offset | Size | Field | Since |
|---:|---:|---|---|
| 0 | 8 | magic `HYBMAN02` | v2 (v1: `HYBMAN01`) |
| 8 | 2 | version `2` | |
| 10 | 2 | flags: bit 0 `has_source`, bit 1 `has_positions`; other bits must be zero | v2 (v1: zero) |
| 12 | 8 | generation number (nonzero) | v1 |
| 20 | 4 | shared document count | v1 |
| 24 | 4 | vector dimensions | v1 |
| 28 | 4 | lexical term count | v1 |
| 32 | 4 | source section count, `0` or `1` | v2 (v1: reserved) |
| 36 | 8 | posting count | v1 |
| 44 | 8 | document section byte length | v1 |
| 52 | 8 | document section internal checksum | v1 |
| 60 | 8 | lexical section byte length | v1 |
| 68 | 8 | lexical section internal checksum | v1 |
| 76 | 8 | source section byte length (`0` without one) | v2 |
| 84 | 8 | source section internal checksum (`0` without one) | v2 |
| 92 | 4 | variable payload byte length | v1 at 76 |
| 96 | 8 | manifest checksum | v1 at 80 |

Offsets 0–75 have the v1 meaning. The manifest checksum is FNV-1a over header
bytes 0–95 followed by the payload: accidental-corruption detection, not
authentication. It covers every new field, so a flipped flag, count, length,
source checksum, filename or `meta` byte fails to decode.

`has_source`, the source count and a non-empty source filename must agree; a
generation without a source section has length and checksum zero.
`has_positions` is reserved for `HYBLEX02` (S3-T2) and is always written false
by S3-T1.

## Payload

Six length-prefixed byte strings (u32 length + bytes), in order:

1. analyzer id;
2. embedding model id, or `none`;
3. document section filename (`documents-N.hybseg`);
4. lexical section filename (`lexical-N.hyblex`);
5. source section filename (`source-N.hybsrc`), or empty;
6. `meta`: a UTF-8 JSON object, no NUL bytes.

Identifiers and filenames follow v1's rules; the three filenames must differ.

`meta`, as `searchd index` writes it (keys in this order):

```json
{"manifest_meta":2,
 "chunkers":[{"id":"line-window-v1","params":{"max_chars":1600,"overlap_lines":3}},
             {"id":"md-section-v1","params":{"max_chars":1600,"overlap_lines":3,"front_matter":"yaml-v1"}}],
 "roots":[{"root_id":"r-legacy","label":"folder","kind":"local","required_labels":[],"retain_source":true}],
 "source_section_version":1}
```

- `chunkers`: `line-window-v1` is always entry 0; `md-section-v1` is entry 1
  when any chunk of the generation was made by it. A document record's
  `chunker_index` ([segment v4](segment-format-v4.md)) indexes this array.
- `roots`: S3-T1 writes the one root `r-legacy` for a folder index; S3-T3 adds
  host and iCloud roots.
- `source_section_version`: `1` when a source section is bound, else `0`.

`decode` checks that `meta` is a UTF-8 object literal (first byte `{`, last
`}`); `parseMeta` parses it fully (`manifest_meta` must be 2, every chunker has
an id, a positive `max_chars` and an `overlap_lines`, every root an id, a
label and a kind).

## Cross-section validation

As v1 for the document and lexical sections, plus: when `has_source` is set,
the named source file must exist with exactly the recorded length, and its own
header checksum (`HYBSRC01`) must equal the recorded one
(`manifest.validateSource`). `snapshot_open.open` checks presence and length
(so a lost source file reads as a missing section and `--update` recovers with
`recovered: "missing_section"`); `snapshot_open.openSource` reads and validates
the whole section.

## Publication

`publication.publishWithSource` links the document, lexical and source files
(each fsynced, non-replacing), syncs the directory, then replaces `MANIFEST`
and syncs again: a reader that sees the new manifest finds all three files.
Pruning (`keep_generations`) removes a superseded generation's source file with
its other two; the report's `pruned_files` keeps counting document and lexical
files only (its v1 meaning), source deletions are counted apart.

## Cross-branch version reservation

This 104-byte layout owns HYBMAN02/version 2 on main. The unmerged CAP-16
filename-search draft used the same identifier for a 136-byte layout; it is
not compatible with this format. Preserve this reader/writer. The integrated
filename/source extension must use HYBMAN03/version 3 with a separately
documented table and v1/v2/v3 migration tests; rebuild draft CAP-16 snapshots
in a separate directory. Do not infer a format from length alone.

## Compatibility

- A v1 manifest opens unchanged: `has_source` and `has_positions` read false,
  `meta` is empty, and `read_span`/`outline` answer `CAPACITY`
  `"re-index required: source absent"`.
- An incremental update over a v1 generation re-chunks unchanged Markdown
  files (their chunks were line windows), reports them under `changed`, and
  publishes v2.

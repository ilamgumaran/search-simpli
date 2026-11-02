# Generation manifest format v2 (minor version 2.1)

Status: implemented in `zig/src/manifest.zig` (S3-T1; v2.1 flag bit 2 since
S4-T1, see [v2.1](#v21-xxh3-section-checksums-s4-t1)). Magic: `HYBMAN02`.
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
| 10 | 2 | flags: bit 0 `has_source`, bit 1 `has_positions`, bit 2 `xxh3_sections` (v2.1); other bits must be zero | v2 (v1: zero) |
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
 "roots":[{"root_id":"r-legacy","label":"folder","kind":"local","required_labels":[],"retain_source":true,"origin":"folder"}],
 "source_section_version":1}
```

- `chunkers`: `line-window-v1` is always entry 0; `md-section-v1` is entry 1
  when any chunk of the generation was made by it. A document record's
  `chunker_index` ([segment v4](segment-format-v4.md)) indexes this array.
- `roots`: S3-T1 writes the one root `r-legacy` for a folder index; S3-T3 adds
  host, iCloud and local roots through `apply_changes`. Each root:
  `root_id`, `label`, `kind`, `required_labels` (they add to every document's
  own), `retain_source` and, since S3-T3, `origin` (`folder` or `host`; read
  as `folder` when absent). Root ids are unique. Records of `r-legacy` keep
  bare relative paths; every other root's records are `root_id/relative`
  (`scope.zig`, implementation §2).
- `pending` (S3-T3, only when non-empty): `[{root_id, path, size,
  required_labels}]`, the files named by the host whose bytes have not
  arrived (no chunks).
- `unchunked` (S3-T3, only when non-empty): the same fields for indexed files
  that produced no chunk (an empty or blank file).
- `skipped` (S3-T3, only when non-empty): the same fields plus `reason`
  (`too_large`, `unreadable`, `budget_exhausted`) for files a writer was given
  but could not index in full, kept until a later change of the path; a
  `find` or `index_status` over a scope holding one says `truncated`.
- `source_section_version`: `1` when a source section is bound, else `0`.

`decode` checks that `meta` is a UTF-8 object literal (first byte `{`, last
`}`); `parseMeta` parses it fully (`manifest_meta` must be 2, every chunker has
an id, a positive `max_chars` and an `overlap_lines`, every root an id, a
label and a kind, root ids are unique, `required_labels` are non-empty
strings, every pending or unchunked entry has a root id and a non-empty
path).

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

## Compatibility

- A v1 manifest opens unchanged: `has_source` and `has_positions` read false,
  `meta` is empty, and `read_span`/`outline` answer `CAPACITY`
  `"re-index required: source absent"`.
- An incremental update over a v1 generation re-chunks unchanged Markdown
  files (their chunks were line windows), reports them under `changed`, and
  publishes v2.

## v2.1: XXH3 section checksums (S4-T1)

Bit 2 of the flags, `xxh3_sections`, says that at least one bound section's
own header selects the XXH3-64 checksum (seed 0) instead of FNV-1a 64 (the
section header's flags bit 0: [segment v4](segment-format-v4.md#v41-section-checksum-s4-t1),
[`HYBLEX02`](lexical-segment-format-v2.md#flags-bit-0-xxh3-64-s4-t1),
[`HYBSRC01`](source-section-v1.md#flags-bit-0-xxh3-64-s4-t1)); the recorded
section checksums are then those XXH3 values. Every folder writer since S4-T1
(`searchd index`, `ss_index_folder`, `apply_changes`) sets it and writes all
three sections with XXH3. The header layout, the magic, the version number
`2` and the manifest's own FNV-1a checksum are unchanged. The reason is cost:
FNV-1a runs one byte per step, and a generation's sections are checksummed when
written, when published and when the next generation reads them back; on the
10,000-file corpus one changed file went from 243–249 ms to 154–158 ms
(ReleaseSmall, five runs; `docs/tasks/S4-T1.md`). Checksums remain
accidental-corruption detection, not authentication; SHA-256 stays the
per-file content id (the source section's file table, `INDEX-STATE.json`).

Rules (`manifest.validateSnapshotHeaders`, `manifest.validateSource`):
- without bit 2 every bound section must be FNV-1a (an XXH3 section under such
  a manifest is refused as an invalid section);
- with bit 2 each section is checked with the kind its own header names.

Compatibility:
- A reader since v2.1 opens every v2 generation written before it (FNV-1a
  sections, bit 2 clear) unchanged; `tests/fixtures/index-292cb568/` (written
  at commit 292cb568, the pin of the consumer app) is opened and queried by
  `zig/src/compat_292cb568_test.zig`, and the first `apply_changes` over it
  publishes a v2.1 generation.
- A reader before v2.1 (292cb568 and earlier) refuses a v2.1 manifest on the
  unknown flag bit with `UnsupportedFlags` before it reads any section
  (measured: that commit's `searchd query`, `find` and `read-span` over a v2.1
  index print `error: UnsupportedFlags`). An app that downgrades its engine
  must re-index.
- `import-json` keeps writing a v1 manifest, record v3 and `HYBLEX01` with
  FNV-1a, byte for byte as before.

## Follow-up: cross-branch manifest version reservation

Main's implemented 104-byte HYBMAN02/version 2 remains authoritative. The
unmerged CAP-16 branch at daddbee independently uses HYBMAN02 for a 136-byte
filename-channel layout. These are incompatible formats despite sharing an
identifier. Preserve main-v2; freeze a distinct HYBMAN03/version 3 layout for
combined filename/source support before CAP-16 integration, including explicit
section descriptors, lengths and checksums. Test v1, main-v2, filename-v3 and
combined-v3 compatibility. Rebuild CAP-16 draft-v2 snapshots in a separate
directory; do not infer a format from length alone. Rebase CAP-16 onto main's
source/positions/roots implementation before rebuilding packaged libraries.

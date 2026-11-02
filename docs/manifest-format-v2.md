# Generation manifest format v2 (minor version 2.2)

Status: implemented in `zig/src/manifest.zig` (S3-T1; v2.1 flag bit 2 since
S4-T1, see [v2.1](#v21-xxh3-section-checksums-s4-t1); v2.2 flag bits 3 and 4
since S4-T2, see [v2.2 filename sections](#v22-filename-sections-s4-t2-cap-16)
and [v2.2 recovery state](#v22-recovery-state-section-s4-t2)). Magic: `HYBMAN02`.
Written by `searchd index` / `ss_index_folder` (`zig/src/indexer.zig`).
`import-json` still writes [v1](manifest-format-v1.md), and every reader opens
both. Design: [`folder-knowledge-implementation.md`](folder-knowledge-implementation.md) §1.

The manifest stays the single atomic visibility point of a generation. v2 adds
a third bound section, the [source section](source-section-v1.md), two flags,
and a `meta` JSON object that names the chunkers and roots that produced the
generation (CAP-19 FR-18, CFT-09).

## Header (104 bytes, little-endian; +48 with v2.2 filename sections, +16 with the v2.2 state section)

| Offset | Size | Field | Since |
|---:|---:|---|---|
| 0 | 8 | magic `HYBMAN02` | v2 (v1: `HYBMAN01`) |
| 8 | 2 | version `2` | |
| 10 | 2 | flags: bit 0 `has_source`, bit 1 `has_positions`, bit 2 `xxh3_sections` (v2.1), bit 3 `filename_sections` (v2.2), bit 4 `state_section` (v2.2); other bits must be zero | v2 (v1: zero) |
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
| 92 | 4 | variable payload byte length (moved by bits 3 and 4, below) | v1 at 76 |
| 96 | 8 | manifest checksum (moved by bits 3 and 4) | v1 at 80 |

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

## v2.2: filename sections (S4-T2, CAP-16)

Bit 3 of the flags, `filename_sections` (`0x0008`), says the generation binds
the two sections of the opt-in filename channel
([`filename-field-v1`](filename-field-format-v1.md)): a catalog
`filenames-N.hybseg` and its lexical section `filename-lexical-N.hyblex`. The
magic `HYBMAN02`, the version `2`, offsets 0–91 and the manifest's FNV-1a
checksum are unchanged. With bit 3 set the header grows by 48 bytes inserted
before the payload length, and the payload by three strings:

| Offset | Size | Field |
|---:|---:|---|
| 92 | 4 | filename catalog file count |
| 96 | 4 | filename lexical term count |
| 100 | 8 | filename lexical posting count |
| 108 | 8 | catalog byte length |
| 116 | 8 | catalog internal checksum |
| 124 | 8 | filename lexical byte length |
| 132 | 8 | filename lexical internal checksum |
| 140 | 4 | variable payload byte length |
| 144 | 8 | manifest checksum (over bytes 0–143 and the payload) |

Payload strings 7–9 follow the six above: the catalog filename, the filename
lexical filename and the policy id `filename-field-v1`. All section names are
safe, distinct basenames (the documents, lexical, source and both filename
sections). Both filename sections have zero vector dimensions and the file
count, term count and posting count the header records; their lengths and
checksums are bound like the others, and bit 2 covers them too (an XXH3
filename section without it is refused).

The filename sections are not read by an open. The first filename or `both`
query on a handle reads both, checks each length and checksum against the
manifest and the counts, and walks the catalog (sorted safe paths, each stem
equal to its text, each record anchored at a real body chunk with the same
labels); the decoded catalog, its body-anchor ordinals and the filename term
lookup stay on the handle. `index_status` reports `filename_policy_id` from
the manifest alone. Writers validate the canonical postings in full before
publishing (`filename_field.validate`). Visible root masks apply through the
body anchor's ordinal, never the catalog's own; `df` and the average length
are computed over the same visible scope.

Publication links both filename files with the other sections before the
directory sync and the `MANIFEST` replacement; generation allocation skips a
number any leftover filename file holds, and pruning removes them with their
generation.

Compatibility:
- A reader before v2.2 refuses a filename generation on bit 3 with
  `UnsupportedFlags` before it reads any section: the 0.2.1 library (f45c06d,
  v2.1) and the 292cb568 library (v2.0) alike. A generation without filename
  sections does not set bit 3, but every v2.2 folder generation sets bit 4
  (below), so the older readers refuse it too.
- The channel is chosen when a directory is created: enabling it, disabling it
  or changing its analyzer needs a fresh directory
  (`FilenameSettingMismatch`, `FilenameMigrationRequiresNewDirectory`). A
  writer that omits the setting (`searchd index` without `--filename-index`,
  `ss_index_folder` or `ss_apply_changes` without `filename_index`, Dart
  `filenameIndex: null`) keeps the directory's setting, for an update and a
  full rebuild alike; an explicit different value is refused.
- PR #21 first wrote this extension as `HYBMAN03` version 3 (152-byte header,
  nine strings, the same fields in the same order). No released library wrote
  it and its natives were never pinned by a consumer, so v2.2 replaces it and
  no reader accepts `HYBMAN03` (`BadMagic`). The CAP-16 draft at `daddbee`,
  which reused `HYBMAN02` for a 136-byte layout, is not readable either: such
  a directory is rebuilt.

## v2.2: recovery-state section (S4-T2)

Bit 4 of the flags, `state_section` (`0x0010`), says the generation binds its
recovery state, the [INDEX-STATE v2](folder-knowledge-implementation.md#5-index-state-v2)
JSON of exactly this generation, as an immutable section `state-N.hybstate`.
Every folder writer since v2.2 (`searchd index`, `ss_index_folder`,
`apply_changes`) sets it; `import-json` (manifest v1) does not. With bit 4 set
the header grows by 16 bytes, after the filename fields when bit 3 is also
set, and the payload by one string, last of all:

| Offset (without bit 3 / with bit 3) | Size | Field |
|---:|---:|---|
| 92 / 140 | 8 | state section byte length |
| 100 / 148 | 8 | state section internal checksum |
| 108 / 156 | 4 | variable payload byte length |
| 112 / 160 | 8 | manifest checksum (over the bytes before it and the payload) |

So a generation is 120 bytes of header (bit 4 only) or 168 (bits 3 and 4).
The last payload string is the state file name, a safe basename distinct from
every other section's.

The section (`zig/src/state_section.zig`), little-endian, 32-byte header:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 8 | magic `HYBSTA01` |
| 8 | 2 | version `1` |
| 10 | 2 | flags: bit 0 XXH3-64; other bits zero |
| 12 | 4 | reserved, zero |
| 16 | 8 | payload byte length |
| 24 | 8 | checksum (XXH3-64) over bytes 0–23, then the payload |

The payload is the state JSON as `INDEX-STATE.json` holds it. The manifest
binds the section's whole byte length and the checksum its header records.

**Writers only.** No open reads, stats or opens the state section; a query
never touches it. A writer (`apply.zig`, the previous-generation path of
`searchd index --update`, `ss_index_folder` over an existing directory and
`apply_changes`) reads it in full and checks it before it changes anything:
a size different from the manifest's is `StateSectionSizeMismatch`, a header
`inspect` refuses (bad magic, version, flags, truncation, trailing bytes) is
`InvalidStateSection`, a checksum different from the manifest's or from its
own payload is `StateSectionChecksumMismatch` (`manifest.validateState`, which
also has `StateSectionMissing` and `StateSectionUnexpected` for bytes absent
or present against bit 4). The C ABI answers these, and the `Filename*` load
errors, with `SS_ERR_CORRUPT_SNAPSHOT`. The write is refused and nothing is
published; readers keep answering from the same generation. A state file
that is gone is a lost section, recovered like any other
(`recovered: "missing_section"`). The payload is parsed strictly
(`incremental_state.parseCommitted`: a stated `state_version`, no unknown
fields), and its `generation` and `analyzer_id` must equal the manifest's,
else `InvalidState`.

**Precedence** for the writer's previous state: the generation's bound state
section; else, for a generation that predates it (no bit 4), an
`INDEX-STATE.json` whose `generation` and `analyzer_id` match the manifest's;
else the conservative reconstruction from the generation itself (S3-T3).
`INDEX-STATE.json` is still written after each publication, as a
compatibility cache for older writers and tools.

**Publication and retention.** The state section is linked and fsynced with
the other sections before the directory sync and the `MANIFEST` replacement,
and removed when its publication fails. Generation allocation skips a number
any leftover state file holds; pruning removes it with its generation, and
orphan and superseded state files are found by the lifecycle scan
(`generation-lifecycle.md`).

**Why a section and not `meta`.** PR #21 bound the same state by copying it
into the manifest's `meta`, which every open then read and parsed: a 10k
index's MANIFEST grew from 540 B to about 2.5 MB and `ss_open` paid for it.
As a section the MANIFEST stays small (measured on S4-T1's 10k corpus: 576 B
with bit 4, 696 B with bits 3 and 4, against 540 B on f45c06d) and the open
is unchanged.

**Compatibility and rollback.** A reader before v2.2 (the 0.2.1 library at
f45c06d, the 292cb568 library) refuses every generation a v2.2 folder writer
publishes, including the first update of an older directory, with
`UnsupportedFlags`. Rolling the library back therefore needs the previous
directory: keep a copy of the index directory from before the upgrade, or
rebuild with the older library into a fresh directory. A v2.2 reader opens
every older generation (no bit 4: the precedence above starts at
`INDEX-STATE.json`).

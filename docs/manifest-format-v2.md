# Generation manifest format v2 (minor version 2.5)

Status: implemented in `zig/src/manifest.zig` (S3-T1; v2.1 flag bit 2 since
S4-T1, see [v2.1](#v21-xxh3-section-checksums-s4-t1); v2.2 flag bits 3 and 4
since S4-T2, see [v2.2 filename sections](#v22-filename-sections-s4-t2-cap-16)
and [v2.2 recovery state](#v22-recovery-state-section-s4-t2); v2.3 flag bit 5
since S6-T4, see [v2.3 lexical sections v3](#v23-lexical-sections-v3-s6-t4); v2.4 flag bit 6
since S6-T7, see [v2.4 text once](#v24-text-once-s6-t7); v2.5 flag bit 7
since S6-T8, see [v2.5 lexical section v4](#v25-lexical-section-v4-s6-t8)).
Magic: `HYBMAN02`.
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
| 10 | 2 | flags: bit 0 `has_source`, bit 1 `has_positions`, bit 2 `xxh3_sections` (v2.1), bit 3 `filename_sections` (v2.2), bit 4 `state_section` (v2.2), bit 5 `lexical_v3` (v2.3), bit 6 `text_once` (v2.4), bit 7 `lexical_v4` (v2.5); other bits must be zero | v2 (v1: zero) |
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
- `source_section_version`: the bound source section's version (`1` for
  `HYBSRC01`; `2` for `HYBSRC02`, under v2.4's bit 6), else `0`.

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
(`manifest.validateSource`). Since S3-T4 an open (`snapshot_open.open`,
`ss_open`) does not read it and does not fail without it: a lost or damaged
source section makes only `read_span` and `outline` answer `CAPACITY`
(`ss_open` opens the file and reads it at first use, see
[`generation-lifecycle.md`](generation-lifecycle.md#the-files-of-a-generation)).
A writer reads it whole with the previous generation (`apply.zig`,
`openPrevious`), so there a lost source file reads as a missing section and
`--update` recovers with `recovered: "missing_section"`;
`snapshot_open.openSource` reads and validates the whole section.

## Publication

`publication.publishWithSource` links the document, lexical and source files
(each fsynced, non-replacing), syncs the directory, then replaces `MANIFEST`
and syncs again: a reader that sees the new manifest finds all three files.
Pruning (`keep_generations`) removes a superseded generation's source file with
its other two; the report's `pruned_files` keeps counting document and lexical
files only (its v1 meaning), source deletions are counted apart
(`PruneReport.deleted_source`, which no report prints; the same holds for the
v2.2 file-name and state sections, see
[`generation-lifecycle.md`](generation-lifecycle.md#retention-pruning-keep_generations-s2-t5)).

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

The payload is the state JSON as `INDEX-STATE.json` held it (version 2). The
manifest binds the section's whole byte length and the checksum its header
records.

**S4-T4: `HYBSTA02`.** Since S4-T4 (Dart package 0.3.1) writers publish the
section as magic `HYBSTA02`, version `2`, with the same header, flags, length
and checksum and a binary payload ([`state-section-format-v2.md`](state-section-format-v2.md));
they read both forms. The manifest's binding and `validateState` are unchanged.
A library before S4-T4 refuses `HYBSTA02` with `InvalidStateSection`: it still
opens and queries such a directory, but cannot update it.

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
fields), or, for `HYBSTA02`, decoded strictly (`incremental_state.decodeBinary`),
and its `generation` and `analyzer_id` must equal the manifest's, else
`InvalidState`.

**Precedence** for the writer's previous state: the generation's bound state
section; else, for a generation that predates it (no bit 4), an
`INDEX-STATE.json` whose `generation` and `analyzer_id` match the manifest's;
else the conservative reconstruction from the generation itself (S3-T3).
After each publication `INDEX-STATE.json` is written as a **version 3
pointer** to the bound section (S4-T4: `{"state_version":3,"generation":N,
"analyzer_id":"…","state_file":"state-N.hybstate"}`, no file table); 0.3.0
wrote a full version 2 copy there instead. A pointer is resolved only through
the current `MANIFEST` (the same `validateState` checks; `null` when the
`MANIFEST` is missing or does not bind the named section), so it never
outranks the section ([folder-knowledge-implementation.md §5](folder-knowledge-implementation.md#5-index-state-v2)).

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

## v2.3: lexical sections v3 (S6-T4)

Bit 5 of the flags, `lexical_v3`, says that every lexical section the manifest
binds is [`HYBLEX03`](lexical-segment-format-v3.md) (gap-coded postings, a
front-coded dictionary, varint document lengths): the content section and,
with bit 3, the file-name section. Every folder writer since S6-T4
(`searchd index`, `searchd search`'s in-memory build, `ss_index_folder`,
`apply_changes`) sets it. The header layout, the magic, the version number `2`
and every other flag are unchanged; the recorded lexical length and checksum
are the `HYBLEX03` file's.

Rules (`manifest.validateSnapshotHeaders`, `filename_field.validateFilenameSections`):
- with bit 5 every bound lexical section must be `HYBLEX03`; without it none
  may be (a `HYBLEX03` section under a manifest without bit 5, or an older
  section under one with it, is refused: `InvalidLexicalSection` for the
  content section, `InvalidFilenameLexicalSection` for the file-name one);
- a v1 manifest (`import-json`) never sets it: `import-json` keeps writing
  `HYBLEX01`, byte for byte as before.

Upgrade. A reader since v2.3 opens every older generation unchanged
(`HYBLEX01` and `HYBLEX02` keep their readers). The first publish over an
older directory (an update, `apply_changes`) writes v3: the content section is
re-encoded from the decoded one, and the file-name section, which a publish
otherwise carries byte for byte, is rebuilt once from the catalog (no
conversion path; the cost is stated in the task Report,
[`docs/tasks/S6-T4.md`](tasks/S6-T4.md)). From then on it is carried as
before. `tests/fixtures/index-98c4a2b/` (written at 98c4a2b, the last commit
before v3) is opened, compared with a fresh v3 index answer for answer, and
updated to v3 by `zig/src/compat_98c4a2b_test.zig`.

**Compatibility and rollback (one way).** A reader before v2.3 (98c4a2b and
earlier) refuses a v2.3 manifest on bit 5 with `UnsupportedFlags`, before it
reads any section: measured on 98c4a2b's own `searchd` (every command,
`index --update` included) and `ss_open`
([`docs/evidence/s6-t4/old-library-on-v3.txt`](evidence/s6-t4/old-library-on-v3.txt)).
After the first publish under a v2.3 library, an older library cannot open
the directory and must rebuild it from the files into a fresh directory.
Index directories are never shared between devices running different library
versions.

## v2.4: text once (S6-T7)

Bit 6 of the flags, `text_once` (`0x0040`), says that the documents section is
record v5 (its file table holds each path once) and the source section, when
the manifest binds one, is `HYBSRC02` (only the bytes no chunk holds; files are
rebuilt from their chunks and checked by SHA-256). Both are specified in
[`documents-v5-source-v2-format.md`](documents-v5-source-v2-format.md), with
every validity rule. Every folder writer since S6-T7 sets it. The header
layout, the magic, the version number `2` and every other flag are unchanged;
the meta's `source_section_version` is `2` under the bit.

Rules (`manifest.validateSnapshotHeaders`, `apply`'s open of the previous
generation): with bit 6 the documents section must be record v5 and a bound
source `HYBSRC02`; without it neither may be (`InvalidDocumentSection`,
`InvalidSourceSection`). `import-json` never sets it.

Upgrade. A reader since v2.4 opens every older generation unchanged (record
v1–v4 and `HYBSRC01` keep their readers). The first publish over an older
directory writes one whole v2.4 generation; the old one stays whole until the
manifest is replaced. `tests/fixtures/index-v3-s6t4/` (written at `a534678`)
is opened, compared with a fresh index answer for answer, and updated by
`zig/src/compat_s6t7_test.zig`.

**Compatibility and rollback (one way, the second after v2.3).** A reader
before v2.4 (`ad71cfb` and earlier) refuses a v2.4 manifest on bit 6 with
`UnsupportedFlags` before it reads any section, through `ss_open`,
`ss_index_folder`, `ss_apply_changes` and every `searchd` command, and leaves
the index's files byte-identical
([`docs/evidence/s6-t7/old-library-phase2.txt`](evidence/s6-t7/old-library-phase2.txt)).
After the first publish under a v2.4 library an older library cannot open the
directory and must rebuild it from the files into a fresh directory.

## v2.5: lexical section v4 (S6-T8)

Bit 7 of the flags, `lexical_v4` (`0x0080`), says that the content lexical
section is [`HYBLEX04`](lexical-segment-format-v4.md): v3 with section 5 (the
highlight offsets `find` reads) at one byte per token, two 4-bit fields with
a varint escape at 15. Every validity rule of that section is in its format
document. Bit 7 is set only together with bit 5 and narrows it: under bits 5
and 7 the content section is `HYBLEX04` and a bound file-name section stays
`HYBLEX03` (it has no section 5). Every folder writer since S6-T8 sets it. The
header layout, the magic, the version number `2` and every other flag are
unchanged; the recorded lexical length and checksum are the `HYBLEX04` file's.

Rules (`manifest.validateSnapshotHeaders`): with bit 7 the content section
must be `HYBLEX04`; without it, it must not be (`InvalidLexicalSection` either
way); a `HYBLEX04` content section also needs bit 5 (`InvalidLexicalSection`).
A v1 manifest refuses bit 7. `import-json` never sets it.

Upgrade. A reader since v2.5 opens every older generation unchanged (`HYBLEX01`
to `HYBLEX03` keep their readers; `postings.PositionSections` records which
coding section 5 uses). The first publish over an older directory (an
update, `apply_changes`) writes one whole v2.5 generation, byte for byte a
fresh index's: the carried documents' section 5 tables are transcoded token
by token from v2's coding, the fresh ones written in v4's. The old generation
stays whole until the manifest is replaced. `tests/fixtures/index-v5-s6t7/`
(written by `main` at 62324f9), `tests/fixtures/index-v3-s6t4/` and
`tests/fixtures/index-98c4a2b/` are opened, compared with a fresh index answer
for answer, updated and crashed mid-publish by `zig/src/compat_s6t8_test.zig`;
`tests/fixtures/index-lex4-s6t8/` is v2.5's reference
(`tests/fixtures/gen_index_lex4_s6t8.sh`).

**Compatibility and rollback (one way, the third after v2.3 and v2.4).** A
reader before v2.5 (62324f9 and earlier) refuses a v2.5 manifest on bit 7 with
`UnsupportedFlags` before it reads any section, through `ss_open` and every
`searchd` command, and leaves the index's files byte-identical
([`docs/evidence/s6-t8/old-library.txt`](evidence/s6-t8/old-library.txt)).
After the first publish under a v2.5 library an older library cannot open the
directory and must rebuild it from the files into a fresh directory.

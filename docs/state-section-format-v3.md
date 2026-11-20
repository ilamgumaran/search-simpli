# State section format v3 (`HYBSTA03`)

Status: S6-T9 (D2-4, the fourth index-size step). Header in
`zig/src/state_section.zig`, payload in `zig/src/incremental_state.zig`
(`encodeBinaryRefs`, `decodeBinaryWith`). File `state-N.hybstate`, bound to its
generation by [manifest v2.6](manifest-format-v2.md#v26-state-v3-and-catalog-v6-s6-t9)
(flag bits 4 and 8). Content: the
[INDEX-STATE v2](folder-knowledge-implementation.md#5-index-state-v2) state of
exactly that generation, as in [v2](state-section-format-v2.md), except that a
file whose bytes the generation's source section holds may **refer to its
source record** instead of repeating its SHA-256, path and size.

Every folder writer since S6-T9 publishes this form. Writers read `HYBSTA01`,
`HYBSTA02` and `HYBSTA03`. An open never reads any of them; a query never
touches the state.

## Why

v2 stores, for every file, a 76-byte record and its path. For a file the
generation retains, three of those fields are already in other sections of
the same generation: the SHA-256 and the byte length in the file's
[source record](documents-v5-source-v2-format.md#records) (`HYBSRC02`), and
the path in the documents section's [file table](documents-v5-source-v2-format.md#file-table).
S6-T3 measured the repetition at 610,000 B on the 10k timing corpus and
727,531 B on prose-10k ([`index-size.md` § D](index-size.md)). v3 drops
exactly those bytes: a referenced record is 36 bytes (40 fewer than v2's 76,
the 32-byte digest and the 8-byte size) and its path is not in the text area.
Re-encoding `main`'s state sections this way (S6-T9, before the build) saves
610,000 B on timing-10k and 727,531 B on prose-10k, S6-T3's figures.

## Header (32 bytes, little-endian)

The `HYBSTA02` header with another magic and version:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 8 | magic `HYBSTA03` |
| 8 | 2 | version `3` |
| 10 | 2 | flags: bit 0 XXH3-64; other bits zero |
| 12 | 4 | reserved, zero |
| 16 | 8 | payload byte length |
| 24 | 8 | checksum (XXH3-64) over bytes 0–23, then the payload |

`HYBSTA03` with a version other than 3 is `UnsupportedVersion`; the other
header rules are v2's (`UnsupportedFlags`, `Truncated`, `TrailingData`,
`SizeOverflow`, `ChecksumMismatch`). A writer reports any of them as
`InvalidStateSection` (a checksum mismatch as `StateSectionChecksumMismatch`).
Under manifest v2.6 the section is `HYBSTA03` exactly when flag bit 8 is set
(`StateSectionVersionMismatch` otherwise).

## Payload (little-endian, fixed-width integers, no padding)

The v2 payload with one change: a file record is either v2's 76-byte record
or, when its flag bit 6 is set, a 36-byte *referenced* record.

```text
-- header, 40 bytes (as v2)
u32  state_version = 2        // the INDEX-STATE v2 content, unchanged
u32  reserved = 0
u64  generation
u32  analyzer_id              // string index
u32  string_count
u32  root_count
u32  file_count
u32  label_ref_count
u32  reserved = 0
-- string table (as v2)
u32  length                   // × string_count
u8   text[...]
-- roots, 24 bytes each (as v2)
-- files, in file order, each either:
--   (a) bit 6 clear: v2's 76-byte record, every v2 field and rule
u32  root_id
u32  flags                    // bit 0 size, 1 mtime_ms, 2 sha256, 3 pending,
                              // 4 moved_from, 5 chunker, 6 source_ref; other bits zero
u64  size
i64  mtime_ms
u32  chunks
u32  chunker
u32  label_count
u32  path_length
u32  moved_from_length
u8   sha256[32]
--   (b) bit 6 set: a referenced record, 36 bytes
u32  root_id                  // string index
u32  flags                    // bit 6 set; bits 0, 2 and 3 clear
i64  mtime_ms                 // 0 when bit 1 is clear
u32  chunks
u32  chunker                  // string index; 0 when bit 5 is clear
u32  label_count
u32  source_record            // the ordinal of the file's record in the source section
u32  moved_from_length        // 0 when bit 4 is clear
-- label references (as v2)
u32  string index             // × label_ref_count
-- text
u8   path[path_length]        // per unreferenced file, in file order
u8   moved_from[moved_from_length]   // per file with bit 4, after its path (if any)
```

A file's flags word is at offset 4 of its record in both forms, so a reader
learns the record's length from the first eight bytes.

### What a referenced record stands for

Record *r* of the generation's `HYBSRC02` source section belongs to the
*r*-th file of the documents section's file table whose `retained` bit is
set ([the source section's rule](documents-v5-source-v2-format.md#source-section-v2)).
A referenced state record with `source_record` = *r* decodes to the v2 entry
with:

- `size` = record *r*'s text length (the file's byte length);
- `sha256` = record *r*'s SHA-256 (read back as 64 lower-case hex digits);
- `path` = the file table path of that file with the record's root prefix
  removed: for the legacy root (`r-legacy`) the whole path; for any other
  root `root_id`, the path must be `root_id/` followed by at least one byte,
  and the entry's path is what follows the `/`;
- `status` indexed (bit 3 is clear);
- every other field (`root_id`, `mtime_ms`, `chunks`, `chunker`,
  `moved_from`, `required_labels`) from the record, as v2.

So a referenced record carries no path, size or digest of its own: a damaged
reference cannot name a different file without breaking one of the rules
below, and the checksums of the source section and the documents section
(bound by the same manifest) cover the bytes it refers to.

## Reading

The state is read only by a writer (`apply.zig`, before it plans an update)
and by `incremental_state.resolvePointer` (the `INDEX-STATE.json` pointer,
resolved through the current `MANIFEST`). Both decode with the generation's
source table: the writer the one it opened for the update (`source_v2.walk`,
after the documents section's checksum and the source section's checksum);
`resolvePointer` reads, checks and walks the same two sections. A generation
with no `HYBSRC02` source section has no table.

`decodeBinaryWith` reads front to back. Every v2 rule holds for both record
forms (each refused with `InvalidState`): the payload ends exactly at the
last text byte; the counts fit the remaining bytes before anything is
allocated (each file needing at least 36 bytes); string indices in range;
label counts adding up; reserved fields zero; `state_version` 2; text UTF-8;
a field whose flag is clear holds zero; flag bits 7 to 31 clear. The new
rules, each with its own error:

| # | Rule | Error |
|---:|---|---|
| S1 | A referenced record has bits 0 (size), 2 (sha256) and 3 (pending) clear. | `StateReferenceFlags` |
| S2 | A referenced record needs a source table: the generation binds a `HYBSRC02` source section. | `StateReferenceWithoutSource` |
| S3 | `source_record` is less than the source section's file count. | `StateReferenceOutOfRange` |
| S4 | The `source_record` values of the referenced records strictly increase in file order (each file is referred to at most once; state files and source records are both in record-path order). | `StateReferenceOrder` |
| S5 | For a root other than `r-legacy`, the referenced file's table path is `root_id/` followed by at least one byte. | `StateReferencePath` |

Rule S2 is checked before S3, S3 before S4, S4 before S5, and S1 before all
of them; the v2 rules of a record's own fields come before S1. The writer
reports each error as it is named and refuses the write; nothing is
published and readers keep answering from the same generation. Through the
C ABI each is `SS_ERR_CORRUPT_SNAPSHOT`.

The checksum the manifest binds catches a flipped byte first
(`StateSectionChecksumMismatch`); these rules are for a section whose
checksum is right and whose content is not. The decoded `generation` and
`analyzer_id` must equal the manifest's (`InvalidState`), as in v2.

## Writing

A writer stores a file as a referenced record exactly when all of these hold;
any other file gets v2's full record:

1. the file is indexed (not pending) and retained in the new generation, so
   the new source section has a record *r* for it;
2. the entry's `sha256` is 64 lower-case hex digits equal to record *r*'s
   digest, and its `size` is present and equal to record *r*'s text length;
3. the file table path of record *r* is the entry's root prefix (none for
   `r-legacy`, `root_id/` otherwise) followed by the entry's path;
4. *r* is greater than the previous referenced record's.

The writer reads *r*'s digest and length back from the source section it has
just encoded, so the state decodes to exactly the entries it was built from:
`decode(encode(state)) == state`, field for field, for every state. A file
whose bytes changed between the hash and the read, or whose recorded hash is
not lower-case hex, simply keeps its full record.

On the timing and prose corpora every file is retained, so every record is
referenced. A root that does not retain source (`retain_source: false`), a
pending file and a file named by the host without its bytes keep full
records.

## Worked example

Generation 3, analyzer `analyzer-v2`, one host root `home` (label `home`,
kind and origin `host`, retained), two files in record-path order:

- `inbox/todo.txt`, pending, size 12: a full record;
- `notes/plan.md`, indexed, `md-section-v1`, 2 chunks, no mtime, retained:
  the source section's record 0 (its table path `home/notes/plan.md`).

Strings, in first-use order: 0 `analyzer-v2`, 1 `home` (root id and label),
2 `host` (kind and origin), 3 `md-section-v1`. Payload, 238 bytes:

```text
offset  bytes                                            field
0       02000000 00000000 0300000000000000               state_version 2, reserved, generation 3
16      00000000 04000000 01000000 02000000              analyzer 0, 4 strings, 1 root, 2 files
32      00000000 00000000                                0 label refs, reserved
40      0b000000 04000000 04000000 0d000000              string lengths 11, 4, 4, 13
56      "analyzer-v2" "home" "host" "md-section-v1"      32 bytes
88      01000000 01000000 02000000 02000000              root: id, label, kind, origin
104     01000000 00000000                                retain_source, 0 labels
112     01000000 09000000 0c00000000000000               file 0: root 1, flags size|pending, size 12
128     0000000000000000 00000000 00000000               mtime 0, chunks 0, chunker 0
144     00000000 0e000000 00000000                       0 labels, path_length 14, moved_from 0
156     00 × 32                                          sha256 absent
188     01000000 60000000 0000000000000000               file 1: root 1, flags source_ref|chunker, mtime 0
204     02000000 03000000 00000000                       chunks 2, chunker 3, 0 labels
216     00000000 00000000                                source_record 0, moved_from 0
224     "inbox/todo.txt"                                 14 bytes: file 0's path only
238                                                      end
```

File 1 decodes to `{root_id: home, path: notes/plan.md, size: <record 0's
text length>, sha256: <record 0's digest>, status: indexed, chunker:
md-section-v1, chunks: 2}`. In v2 the same state is 291 bytes: file 1's
record 40 bytes longer and its 13-byte path in the text area.

Damaging the example: flags `0x65` (bit 0 set) is `StateReferenceFlags`; a
`source_record` of 1 with one source record is `StateReferenceOutOfRange`;
the same reference under a generation without a source section is
`StateReferenceWithoutSource`; a table path `home/` or `homework/plan.md`
is `StateReferencePath`; two referenced records both naming 0 is
`StateReferenceOrder`.

## Compatibility and rollback (one way, the fourth after v2.3, v2.4, v2.5)

A writer since S6-T9 reads every older state (`HYBSTA01` JSON, `HYBSTA02`)
and writes `HYBSTA03` at its first publish, one whole generation under
manifest v2.6. A library before S6-T9 refuses the v2.6 manifest on flag bit
8 (`UnsupportedFlags`) before it reads any section, so it cannot open, query
or update the directory; its files stay byte-identical. Rolling back needs
the directory from before the upgrade, or a rebuild with the older library
into a fresh directory.

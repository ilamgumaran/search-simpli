# State section format v2 (`HYBSTA02`)

Status: implemented in `zig/src/state_section.zig` (header) and
`zig/src/incremental_state.zig` (`encodeBinary`, `decodeBinary`), S4-T4 ruling
3. File `state-N.hybstate`, bound to its generation by
[manifest v2.2](manifest-format-v2.md#v22-recovery-state-section-s4-t2)
(flag bit 4). Content: the
[INDEX-STATE v2](folder-knowledge-implementation.md#5-index-state-v2) state of
exactly that generation, in binary.

Since S4-T4 (Dart package 0.3.1) every writer publishes this form; the writers
read both this and the JSON form `HYBSTA01` that S4-T2 (0.3.0) wrote. An open
never reads either.

## Why

At 10,000 files the JSON section was 2,522,562 B per generation (a 2,522,530 B
payload and the 32-byte header), written a second time as `INDEX-STATE.json`.
Measured on S4-T1's 10k timing corpus (one root, every file indexed, no mtime,
no move, no own label), the payload's bytes go to:

| Part of the JSON payload | Bytes | Share |
|---|---:|---:|
| keys, quotes, colons, commas | 1,120,000 | 44.4 % |
| `sha256` as 64 hex digits in quotes | 660,000 | 26.2 % |
| paths | 230,000 | 9.1 % |
| `chunker` repeated per file | 150,000 | 5.9 % |
| `root_id` repeated per file | 100,000 | 4.0 % |
| `null` and empty fields (`mtime_ms`, `moved_from`, `required_labels`) | 100,000 | 4.0 % |
| `status` | 90,000 | 3.6 % |
| numbers (`size`, `chunks`) | 42,333 | 1.7 % |
| entry punctuation, header and roots | 30,197 | 1.2 % |

The same state in this format is 970,159 B (38.5 %): 32 header bytes, 40
payload header bytes, 63 bytes of string table (five strings), one 24-byte root,
10,000 76-byte file records and 210,000 bytes of paths. Omitting only the null and
empty fields from the JSON would have left 2,132,562 B.

## Header (32 bytes, little-endian)

The `HYBSTA01` header with another magic and version, so the manifest binds
both forms the same way (`manifest.validateState`: whole byte length, and the
checksum the header records):

| Offset | Size | Field |
|---:|---:|---|
| 0 | 8 | magic `HYBSTA02` |
| 8 | 2 | version `2` |
| 10 | 2 | flags: bit 0 XXH3-64; other bits zero |
| 12 | 4 | reserved, zero |
| 16 | 8 | payload byte length |
| 24 | 8 | checksum (XXH3-64) over bytes 0–23, then the payload |

`HYBSTA01` with version 2, `HYBSTA02` with version 1, and any other magic are
refused (`UnsupportedVersion`, `BadMagic`; the writer reports
`InvalidStateSection`).

## Payload (little-endian, fixed-width integers, no padding)

```text
-- header, 40 bytes
u32  state_version = 2        // the INDEX-STATE v2 content
u32  reserved = 0
u64  generation
u32  analyzer_id              // string index
u32  string_count
u32  root_count
u32  file_count
u32  label_ref_count
u32  reserved = 0
-- string table
u32  length                   // × string_count
u8   text[...]                // the strings' UTF-8 bytes, concatenated in index order
-- roots, 24 bytes each       // × root_count
u32  root_id, label, kind, origin   // string indices
u32  flags                    // bit 0 retain_source; other bits zero
u32  label_count              // its required_labels, next in the label references
-- files, 76 bytes each       // × file_count
u32  root_id                  // string index
u32  flags                    // bit 0 size, 1 mtime_ms, 2 sha256, 3 pending (else indexed),
                              // 4 moved_from, 5 chunker; other bits zero
u64  size                     // 0 when bit 0 is clear
i64  mtime_ms                 // 0 when bit 1 is clear
u32  chunks
u32  chunker                  // string index; 0 when bit 5 is clear
u32  label_count              // its own required_labels, next in the label references
u32  path_length
u32  moved_from_length        // 0 when bit 4 is clear
u8   sha256[32]               // the raw digest; zeros when bit 2 is clear
-- label references
u32  string index             // × label_ref_count: every root's labels in root order,
                              // then every file's in file order
-- text
u8   path[path_length], moved_from[moved_from_length]   // per file, in file order
```

Shared strings (root ids, root labels, kinds, origins, label names, chunker ids,
the analyzer id) are stored once each, in first-use order. Paths are stored once
per file, in the text area. With no roots the writer stores the legacy root
(`r-legacy`, `folder`, `local`, retained, origin `folder`), as the JSON form does.

A hash that is not 64 hexadecimal digits is stored as unknown (bit 2 clear); a
hash in upper case is stored as its digest and read back in lower case. No
writer of this engine records either: hashes are SHA-256 in lower-case hex.

## Reading

`decodeBinary` reads front to back and refuses (`InvalidState`) a payload that
does not end exactly at the last text byte, a count the remaining bytes cannot
hold (checked before any allocation), a string index out of range, label counts
that do not add up to `label_ref_count`, unknown flag bits, a non-zero value in
a field whose flag is clear, a non-zero reserved field, a `state_version` other
than 2, and text that is not UTF-8. A flipped byte anywhere in the file is first
caught by the header checksum the manifest binds (`StateSectionChecksumMismatch`
or `InvalidStateSection`); the decoder's checks are for a section whose checksum
is right and whose content is not. The decoded `generation` and `analyzer_id`
must equal the manifest's.

## Compatibility and rollback

A library before S4-T4 (the 0.3.0 package, contracts 2.2.0) does not know
`HYBSTA02`. It still **opens and queries** a directory 0.3.1 wrote (the open never
reads the state section), but refuses to **update** it: `ss_apply_changes`,
`searchd index --update` and `ss_index_folder` over it fail with
`InvalidStateSection` (`SS_ERR_CORRUPT_SNAPSHOT` through the C ABI), and nothing
is published. Rolling the library back therefore needs the directory from before
the upgrade, the rule since S4-T2: keep the previous directory, or rebuild with
the older library into a fresh one.

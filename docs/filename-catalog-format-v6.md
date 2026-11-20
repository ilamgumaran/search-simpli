# File-name catalog, record v6

Status: S6-T9 (D2-4, the fourth index-size step). Implemented in
`zig/src/core/segment.zig` (`encodeCatalogV6`, `inspectCatalog`, the v6 case of
`decodeInspected`) and `zig/src/core/filename_field.zig` (the derivation and its
checks). File `filenames-N.hybseg`, bound by
[manifest v2.6](manifest-format-v2.md#v26-state-v3-and-catalog-v6-s6-t9)
(flag bits 3 and 9). The semantics of the catalog are
[filename field v1](filename-field-format-v1.md)'s, unchanged: one entry per
path with a body chunk, in byte order of the path, anchored to the file's
first body chunk, with that chunk's id, lines and labels, and the path's stem
as its text.

Every folder writer since S6-T9 publishes this form when the directory has
the file-name channel. Readers read record v3 (every catalog before S6-T9,
and `import-json`'s, which keeps writing v3) and v6.

## Why

A v3 catalog entry stores its anchor chunk's 20-byte id and the path's stem,
both of which a reader can compute: the id is the anchor body chunk's id
(the reader already finds the anchor, to check it), and the stem is a slice
of the path. S6-T3 measured them at 290,000 B on the 10k timing corpus
(200,000 B of ids, 90,000 B of stems) and 423,531 B on prose-10k
([`index-size.md` § F](index-size.md)). v6 stores neither. Re-encoding
`main`'s catalogs this way (S6-T9, before the build) saves 290,000 B on
timing-10k and 423,531 B on prose-10k, S6-T3's figures.

The record keeps v3's layout, with the id and text lengths written as zero,
so a v6 record is read by v3's record decoder and every v3 rule still
applies; the two zero length fields (8 bytes a record) are the price of that.

## Header (36 bytes, little-endian)

`HYBSEG01`'s header, as record v1 to v4:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 8 | magic `HYBSEG01` |
| 8 | 2 | version `6` |
| 10 | 2 | flags: bit 0 XXH3-64 (the writer sets it); other bits zero |
| 12 | 4 | record count |
| 16 | 4 | vector dimensions (`0` for a catalog) |
| 20 | 8 | payload byte length |
| 28 | 8 | checksum over bytes 0–27, then the payload (XXH3-64 with bit 0, else FNV-1a 64) |

Version 6 is a catalog version only: a documents section with version 6 is
refused (`UnsupportedVersion`, so `InvalidDocumentSection`), and a catalog
with version 5 (a documents-section version) is refused
(`UnsupportedVersion`, so `InvalidFilenameCatalog`). `segment.inspectCatalog`
accepts versions 1 to 4 and 6; `segment.inspect`, for documents, versions 1
to 5.

## Records

`record count` records, back to back, ending exactly at the payload's end:

```text
u32 id_length                 // must be 0
u32 path_length
u32 text_length               // must be 0
u32 vector_length             // must be 0
u32 start_line                // the anchor chunk's
u32 end_line                  // the anchor chunk's
u32 required_labels_length
path bytes
required-label bytes          // the file's labels, v3's canonical field
```

## Derivation

For catalog entry *i* with path *P*, the reader takes the body (documents
section) chunks whose path is *P*; the **anchor** is the first of them by
(start line, end line, id), as v3's writer chose it. Then:

- the entry's **id** is the anchor's id;
- the entry's **text** is the stem of *P*: its last `/`-separated part
  without its final `.` and what follows (the whole part when it has no `.`).

These are exactly the bytes a v3 catalog stores, so every answer that
reads a catalog entry (file-name search, `both`, `list_files`) is the same.

## Validity rules

All v3 catalog rules hold, each with its existing error, at the first
file-name or `both` query on a handle (the lazy load), at the one-shot CLI
open (`searchd search`), and in the writer's check of the catalog it built
(`validateBuilt`, before publishing): the manifest's size, checksum and
counts; zero vector dimensions; every path a safe relative path, strictly
increasing (`FilenameCatalogMismatch`); every chunk's labels equal to its
file's entry's (`FilenameCatalogMismatch`); every entry anchored at a real
body chunk (`FilenameAnchorNotFound`) with the same start and end line
(`FilenameCatalogMismatch`). v3's check that the stored id equals the
anchor's and the stored text equals the stem has nothing to compare in v6;
its place is taken by:

| # | Rule | Error |
|---:|---|---|
| C1 | `id_length` is 0. | `FilenameCatalogIdPresent` |
| C2 | `text_length` is 0. | `FilenameCatalogTextPresent` |
| C3 | Under manifest v2.6 the catalog is record v6 exactly when flag bit 9 is set (and v3 otherwise). | `FilenameCatalogVersionMismatch` |

C1 and C2 are checked per record, in record order, as the record is read
(C1 before C2); C3 before any record is read. An error found at the lazy
load is kept on the handle and answered by every later file-name query
(`SS_ERR_CORRUPT_SNAPSHOT` through the C ABI); content queries are
unaffected, as for every other catalog error.

## Writing

The writer groups the body chunks as before (`filename_field.group`), then
encodes each entry with its path, lines and labels and zero id and text
lengths (`segment.encodeCatalogV6`). A carried file-name lexical section
(S4-T13: the same paths, in the same order, with the same labels) does not
read the previous catalog; the catalog is encoded fresh every generation,
because anchors move with a changed file's chunks. `validateBuilt` decodes
the encoded catalog with the derivation above and compares every field with
the grouping it was encoded from.

## Worked example

Two files: `home/a.md` (anchor chunk lines 1–3, no labels) and
`school/b.txt` (anchor chunk lines 1–40, label `kids`). Payload, 81 bytes:

```text
offset  bytes                                          field
36      00000000 09000000 00000000 00000000            id 0, path 9, text 0, vector 0
52      01000000 03000000 00000000                     lines 1–3, labels 0
64      "home/a.md"                                    9 bytes
73      00000000 0c000000 00000000 00000000            id 0, path 12, text 0, vector 0
89      01000000 28000000 04000000                     lines 1–40, labels 4
101     "school/b.txt" "kids"                          16 bytes
117                                                    end
```

Header: `HYBSEG01`, `0600` (version 6), `0100` (XXH3-64), record count 2,
dimensions 0, payload length 81, checksum. Entry 0 decodes to id = the id of
`home/a.md`'s chunk at lines 1–3, text `a`; entry 1 to the id of
`school/b.txt`'s chunk at lines 1–40, text `b`. As v3 the same catalog
stores two 20-byte ids and the stems `a` and `b`: 42 bytes more.

Damaging the example: an `id_length` of 1 (and one id byte) in entry 0 is
`FilenameCatalogIdPresent`; a `text_length` of 1 is
`FilenameCatalogTextPresent`; entry 1's lines changed to 2–40 (no chunk
there) is `FilenameCatalogMismatch`; the version field set to 3 under bit 9
is `FilenameCatalogVersionMismatch`.

## Compatibility and rollback

A reader since S6-T9 opens every older catalog (record v3) unchanged. The
first publish over an older directory writes a v6 catalog in one whole v2.6
generation. A library before S6-T9 refuses the v2.6 manifest on flag bit 8
or 9 (`UnsupportedFlags`) before reading any section; read alone, a v6
catalog is `UnsupportedVersion` to it.

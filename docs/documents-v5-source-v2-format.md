# Text once: documents record v5 and source section v2

**Status: implemented (S6-T7 Phase 2).** `zig/src/segment_v5.zig` writes and
reads the documents section, `zig/src/source_v2.zig` the source section; the
folder writer (`apply.zig`) publishes them at every publish, manifest v2.4.
The Phase 1 prototype `scripts/prototypes/s6t7/text_once.py` wrote the same
bytes from an index `main` wrote: on the six corpora the library's sections
equal the prototype's to the byte. Every validity rule below has a Zig test
that breaks it with the checksum recomputed (`zig/src/text_once_test.zig`);
the old formats' compatibility is in `zig/src/compat_s6t7_test.zig`.
Measured results are in `docs/tasks/S6-T7.md` (Reports) and
`docs/evidence/s6-t7/`.

This is D2 step 2 of [`index-size.md`](index-size.md) (§ A′, rulings 1 and 5).
A file's text is stored once:

- the chunk text stays in the documents section, where queries read it;
- the source section keeps only the bytes no chunk holds;
- `read_span` and `outline` rebuild a file from its chunks and those bytes,
  and check the result's SHA-256 before using it;
- records are coded compactly (raw ids, varint fields);
- each path is stored once, in a file table, and the other parts of the two
  sections refer to a file by its position in that table.

It replaces [segment record v4](segment-format-v4.md) (`HYBSEG01`, version 4)
for the content documents section and [source section v1](source-section-v1.md)
(`HYBSRC01`) in a generation the folder writer publishes. The file-name catalog
(`filenames-N.hybseg`, record v3), the lexical sections, the state section and
`import-json`'s output do not change in this step (see
[Paths in the other sections](#paths-in-the-other-sections)).

## Conventions

- Integers in headers are little-endian, fixed width.
- **varint**: unsigned LEB128, low seven bits first, the high bit set on every
  byte but the last. A **u32 varint** has at most 5 bytes and a value below
  2^32. A **u64 varint** has at most 10 bytes and a value below 2^64. It is
  used only for a file's byte length.
  - A reader refuses a varint that runs past the end of its area, has more
    bytes than its width allows, or exceeds its range.
  - It accepts an overlong form (for example `0x80 0x00` for 0), as
    `postings.readVarint` does today. No writer emits one.
- Line maps keep v1's coding exactly: `line_count + 1` u64 varints, the first
  absolute, each later one a delta ([source-section-v1](source-section-v1.md#line-maps)).
- "Bytes" means bytes. A path is compared bytewise (`std.mem.order`).
- An **area** is a byte range named by the header. "No byte left over" means
  that, once the area's last element is read, the cursor is exactly at the
  area's end.

## Documents section, record v5

The magic stays `HYBSEG01`; the version is `5`. The 56-byte header:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 8 | magic `HYBSEG01` |
| 8 | 2 | version `5` |
| 10 | 2 | flags: bit 0 XXH3-64 (must be set); other bits must be zero |
| 12 | 4 | document (chunk) count |
| 16 | 4 | vector dimensions (0 when no record has a vector) |
| 20 | 4 | file count |
| 24 | 8 | file table bytes |
| 32 | 8 | records bytes |
| 40 | 8 | decoded path bytes: the sum of every path's length |
| 48 | 8 | checksum: XXH3-64 (seed 0) over bytes 0–47, then bytes 56 to the end |

The payload is two areas, back to back:

- the **file table**, from byte 56, `file table bytes` long;
- the **records**, immediately after it, `records bytes` long.

The section ends exactly at the last record's last byte.

### File table

There is one entry per file, in strictly increasing path order. The table
holds every file that has at least one chunk or whose bytes are retained.
Files that are only pending, skipped, or unchunked and not retained are not
in it (they stay where they are today: the state section and the manifest
meta).

| Field | Coding | Rule |
|---|---|---|
| shared | u32 varint | bytes shared with the previous path, at most 255; 0 for the first entry; at most the previous path's length |
| suffix length | u32 varint | ≥ 1 |
| suffix | bytes | the path's bytes after the shared prefix |
| chunks and retained | u32 varint | `(chunk_count << 1) \| retained` |

- The path is the previous path's first `shared` bytes followed by the suffix.
- The path is the record path the engine uses today: `root_id/relative` for a
  named root, the bare relative path for `r-legacy`.

**Order and canonical form** are one check, the
[lexical v3 rule](lexical-segment-format-v3.md#section-2-dictionary):

- When `shared` is less than both the previous path's length and 255, the
  suffix's first byte must be greater than the previous path's byte at
  `shared`. This rules out duplicates, descending pairs, and a `shared`
  shorter than the true common prefix.
- When `shared` equals the previous path's length, the path is a strict
  extension of the previous one, which is ascending.
- When `shared` equals 255 and is shorter than the previous path, the rest of
  the two paths must be ascending bytewise.

The writer caps a longer common prefix at 255; the suffix then carries the
rest. Neither the 255-byte cap nor UTF-8 validity is a rule about paths, as
neither is today. The retained files' paths must also satisfy v1's
`validPath`, as today; that rule is checked when the source section is read.

**Fields of an entry:**

- `chunk_count` is the number of records this file owns. A file with
  `chunk_count = 0` must have `retained = 1`: an unchunked file is in the
  table only because its bytes are kept.
- `retained = 1` says the file's bytes are in the source section. It is
  allowed only when the manifest binds a source section.

**Derived for file *i***, by walking the table in order:

- `first_record(i)` = the sum of the earlier entries' `chunk_count`. The
  file's records are `[first_record(i), first_record(i) + chunk_count(i))`.
- `retained_ordinal(i)` = the number of earlier entries with `retained = 1`.
  This is the file's position in the source section, and the value v4 stored
  as `source_doc_index`.
- A file with `retained = 0` has `source_doc_index = 0xFFFFFFFF`, as in v4.

**Totals:**

- The `chunk_count`s sum to the document count exactly.
- The decoded paths' lengths sum to `decoded path bytes` exactly.
- The table ends exactly at `file table bytes`.
- The number of entries equals `file count`.

### Records

There is one record per chunk, in file-table order: file 0's records first,
then file 1's, and so on. Within a file, records are in the writer's order,
which is the chunker's order today.

| Field | Coding | Rule |
|---|---|---|
| flags | u32 varint | bit 0 `id_inline`, bit 1 `has_vector`, bit 2 `has_labels`; other bits zero |
| id | 10 bytes, or u32 varint length + bytes | see below |
| text length | u32 varint | |
| start line | u32 varint | ≥ 1 |
| line span | u32 varint | `end_line − start_line`; `start + span` < 2^32 |
| chunker index | u32 varint | ≤ 65,535 |
| section depth | u32 varint | ≤ 65,535 |
| heading back | u32 varint | 0 when the chunk has no heading line, else `start_line − heading_line + 1`; ≤ start line |
| section path length | u32 varint | present only when section depth > 0 |
| labels | u32 varint length (≥ 1) + bytes | present only when `has_labels` |
| vector | dimensions × f32, little-endian | present only when `has_vector`; requires dimensions > 0 |
| text | text length bytes | |
| section path | section path length bytes | |

**The id.**

- Without `id_inline`, the id is 10 raw bytes. The decoded id is their 20
  lower-case hex digits, high nibble first.
- With `id_inline`, the id is a u32 varint length followed by that many bytes,
  taken as they are. It may be empty.
- The writer uses the raw form exactly when the id is 20 lower-case hex digits,
  which every id the folder writer makes is
  (`sha256(path\0start\0end\0text)[:20]`). It uses the inline form otherwise,
  for an id carried from a generation that another writer made.
- A reader accepts either form for any id; non-canonical forms are not refused.

**Each decoded record** has the same fields as record v4:

- `path` is its file's path;
- `start_line` is the start line;
- `end_line` is `start_line + span`;
- `heading_line` is 0 when heading back is 0, else `start_line − heading back + 1`;
- `source_doc_index` is its file's;
- labels, vector, chunker index, section depth and section path are as stored.

**Record rules** are v4's, restated:

- start line ≥ 1, and end line ≥ start line (this follows from the span).
- When depth > 0: heading back ≥ 1, and the section path holds exactly `depth`
  entries joined by U+001F (`0x1F`).
- When depth = 0: there is no section path length field, and the path is empty.
- Labels are sorted strictly bytewise and joined by `\n`. No label is empty or
  contains NUL or CR.
- `has_vector` with dimensions = 0 is refused.

The records area ends exactly after the last record's section path.

Record v4's empty-path, line-0 form (an `import-json` record without a
citation) has no v5 coding. No v5 writer emits it (see [Writers](#writers)).

## Source section v2

The magic is `HYBSRC02`, version `2`. The 48-byte header:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 8 | magic `HYBSRC02` |
| 8 | 2 | version `2` |
| 10 | 2 | flags: bit 0 XXH3-64 (must be set); other bits must be zero |
| 12 | 4 | file count: the number of retained files |
| 16 | 8 | records bytes |
| 24 | 8 | line map bytes |
| 32 | 8 | residual bytes |
| 40 | 8 | checksum: XXH3-64 (seed 0) over bytes 0–39, then bytes 48 to the end |

Three areas follow, back to back: records, line maps, residual. The section
ends exactly at the residual area's last byte.

The source section has no paths. Its record *r* belongs to the documents
section's *r*-th file with `retained = 1`, in file-table order, which is path
order as in v1. `file count` must equal the number of such files.

### Records

There is one record per retained file, in that order.

| Field | Coding | Rule |
|---|---|---|
| sha256 | 32 bytes | the SHA-256 of the file's original bytes (BOM included) |
| flags | u32 varint | bit 0 `bom`, bit 1 `whole`; other bits zero |
| text length | u64 varint | the file's byte length |
| line count | u32 varint | v1's line count |
| chunk count | u32 varint | present only when `whole` is clear; must equal the file's `chunk_count` in the documents section |
| recipe | chunk count × u32 varint | present only when `whole` is clear; one value per chunk, in record order |

- `bom` is v1's encoding byte: set exactly when the file starts with
  `EF BB BF`.
- `whole` says the file's bytes are all in the residual area. A file whose
  `chunk_count` is 0 must have `whole` set.

### Line maps

One map per record, in record order, gap-free. Each map is `line count + 1`
u64 varints, exactly as in v1. The maps area ends exactly after the last
map's last varint.

### Residual area

Each file's residual bytes, in record order, gap-free:

- a file kept whole: all of its bytes;
- a rebuilt file: the bytes no chunk holds, in file order (its gaps, then its
  tail).

### The recipe

The recipe describes the file as its chunks laid out in order. `pos` is the
number of bytes emitted so far; it starts at 0. For chunk *j*, with text *t*
of length *L* and recipe value *v*:

- **v even**: a gap of `g = v / 2` bytes, then the whole chunk.
  - Emit the next `g` residual bytes, then *t*.
  - `pos ← pos + g + L`.
- **v odd**: an overlap of `k = (v + 1) / 2` bytes (k ≥ 1). The chunk starts
  `k` bytes before `pos`.
  - Rule: `k ≤ pos`.
  - When `k < L`, emit `t[k..]` and set `pos ← pos + L − k`.
  - When `k ≥ L`, the chunk lies wholly inside bytes already emitted (a
    *contained* chunk). Emit nothing; `pos` is unchanged.

After the last chunk, emit the rest of the file's residual bytes (its tail).

**Derived and checked** while walking a record:

- `pos` never passes the text length.
- The file's residual length is (the sum of its gaps) + (text length − `pos`
  after the last chunk).
- File *r*'s residual run starts where file *r − 1*'s ends (the first at 0).
- A file kept whole has residual length = its text length.
- The residual lengths sum to `residual bytes` exactly. This is "no byte left
  over" for the residual area: one byte more is refused, and one byte less
  makes the last file's run pass the area's end.

The rebuilt bytes are only known to be right once their SHA-256 is checked:

- An overlap's first `k` bytes of *t* are not compared with the bytes already
  emitted.
- A gap's bytes are not compared with anything.
- A chunk's position is not compared with its line numbers.

All three are covered by the SHA-256. A gap written one byte short, an overlap
emitted twice, or a chunk placed one byte off each yields bytes whose SHA-256
differs, and the read is refused.

## Rebuilding a file

```
rebuild(r):                      # r: the source record of a retained file f
  run = residual[res_start(r) .. res_start(r) + residual_length(r)]
  if whole(r): out = run
  else:
    out = []; at = 0
    for each chunk j of f, with recipe value v and text t:
      if v even: g = v/2; out += run[at .. at+g]; at += g; out += t
      else:      k = (v+1)/2; if k < len(t): out += t[k..]
    out += run[at ..]
  require len(out) == text_length(r)          else SourceFileLengthMismatch
  require sha256(out) == sha256(r)             else SourceFileSha256Mismatch
  require bom(r) == out starts with EF BB BF   else InvalidLineMap
  (at the first read of r per handle) require map(r) == the line starts of out
                                               else InvalidLineMap
  return out
```

- The length check cannot fail on a section that passed the structural walk.
  It is kept as a cheap guard.
- The line starts of `out` are v1's (`source.lineStarts`, `splitlines`
  breaks: LF, CR LF, lone CR, VT, FF, FS, GS, RS, NEL, LS, PS; line 1 at
  byte 3 after a BOM).
- The check against the map is v1's `validateLineMap`, run once per file per
  handle (S4-T14), now on the rebuilt bytes.

### The hard cases

| Case | What the writer does | Example in the six corpora |
|---|---|---|
| Overlapping chunks (line windows overlap 3 lines) | odd recipe value: the overlap length | 902 in family, 3,348 in fixtures, 2,536 in prose-10k |
| A chunk wholly inside an earlier one (a short window after a long line) | odd value with k ≥ L: emits nothing | 4 in prose-10k, 190 in fixtures |
| A chunk that is not an exact run of the file's bytes | the file is kept whole | every CR LF or lone-CR file with a multi-line chunk: 2 in J2, 1 in family, 5 in fixtures |
| Front matter, blank lines between Markdown sections, a file's leading or trailing blank lines | gap or tail bytes | every Markdown file with front matter |
| No final newline | the chunk ends at the last byte; the tail is empty | 4 rebuilt in fixtures, 1 in J2, 1 in family |
| Final newline | the tail is the newline (the chunk text is stripped) | most files |
| BOM | `bom` set; the BOM is a gap of 3 bytes before the first chunk (chunk text never holds it) | 3 in fixtures, 1 in J2, 1 in family |
| Empty file | retained, 0 chunks, kept whole, text length 0, residual 0 bytes, line count 0, map one varint `0` | 3 in fixtures, 1 in J2, 1 in family |
| Blank (whitespace-only) file | retained, 0 chunks, kept whole | 1 in fixtures |
| A file with chunks whose bytes are not retained (a root with `retain_source` false) | `retained = 0`; not in the source section | none in the six corpora; the default for `local` roots |

**Why a multi-line chunk in a CR LF file is not an exact span.** Every chunker
joins a chunk's lines with `\n` and strips the result. Inside a CR LF file the
chunk text therefore has `\n` where the file has `\r\n`. The same holds for any
break other than LF: lone CR, VT, FF, FS, GS, RS, NEL, LS, PS. A one-line chunk
in such a file is still exact.

The writer does not try to code the difference. The whole file goes to the
residual area: in the six corpora, 8 files kept whole for this reason. All
kept-whole bytes, including empty and blank files, come to 959 B in fixtures
(9 files), 201 B in family (2) and 525 B in J2 (3). The one cost is that such
a file's text is stored twice, as today.

## Writers

**Where each chunk lies.** For each file with chunks, the writer finds each
chunk text's position in the file's bytes. The reference rule (the
prototype's, from S6-T3's `locate_chunks`) is the first occurrence that starts
at or after the start of the chunk's start line and ends at or before the end
of its end line:

- the start of line `start_line`;
- up to the start of line `min(end_line, line_count) + 1`, or the end of the
  file.

The format accepts any true position, so the rule is the writer's, not the
reader's. Two writers may differ in where they place a repeated text, but
not in the bytes rebuilt.

**Kept whole.** A file is kept whole, with `whole` set and all its bytes in the
residual area, when either:

- it has no chunk; or
- some chunk is not found at a true position.

The writer also keeps the file whole when a recipe value would reach 2^32: a
gap or overlap of 2^31 bytes or more, only possible in a file over 2 GiB.

**Recipe.** Otherwise, with the chunks' positions `p_j` and lengths `L_j` in
record order:

- If `p_j ≥ pos`, write `2(p_j − pos)` and set `pos ← p_j + L_j`.
- Else write `2(pos − p_j) − 1` and set `pos ← max(pos, p_j + L_j)`.

The gaps and the tail, in order, are the file's residual bytes.

**What the writer copies.** A carried file (bytes unchanged, chunks unchanged,
including a rename) keeps its source record and its residual run byte for
byte. Today's writer copies a carried file's v1 record and text the same way
(`source.carriedRecord`). A changed or new file is located afresh.

**Ordering.** The folder writer already writes files in record-path order with
each file's records together (S4-T16). The file table and both sections follow
that order unchanged.

**import-json.** It writes what it wrote before (record v3 under a v1
manifest, or v2 with the file-name channel), byte for byte. It never writes v5.

**A record v5 cannot code.** When a folder writer meets a record it cannot
code (an empty path, or line 0), the publish fails before anything is written:
a writer bug, not a fallback. No folder generation has one: every folder
record's path passes `validPath` and every chunker's start line is ≥ 1. The
error is `RecordNotEncodableV5` (`segment_v5.encodeAlloc`, before the
generation's first file is written).

## Validation

### Documents section, at open

In this order. Any failure is the existing corruption error:
`InvalidDocumentSection` at the manifest binding, `SS_ERR_CORRUPT_SNAPSHOT`
through the C ABI, and the open fails. The names below are the library's
(`segment.DecodeError`).

1. **Header.**
   - Length ≥ 56, else `Truncated`.
   - Magic, else `BadMagic`.
   - Version: 5, or 1–4 handed to the v4 decoder; anything else is
     `UnsupportedVersion`.
   - Flags exactly `0x0001`, else `UnsupportedFlags`.
   - `56 + file table bytes + records bytes`, with overflow checks
     (`SizeOverflow`), equals the section's length. Shorter is `Truncated`;
     longer is `TrailingData`.
2. **Checksum**, before any count is trusted (`ChecksumMismatch`).
3. **Bounds the counts imply**, before any allocation sized by them
   (`InvalidFileTable` or `InvalidRecord`):
   - file table bytes ≥ 4 × file count (an entry is at least 4 bytes);
   - decoded path bytes ≥ file count, and ≤ 255 × file count + file table
     bytes;
   - records bytes ≥ 8 × document count (a record is at least 8 bytes);
   - vectors: at most `records bytes / (4 × dimensions)` records can have
     one. A reader sizes its vector array by that bound, or by a count taken
     in the walk, never by document count × dimensions alone.
4. **File table**, entry by entry. Each entry's rules come from
   [File table](#file-table):
   - **`shared`:**
     - at most 255;
     - at most the previous path's length;
     - 0 for entry 0;
     - else `InvalidFileTable`.
   - **Suffix:**
     - suffix length ≥ 1, and the suffix within the area, else
       `InvalidFileTable`;
     - order and canonical form, else `UnsortedPaths`.
   - **Running totals:**
     - the decoded path bytes never pass the header's, else
       `InvalidFileTable`;
     - the chunk count sum never passes the document count, else
       `InvalidFileTable`.
   - **Chunks and retained:**
     - `chunk_count = 0` with `retained = 0`, else `InvalidFileTable`;
     - `retained = 1` while the manifest binds no source section, else
       `InvalidFileTable`.
   - **After the last entry** (header `file count`):
     - no byte left over, else `TrailingData`;
     - decoded path bytes equal the header's;
     - the chunk counts sum to the document count;
     - else `InvalidFileTable`.
5. **Records**, one per chunk:
   - unknown flag bits, else `UnsupportedFlags`;
   - every varint within the area, else `InvalidRecord`;
   - start line ≥ 1 and the span in range, else `InvalidCitation`;
   - chunker index and depth ≤ 65,535, heading back ≤ start line, and the
     depth rules, else `InvalidSection`;
   - the labels rules, else `InvalidRequiredLabels`;
   - a vector with dimensions 0, else `InvalidVectorDimensions`;
   - every take within the area, else `InvalidRecord`;
   - after the last record (the document count), no byte left over, else
     `TrailingData`.
6. **Manifest binding** (unchanged rules, new values):
   - The manifest's document count and section checksum equal the header's.
   - The `text_once` flag is set exactly when this section is version 5 (see
     [Manifest](#manifest-v24)).

The open decodes everything (as for v4). It fills the same `hybrid.Document`
array, with two additions:

- one block of `decoded path bytes` that every record's path points into;
- one block of 20 bytes per raw id for the hex ids.

Text, labels, vectors and section paths still point into the section's
bytes, as in v4.

### Source section, at its first use

The first `read_span` or `outline` on a handle runs this, as v1's streamed
open runs today (S4-T10). Any failure makes every `read_span` and `outline` on
the handle answer the existing capacity error `re-index required: source
section unavailable (<name>)`. Queries, `find` and `list_files` are not
affected: a damaged source never fails the open, as today.

1. **Header.**
   - Length ≥ 48, else `Truncated`.
   - Magic: `HYBSRC02`, or `HYBSRC01` handed to the v1 reader; anything else
     is `BadMagic`.
   - Version 2, else `UnsupportedVersion`.
   - Flags exactly `0x0001`, else `UnsupportedFlags`.
   - `48 + records + maps + residual`, with overflow checks, equals the
     section's length. Shorter is `Truncated`; longer is `TrailingData`.
2. **Checksum** over the whole section; it must equal the manifest's.
   (Streamed as v1's text is: the residual area need not stay resident.)
3. **File count** equals the documents section's number of retained files,
   else `SourceFileCountMismatch`.
4. **Bounds:**
   - records bytes ≥ 35 × file count (32 + 3 one-byte varints);
   - maps bytes ≥ file count (a map is at least 1 byte);
   - else `InvalidFileTable`.
5. **Records**, record *r* bound to retained file *r*:
   - **The file's path:**
     - satisfies `validPath`, else `InvalidPath` (v1's rule, now checked on
       the file table's path).
   - **Flags and kept whole:**
     - unknown flag bits, else `InvalidFileTable`;
     - a file with 0 chunks not `whole`, else `InvalidFileTable`.
   - **Chunk count and recipe** (not `whole` only):
     - the chunk count equals the documents', else `InvalidFileTable`;
     - each recipe value walked by [the recipe](#the-recipe): an overlap with
       k > `pos`, or `pos` past the text length, is `InvalidFileTable`.
   - **The file's residual run:**
     - must end within `residual bytes`, else `InvalidFileTable`.
   - **The file's map:**
     - `line count + 1` u64 varints, read from where the previous map ended,
       within the maps area, else `InvalidLineMap`.
6. **After the last record:**
   - no byte left over in the records area, else `TrailingData`;
   - none in the maps area, else `InvalidLineMap`;
   - the residual runs sum to `residual bytes` exactly, else
     `InvalidFileTable`.

### Every `read_span` and `outline` of a file

- The file is rebuilt and its SHA-256 checked **at every call**, before any
  byte is used.
  - A mismatch answers `re-index required: source section unavailable
    (SourceFileSha256Mismatch)`, the error and wording v1's `fileBytes` uses
    today.
  - A rebuilt file whose SHA-256 does not match is never returned.
- The line map is checked against the rebuilt bytes at the first call per
  file per handle (S4-T14's rule, unchanged).

There is no per-file I/O beyond the file's residual run:

- the chunk text is already resident (the documents section is decoded at
  open);
- a kept-whole file is one positioned read, as in v1;
- a rebuilt file is one positioned read of its gaps and tail. In the six
  corpora that is 1 to 130 bytes for every timed file.

## Manifest v2.4

Flag bit 6 of `HYBMAN02`, `text_once` (`0x0040`), is set exactly when the
generation's documents section is record v5 and its source section, when it
has one, is `HYBSRC02`. A set bit with a v4 documents section, or with a
`HYBSRC01` source, is refused (`InvalidDocumentSection` /
`InvalidSourceSection`). So is a clear bit with a v5 or v2 section. No other
manifest byte changes. The meta's `source_section_version` is `2` with bit 6
set (`1` before, `0` without a source).

## Compatibility

**An older library and a new index.** A library from `main` (`ad71cfb`) or
any earlier one knows flag bits 0–5. `manifest.decodeV2` refuses bit 6 with
`UnsupportedFlags` before it reads any section. So `ss_open`, every CLI
command and `searchd index` (full or `--update`) over the directory fail at
once, and nothing is written. Measured with `main`'s `searchd` on a copy whose
only change is bit 6 (`docs/evidence/s6-t7/old-library.txt`):

- `query`, `read-span`, `outline` and `list-files` print `error:
  UnsupportedFlags` and exit 1;
- `index --update` and a full `index` into it exit 1;
- every file of the directory is byte-identical afterwards.

Phase 2 repeated it on indexes the new writer published, through the C ABI
(`ss_open`, `ss_index_folder`, `ss_apply_changes`: each returns NULL or an
error naming `UnsupportedFlags`) and the CLI, with every index file
byte-identical afterwards
([`docs/evidence/s6-t7/old-library-phase2.txt`](evidence/s6-t7/old-library-phase2.txt)).
On a directory without a `WRITER.LOCK` (the committed fixture) the three
writer calls create that empty lock file before they read the manifest, as
they do on any directory; every published index already has one.

Without the bit an old library would still refuse, but later and less
clearly: the v5 section fails its length binding (`DocumentSectionSizeMismatch`,
measured). The bit makes the refusal happen first and name itself.

**A new library and an old index.** It reads record v1–v4 and `HYBSRC01`
exactly as today (manifest bit 6 clear). It writes v5/v2 at its first publish
into the directory: one whole new generation, the old one left whole until
the manifest is replaced (S6-T4's rule). An update from a v4/v1 generation
locates every carried file's chunks once in its v1 bytes, which it already
reads.

**Rollback** needs the directory from before the upgrade, or a re-index with
the older library into a fresh one. This is the rule since S4-T2 and S6-T4.

## Paths in the other sections

After this step a path is stored once in each section that has one. Today:

| Where | Today | With this format |
|---|---|---|
| Documents (content) | the record path, once per chunk | once per file, front-coded, in the file table |
| Source | the record path, once per retained file | none: bound to the file table by order |
| State section (`HYBSTA02`) | the relative path per file (indexed and pending), and `moved_from` | unchanged in this step |
| File-name catalog (`filenames-N.hybseg`, record v3) | the record path per file with a chunk, with the anchor chunk's id, lines and labels | unchanged in this step |
| Manifest meta | `pending`, `unchunked` and `skipped` paths | unchanged |

How each could refer to a file-table ordinal later (step 4 of D2, unless ruled
into this step):

- **State.** A file entry in the table holds `ordinal + 1` in place of its
  path; 0 means "path in the text area" for a pending or excluded file, which
  is not in the table. `moved_from` stays a path, since the old path is not in
  the new table.
- **Catalog.** One record per table file with a chunk, in table order, can be
  derived entirely: the path from the table, the text (the stem) from the
  path, and the id, lines and labels from the file's first record. That makes
  the catalog's records a function of the documents section. It is then a
  flag rather than a section, and only its lexical part stays.
- **Meta `unchunked`.** Every unchunked retained file is a table entry with 0
  chunks, so the list could be dropped. Unchunked files that are not retained
  are not in the table and keep their paths.

## Placement of the file table

[`index-size.md`](index-size.md) ruling 5 puts the paths in the source
section's file table. This document puts them in the documents section, for
four reasons found while writing it:

1. A generation without a source section must still have paths. That is every
   generation whose roots are all `local`, the default (`apply.defaultRetain`).
   With the table in the source section, every generation would need a source
   section, and `index_status`'s `has_source` would change meaning.
2. Queries, `find`, `list_files` and `search` read paths, so the open would
   have to read and check the source section's table. Today the source is
   opened lazily, at the first `read_span`.
3. A damaged source section would then fail the open and every query. Today it
   fails only `read_span` and `outline`.
4. The open would read two sections instead of one.

**Byte cost of the two placements.**

- The bytes are the same either way: the table moves between the two sections.
- The documents header loses its three table fields (−16 bytes, a 40-byte
  header), and the source header gains them (+16).
- In the six corpora every file is retained, so the totals are equal to the
  byte.

## Measured

On the six corpora S6-T4 used:

- **Rebuild check:** 30,366 retained files, every one rebuilt from v5/v2
  equal to its v1 bytes, SHA-256, BOM flag and line map.
  - 30,352 rebuilt from chunks; 14 kept whole.
  - 0 mismatches.
- **Record fields:** every field of every v5 record equal to v4's, 64,142
  records.

The library (Phase 2), on the same six corpora:

- **Sections:** documents and source equal the prototype's to the byte
  (timing-10k: 8,028,417 B and 539,719 B); the index 34–45 % smaller than
  `main`'s ([`index-size.md`](index-size.md#landed)).
- **Rebuild:** `read_span` of every file, whole and over every pair of
  adjacent lines, byte-identical to `main`'s, fresh and after one update
  (`docs/evidence/s6-t7/phase2/same-answers-c-abi.txt`).
- **Cost:** open within 1 % of `main`'s, the first `read_span` on a handle
  42–76 % faster on the 10k corpora, a later `read_span` of a 1.1 MB file
  about +2 % CPU (`docs/evidence/s6-t7/phase2/timing/`).

Per-section bytes, timings and memory are in `docs/tasks/S6-T7.md`.

# Source section format v1

Status: implemented in `zig/src/source.zig` (S3-T1). Magic `HYBSRC01`, file
`source-N.hybsrc`, bound to its generation by [manifest v2](manifest-format-v2.md).
Design: [`folder-knowledge-implementation.md`](folder-knowledge-implementation.md) §4.

Chunks are stripped and joined with LF, and `md-section-v1` leaves front matter
out of the body, so a chunk cannot give back a file's bytes. The source section
keeps one copy of every retained file's original bytes with a line map, so
`read_span` is byte-exact (CAP-19 FR-22, review finding 2).

## Lines

A line is a `str.splitlines` line of the original bytes, the same lines the
chunkers number: LF, CR and CRLF (one terminator), and VT, FF, FS, GS, RS,
NEL (U+0085), LS (U+2028) and PS (U+2029) each end a line. A final line without
a terminator counts; an empty file has no lines. A leading UTF-8 byte order
mark is not part of line 1 (line 1 starts at byte 3). Lines `a..b` are the
bytes from the start of line `a` to the start of line `b + 1` (the end of the
file after the last line), so every terminator in the range, the last line's
own included, comes back as written.

## Layout (little-endian)

```text
u8[8]  magic "HYBSRC01"
u16    version = 1
u16    flags              // bit 0 (S4-T1): the checksum is XXH3-64; other bits zero
u32    file_count
u64    files table bytes
u64    line maps bytes
u64    text bytes
u64    checksum           // FNV-1a 64 (flags 0) or XXH3-64 (flags bit 0) over header bytes 0-39, then every payload byte
-- files table: file_count records, strictly sorted by path bytes
   u32 path_length
   u64 text_offset        // into the text area; files are laid out in table order without gaps
   u64 text_length
   u32 line_count
   u64 line_map_offset    // into the line-map area; maps in table order without gaps
   u8[32] sha256          // of the file's original bytes
   u8 encoding            // 0 = UTF-8, 1 = UTF-8 with a BOM (line 1 starts at byte 3)
   u8[3] reserved (zero)
   path bytes             // root-relative POSIX path: no leading '/', no '.' or '..' part, no NUL/CR/LF
-- line maps: per file, line_count + 1 unsigned LEB128 varints, delta coded:
   the offset of line 1's start (0, or 3 with a BOM; for an empty file, the
   file length), then each following line start and finally the file length,
   each as the gap from the previous value
-- text: the original bytes of every retained file, concatenated
```

The header is 48 bytes; a record is 68 bytes plus its path.

`source.open` validates everything before answering: magic, version, flags,
declared size, checksum, every record's bounds, path rules and order, the
gap-free layout, the encoding byte against the bytes, and each line map
against the file's own bytes (recomputed without allocating). `openIndexed`
adds a record-offset table so a path lookup is a binary search. Since
S4-T14 the reader's streamed open and the writer's open (`openTable`) check
all of that except the last two: each map is bounded by its varints instead
(`line_count + 1` of them must end inside the line-map area, else
`InvalidLineMap`), and a map and encoding byte are checked against their
file's bytes where the file is read ("Reading" below).

### Flags bit 0: XXH3-64 (S4-T1)

Every writer since S4-T1 sets flags bit 0 and checksums the section with
XXH3-64 (seed 0) over the same bytes FNV-1a 64 covered; the binding manifest
sets `xxh3_sections` ([manifest v2.1](manifest-format-v2.md#v21-xxh3-section-checksums-s4-t1)).
Sections written before (flags zero, FNV-1a) read as before. The version
stays `1`. On the 10,000-file corpus the section is 8.3 MB, so its checksum
was about a quarter of the FNV-1a work of one generation.

## Operations

`read_span(path, start_line, end_line, context_lines)` (`source.readSpan`):

- `context_lines` must be 0–20 (`invalid_argument`); `1 <= start_line <=
  end_line` and `start_line <= line_count` (`invalid_argument`); `end_line`
  past the last line is clamped to it; an unknown path is `not_found`.
- The lines including context (`start_line - context` to `end_line + context`,
  clamped to the file) must be at most 400 and their bytes at most 256 KiB,
  else `capacity` with the counts in the message.
- The answer: `start_line`, `end_line`, `text` (the bytes of the lines),
  `context_before`, `context_after`, `byte_exact: true`, `sha256` of `text`
  (`source.writeSpanJson`, the shape of implementation §8).
- A generation without a source section answers `capacity`
  `"re-index required: source absent"`.

`outline(path)` (`source.outline`): the file's line count and chunker; for a
Markdown file its headings (level, text, line, end line: the line before the
next heading of the same or a higher level, else the last line) and front
matter (`start_line`, `end_line`, `fields`; `raw` holds the inner lines when
they are not `key: value`). Front matter is part of the bytes, so `read_span`
returns it.

Both read one file and never load another (CAP-19 NFR-13). The refusal codes
map to the C ABI's `SS_ERR_INVALID_ARGUMENT` (-1), `SS_ERR_CAPACITY` (-4) and
`SS_ERR_NOT_FOUND` (-6) (`source.Code.ssError`); the ABI functions are
`ss_read_span` and `ss_outline` (S3-T4, contract 2.0.0).

**Sparse line index (S3-T4, no format change).** `source.openIndexed`
records, while it validates each line map, a checkpoint before every 256th
varint (the map offset and the running value), so `read_span` finds a line
by decoding at most 256 varints from the nearest checkpoint instead of every
varint from line 1. `(line_count / 256 + 1)` checkpoints of 16 bytes per
file; a section opened with plain `source.open` has none and decodes from
line 1, as before. Since S4-T14 a streamed section (the reader's,
"Reading" below) has none either: its maps are not decoded at first use,
and each call reads and hashes its whole file anyway, so decoding the map
from line 1 is a small part of the call. A lost or damaged source section does not fail opening a
generation (`snapshot_open.openSource` reports `source_error`); only
`read_span` and `outline` answer `capacity` "re-index required: source
section unavailable (<error>)".

## Reading (S4-T10, S4-T14, no format change)

An opened generation reads its source section at the first `read_span` or
`outline` (`scope.Loads.readSource`, `source.openStreamed`), not earlier:
`index_status` reports `unverified` until then and `verified` or
`unavailable` after, as before. That first use reads the header, the files
table and the line maps into one exact block from the handle's parent
allocator (freed at close; 1,009,678 B at 10,000 files, 1,519,423 B at
15,000, 2,029,348 B at 20,000 on the generated corpus) and keeps them, with
the record-offset table. It walks the files table with `open`'s rules
(bounds, path rules and order, gap-free text and map offsets) and bounds
each line map by its varints, and it streams the text area once through a
buffer of at most 1 MiB (`source.stream_buffer_bytes`, freed before it
returns) to compute the section checksum, compared with the header's and the
manifest's value. It keeps none of the text and, since S4-T14, checks no
line map against its bytes and builds no sparse line index. Every failure
there (size, checksum, a malformed table, a map whose varints miss its
region) makes the section `unavailable` for every file, as before.

Each later call finds its record by binary search, reads that file's
`text_length` bytes at its `text_offset` into the call's allocator
(`source.Section.fileBytes`, freed with the call) and checks them against
the record's SHA-256 before it answers. A file whose bytes no longer match
answers `capacity` "re-index required: source section unavailable
(SourceFileSha256Mismatch)" (a short read answers
`(SourceSectionSizeMismatch)`). **S4-T14:** the first time a handle reads a
file, those checked bytes are also walked against the file's line map and
encoding byte by `open`'s rules (`validateLineMap`). A map that disagrees
answers `capacity` "re-index required: source section unavailable
(InvalidLineMap)" for that file, at every call; every other file answers.
A file that passes is recorded in one bit per file (`Section.checked`, from
the handle's arena: 1,256 B at 10,000 files, 1,880 B at 15,000) and is not
walked again on that handle. Because an unchecked map is never decoded, a
`read_span` of a file not yet checked on the handle reads and checks it
before the 400-line and 256 KiB limits are computed: a refused span reads
nothing only for a file already checked on the handle, and the first request
to a damaged file answers the integrity message, not the size limit's.
`index_status` is not changed by a per-call failure. The answers are byte
for byte those of the resident reader (`scripts/source_read_parity.py`). The
SHA-256 costs about 0.34 ms per MiB on the Mac (`ReleaseSmall`): 0.36 ms for
the 1,133,158-byte largest file of `fixtures/family-folder`, about 1 µs for a
4 KiB file.

**The writer's guard (S4-T13, S4-T14).** A writer reads its previous
generation's source section whole (`apply.openPrevious`). It computes the
section checksum once (`source.inspect`, against the header's value, which
must equal the manifest's: `ChecksumMismatch`, `SourceSectionChecksumMismatch`),
then walks the files table and bounds every line map by its varints
(`source.openTable`: `open`'s table rules and error names), before it
carries any record into the next generation. The checksum refuses a damaged
section; the table walk and the varint bounds refuse a malformed one. A
checksum-valid map that disagrees with its bytes can only come from a wrong
writer. Since S4-T14 such a map is carried as it is and costs its one file
its `read_span` and `outline` (`capacity`, `InvalidLineMap`) until an update
changes that file's bytes and scans them afresh. So neither the reader at
first use nor the writer at its open walks every map. (S4-T13 kept the
writer's walk because the reader then refused such a section whole, every
file answering `InvalidLineMap`.)

## Retention

`index_folder` retains every file it indexes (`indexer.Caps.retain_source`,
default true in S3-T1, ruling 4). An incremental update retains the bytes it
reads; a file it does not read this run (unreadable, over the run's byte
budget) keeps its bytes from the previous generation's source section when
they were there. With retention off no source section is written and the
manifest's `has_source` is false.

Measured cost (S3-T1 Report): on the family-folder fixture the three roots
retain 1,150,039 bytes of files in source sections totalling 1,170,330 bytes;
on the 10,000-file benchmark corpus 7,269,199 bytes of files take 8,279,041
bytes (the 890,000-byte file table is most of the overhead).

## Python reference

`search_platform.core` keeps no copy: `read_span`/`outline` re-read the file
under the index root and refuse with `not_found` "stale: …" when its sha256 no
longer matches the one recorded at index time (the `retain_source: false`
path of implementation §4). `core.line_starts` is the same line map.

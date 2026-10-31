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
u16    flags = 0
u32    file_count
u64    files table bytes
u64    line maps bytes
u64    text bytes
u64    checksum           // FNV-1a over header bytes 0-39, then every payload byte
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
adds a record-offset table so a path lookup is a binary search.

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
`SS_ERR_NOT_FOUND` (-6) (`source.Code.ssError`); the ABI functions themselves
arrive with S3-T4.

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

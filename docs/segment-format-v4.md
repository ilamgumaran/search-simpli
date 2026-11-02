# Immutable document/vector segment format v4 (minor version 4.1)

Status: implemented in `zig/src/segment.zig` (S3-T1; v4.1 since S4-T1, see
[v4.1](#v41-section-checksum-s4-t1)). Magic `HYBSEG01`,
header layout unchanged (36 bytes, checksummed). `searchd index` writes record v4
(`segment.encodeV4`); `import-json` keeps writing [v3](segment-format-v3.md)
byte for byte (`segment.encode`). The reader decodes v1–v4. Design:
[`folder-knowledge-implementation.md`](folder-knowledge-implementation.md) §2.

## Per-document record

All integers little-endian:

```text
u32 id_length
u32 path_length
u32 text_length
u32 vector_length
u32 start_line
u32 end_line
u32 required_labels_length
u16 chunker_index          // v4: index into the manifest's meta.chunkers; 0 = line-window-v1
u16 section_depth          // v4: number of section_path entries; 0 for line windows and preambles
u32 heading_line           // v4: 1-based line of the section's heading; 0 when none
u32 source_doc_index       // v4: index into the source section's file table; 0xFFFFFFFF when not retained
u32 section_path_length    // v4
id bytes
path bytes
text bytes
required-label bytes
vector_length * f32 bytes
section_path bytes         // v4: UTF-8 heading texts, H1 first, joined by U+001F
```

The fixed part is 44 bytes (v3: 28). The variable runs keep v3's order and
`section_path` comes last.

Validation (encode and decode): `section_depth` 0 means an empty
`section_path`; otherwise the path holds exactly `section_depth` entries
(`count(U+001F) + 1`, an entry may be empty for a heading with no text); a
section with a depth has a heading line, and a heading line is at or above the
chunk's `start_line`. `chunker_index` against `meta.chunkers` and
`source_doc_index` against the source section are checked where both are
loaded (the S3-T1 fixture test checks that every record names its own file and
the chunker its extension selects).

The chunk id is unchanged: `sha256(path \0 start \0 end \0 text)[:20 hex]`
over the chunk's normalized text.

## Compatibility

- v1–v3 records decode with `chunker_index` 0, `section_depth` 0,
  `heading_line` 0, `source_doc_index` 0xFFFFFFFF and an empty path.
- `segment.encode` (v3) refuses a document that carries any v4 field
  (`error.RequiresVersion4`) rather than dropping it.

## v4.1: section checksum (S4-T1)

The header's u16 flags field (offset 10), written zero and ignored by readers
before S4-T1, now has one bit: bit 0 selects XXH3-64 (seed 0, over header
bytes before the checksum and then the payload, exactly the bytes FNV-1a
covered) as the section checksum; clear means FNV-1a 64 as before. Any other
bit is refused (`UnsupportedFlags`). Record v4 (the folder writers) always sets
bit 0; record v3 (`import-json`) never does. The manifest that binds an XXH3
section sets its own bit 2 ([manifest v2.1](manifest-format-v2.md#v21-xxh3-section-checksums-s4-t1)).
A reader before S4-T1 that met such a section would fail its checksum, but it
never gets that far: it refuses the v2.1 manifest first. Implementation:
`zig/src/checksum.zig`.

## What the fields carry

`md-section-v1` (`zig/src/chunker_md.zig`, `search_platform.core._md_section_chunks`)
fills `section_path`, `section_depth` and `heading_line`; `line-window-v1`
leaves them empty. `source_doc_index` points at the file's original bytes in
the generation's [source section](source-section-v1.md), which `read_span` and
`outline` use.

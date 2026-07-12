# Document/vector segment format v2

Status: legacy citation-bearing format. Current writers emit v3 with authorization labels; the reader accepts v1, v2, and v3.

The family magic remains `HYBSEG01`; the header’s format version is now `2`. The 36-byte header layout and checksum rule remain unchanged from v1. V2 adds source citation metadata to each document/chunk record.

## V2 document record

| Size | Field |
|---:|---|
| 4 | chunk id byte length |
| 4 | source path byte length |
| 4 | stored text byte length |
| 4 | vector element count |
| 4 | citation start line |
| 4 | citation end line |
| variable | chunk id bytes |
| variable | source path bytes |
| variable | stored UTF-8 text bytes |
| `count * 4` | little-endian IEEE-754 `f32` vector bits |

If the path is non-empty, start line must be at least one and end line must be greater than or equal to start. Chunks without citation metadata must use an empty path and zero line values. Mixed partial states are rejected.

## Compatibility

V1 records contain only id/text/vector lengths and bytes. The v2 reader recognizes header version `1`, decodes that older layout, and exposes an empty path with zero lines. A dedicated compatibility test constructs v1 bytes and loads them through the current reader.

The writer emits only v2. Existing v1 snapshots can be queried but will not provide source citations until reindexed.

## Result propagation

`hybrid.Document` and `hybrid.Result` now carry path, start line, and end line. `engine.Engine.evidence` joins a ranked result with its authoritative stored content and exposes:

- chunk id;
- source path and line span;
- content;
- fused score;
- lexical and semantic scores/ranks.

This is the Zig equivalent of the Python `search_knowledge` evidence envelope’s core result item.

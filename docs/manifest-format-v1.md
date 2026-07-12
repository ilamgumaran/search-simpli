# Generation manifest format v1

Status: implemented in `zig/src/manifest.zig`. Magic: `HYBMAN01`.

The manifest is the single atomic visibility point for one coherent search snapshot. It binds a `HYBSEG01` document/vector section to a `HYBLEX01` lexical section and pins the analyzer and embedding identities used to interpret them.

## Header

All values are little-endian.

| Offset | Size | Field |
|---:|---:|---|
| 0 | 8 | magic `HYBMAN01` |
| 8 | 2 | version `1` |
| 10 | 2 | flags, currently zero |
| 12 | 8 | generation number |
| 20 | 4 | shared document count |
| 24 | 4 | vector dimensions |
| 28 | 4 | lexical term count |
| 32 | 4 | reserved |
| 36 | 8 | posting count |
| 44 | 8 | document/vector section byte length |
| 52 | 8 | document/vector internal checksum |
| 60 | 8 | lexical section byte length |
| 68 | 8 | lexical internal checksum |
| 76 | 4 | variable payload byte length |
| 80 | 8 | manifest checksum |

The manifest checksum is FNV-1a over header bytes 0–79 followed by the payload. It is accidental-corruption detection, not cryptographic authentication.

## Payload

Four length-prefixed byte strings, each encoded as unsigned 32-bit length plus bytes:

1. analyzer id, such as `ascii-alnum-v1`;
2. embedding model id, or an explicit `none`;
3. document/vector section filename;
4. lexical section filename.

Identifiers must be non-empty and contain no NUL/newline bytes. Section filenames must be safe basenames: no separators, `.`/`..`, NUL, or newline. Both filenames must differ.

## Cross-section validation

Creating or loading a snapshot validates:

- each referenced section’s own magic, version, declared size, and checksum;
- exact file byte lengths and internal checksums against the manifest;
- the same document count in both sections and the manifest;
- vector dimensions, lexical term count, and posting count;
- analyzer and embedding identities;
- safe immutable filenames and nonzero generation.

A manifest cannot make incompatible byte sections look coherent merely because each one is independently valid.

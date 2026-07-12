# Immutable document/vector segment format v3

Status: current writer format. The reader remains compatible with v1 and v2.

V3 extends `HYBSEG01` document records with persisted authorization requirements while preserving the 36-byte checksummed segment header.

## Per-document record

All integers are little-endian:

```text
u32 id_length
u32 path_length
u32 text_length
u32 vector_length
u32 start_line
u32 end_line
u32 required_labels_length
id bytes
path bytes
text bytes
required-label bytes
vector_length * f32 bytes
```

The required-label field is empty for public documents. Otherwise it is a strictly sorted, unique, newline-separated list. Individual labels cannot be empty or contain NUL, CR, or LF. Encoding rejects noncanonical data; the importer canonicalizes JSON arrays before encoding; decoding validates again after checksum verification.

This representation lets document ids, paths, text, and label bytes borrow the immutable segment directly. Only aligned vectors are copied into caller-owned storage.

## Compatibility

- V1 has id, text, and vectors only; path/lines/labels decode empty.
- V2 adds path and line citations; labels decode empty.
- V3 adds required labels.

Because older records have no authorization metadata, they are interpreted as public. An authorization deployment must rebuild old snapshots rather than assuming unlabeled legacy data is protected.

Checksums remain accidental-corruption checks, not authenticity signatures. Access control depends on trusted index construction/publication and filesystem/process protections in addition to query filtering.

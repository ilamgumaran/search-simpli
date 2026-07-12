# Immutable segment format v1

Status: legacy reader format. It remains round-trip compatibility tested; current writers emit v3 with citation and authorization metadata. See `docs/segment-format-v3.md`.

All integers and `f32` bit patterns are little-endian. The format is deliberately simple so correctness, corruption behavior, and evolution rules are explicit before compression is introduced.

## Header

| Offset | Size | Field | Meaning |
|---:|---:|---|---|
| 0 | 8 | magic | ASCII `HYBSEG01` |
| 8 | 2 | version | unsigned format version, currently `1` |
| 10 | 2 | flags | reserved, currently zero |
| 12 | 4 | document count | number of document/chunk records |
| 16 | 4 | vector dimensions | dimensions for every non-empty vector; zero if none |
| 20 | 8 | payload length | bytes following the 36-byte header |
| 28 | 8 | checksum | FNV-1a over header bytes 0–27 followed by the payload |

The checksum is designed to detect accidental corruption, not malicious modification. Authenticity requires a cryptographic digest or signature at a manifest/distribution layer.

## Document record

Records are concatenated in header-declared order:

| Size | Field |
|---:|---|
| 4 | id byte length |
| 4 | stored text byte length |
| 4 | vector element count |
| variable | id bytes |
| variable | UTF-8 stored text bytes |
| `count * 4` | IEEE-754 `f32` vector bits |

An empty vector has count zero. Every non-empty vector must match the header dimensions.

## Reader invariants

The reader rejects:

- bad magic or unsupported versions;
- truncation or trailing bytes;
- metadata or payload checksum mismatch;
- inconsistent encoded vector dimensions;
- arithmetic overflow;
- insufficient caller-owned document or aligned-vector storage.

Ids and text are zero-copy slices into the encoded byte buffer. Vectors are decoded into caller-owned `f32` storage because arbitrary byte payload offsets cannot be assumed to meet native alignment requirements.

## What v1 is and is not

V1 is an immutable stored-document/vector container and persistence oracle. It proves stable bytes, checksums, capacity behavior, and ranking preservation across a round trip.

It is not yet a scalable lexical segment. It has no term dictionary, postings, positions, tombstones, compression, manifest, write-ahead log, or atomic filesystem publication. Those structures should either be added as separately checksummed sections in a later version or composed as separate files under one manifest. Existing v1 readers must continue rejecting unknown versions rather than guessing.

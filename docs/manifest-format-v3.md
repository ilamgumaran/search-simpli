# Generation manifest v3: filename field alongside S3

Magic HYBMAN03, version 3. Integers little-endian. Version 1 (88-byte header)
and main's version 2 (104-byte header) retain their readers and writers.
The conflicting CAP-16 draft HYBMAN02 is unsupported: rebuild separately.

V3 retains v2 offsets 0–91, including source length/checksum and the source
and positional flags. It adds:

| Offset | Bytes | Field |
|---:|---:|---|
| 92 | 4 | filename catalog file count |
| 96 | 4 | filename lexical term count |
| 100 | 8 | filename lexical posting count |
| 108 | 8 | catalog byte length |
| 116 | 8 | catalog internal checksum |
| 124 | 8 | filename lexical byte length |
| 132 | 8 | filename lexical internal checksum |
| 140 | 4 | payload byte length |
| 144 | 8 | manifest checksum |

Header length: 152. The checksum covers header bytes 0–143 and all payload
bytes. Payload has nine u32-length-prefixed UTF-8 strings: v2's analyzer,
embedding model, documents filename, body lexical filename, source filename
(or empty), meta JSON, then filename catalog filename, filename lexical
filename and policy id `filename-field-v1`. V3 requires both filename
sections. All section names are safe, distinct basenames, including source.

Files: `filenames-N.hybseg` and `filename-lexical-N.hyblex`, in addition to
S3's documents, lexical and optional source. Both filename sections have
zero vector dimensions, equal file count, matching term/posting counts and
bound byte lengths/checksums. The decoded catalog must match document paths,
labels and real passage anchors. Visible root masks apply using the body's
anchor ordinal, never the catalog's differently sorted ordinal; df and
average length are computed from the same visible scope.

Every bound section is synced and linked without replacement before the
directory sync and atomic MANIFEST replacement. Pre-commit failures remove
only files this publication created; post-commit errors preserve the whole
visible generation. Generation allocation and retention include filename
files. Source remains optional for reads that do not need it, as in S3.

New S3 writes also include `meta.recovery_state`, the encoded state-v2 object
for that generation, whether filename indexing is enabled (manifest v3) or
not (manifest v2). The manifest checksum binds it; cache loss/corruption
cannot discard own labels, hashes, mtime or move provenance. Older readers
ignore this optional JSON key. Older indexes retain the conservative legacy
recovery path until a new generation upgrades them.

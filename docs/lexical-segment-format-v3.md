# Immutable lexical segment format v3 (`HYBLEX03`)

Status: **implemented** in `zig/src/lexical_segment.zig` (S6-T4, 16 Nov
2026; designed and measured in its Phase 1, built in Phase 2 after the
orchestrator's ruling). Every folder writer (`searchd index`, `searchd
apply`, `searchd search`'s in-memory build, `ss_index_folder`,
`ss_apply_changes`) writes it for both lexical sections, under
[manifest v2.3](manifest-format-v2.md#v23-lexical-sections-v3-s6-t4). Every
reader reads `HYBLEX01`, `HYBLEX02` and `HYBLEX03`. Companion to
[`lexical-segment-format-v2.md`](lexical-segment-format-v2.md) and
[`index-size.md`](index-size.md) (candidates C1, C2b, C3 and F2, which this
format builds).

V3 keeps v2's five sections in the same order and recodes the first three:
document lengths as varints (C3), the dictionary front-coded (C1), and each
term's postings as gaps with the term frequency folded into the gap (C2b).
Sections 4 (positions) and 5 (offsets) are byte for byte v2's and are not
recoded here (offsets are D2 step 3). The same format serves the content
section (sections 4 and 5 present) and the file-name section (absent); the
file-name section's dictionary becomes sorted, as the content section's has
been since v2. All integers are little-endian; a varint is unsigned LEB128,
at most five bytes, value below 2^32 (`postings.readVarint`'s rules: a sixth
byte, or a fifth byte above 0x0F, is damage).

## Header (88 bytes)

| Offset | Size | Field | Meaning |
|---:|---:|---|---|
| 0 | 8 | magic | ASCII `HYBLEX03` |
| 8 | 2 | version | `3` |
| 10 | 2 | flags | bit 0: XXH3-64 checksum, **required**; bit 1: sections 4 and 5 present; any other bit rejected |
| 12 | 4 | document count | below 2^31 |
| 16 | 4 | term count | |
| 20 | 8 | posting count | the sum of every term's document frequency |
| 28 | 4 | average document length | IEEE-754 `f32` bits, finite and ≥ 0, as v2 |
| 32 | 8 | document-length bytes | section 1 |
| 40 | 8 | dictionary bytes | section 2 |
| 48 | 8 | postings bytes | section 3 |
| 56 | 8 | positions bytes | section 4 (0 when flags bit 1 is clear) |
| 64 | 8 | offsets bytes | section 5 (0 when flags bit 1 is clear) |
| 72 | 8 | term text bytes | the dictionary's terms laid end to end, decoded |
| 80 | 8 | checksum | XXH3-64 (seed 0) over header bytes 0–79 followed by every payload byte |

The term text length is in the header so a reader can allocate the decoded
terms in one exact block before the walk (v2's terms were zero-copy slices of
the section; front coding removes that). Flags bit 1 replaces v2's "magic
names the sections" rule, so one magic serves both lexical sections; the
manifest's `has_positions` must equal it for the content section, and the
file-name section must clear it.

## Section 1: document lengths

One varint per document, in document order: its token count. Exactly
`document count` varints; no byte left over.

## Section 2: dictionary

One entry per term, in strictly increasing byte order (`std.mem.order`):

| Field | Coding | Rule |
|---|---|---|
| shared | varint | bytes shared with the previous term, at most 255; 0 for the first; at most the previous term's length |
| suffix length | varint | ≥ 1 |
| suffix | bytes | the term's bytes after the shared prefix |
| df | varint | the term's document frequency, 1 ≤ df ≤ document count |
| list bytes | varint | the byte length of this term's list in section 3, ≥ df |

`shared` is the common prefix of the two terms, capped at 255 bytes. The cap
bounds the decoded text by the section's own size (every term is at most 255
bytes plus its suffix, so the term text is at most 255 × term count +
dictionary bytes), which lets the reader check the header's term-text bytes
before allocating them; without it a section of a few kilobytes could ask for
gigabytes of term text and still pass every other rule. (No term in the
measured corpora shares more than 29 bytes, so the cap changes no byte there.
The analyzers set no term-length limit — a token is a maximal run of letters
and digits — so longer shared prefixes can occur; a test indexes two terms
sharing 300 bytes.)

Order and canonical form in one check: when `shared` is less than both the
previous term's length and 255, the suffix's first byte must be greater than
the previous term's byte at `shared`. That rules out duplicates, descending
pairs and a `shared` shorter than the true common prefix. `shared` equal to
the previous length makes the term a strict extension of it, which is
ascending. `shared` equal to 255 and shorter than the previous term (only
terms of over 255 bytes) compares the rest of the two terms bytewise, which
must be ascending. The decoded term — the previous term's first `shared` bytes then the suffix — is
not checked for UTF-8, as v2's are not.

Term *i*'s list starts in section 3 where term *i − 1*'s ends (the first at
0); its postings are numbered from the sum of the earlier dfs, as v2's
contiguous term ranges. `list bytes` costs one or two bytes a term (measured:
24,114 B of the timing corpus's 5,396,552 B section; 6,252 of prose's
13,244,927; 21,632 of Tamil's 5,555,692; 10,002 to 12,936 of the file-name
sections' 92,952 to 146,333). It lets a reader find a term's list without decoding
the lists before it, which only a lazy reader needs; today's reader is eager
and checks it. It is kept (the S6-T4 ruling) so that a later lazy reader
needs no format change.

## Section 3: postings

For each term in dictionary order, its df postings in strictly increasing
document order, each one or two varints:

- `(gap << 1) | (tf == 1)`, where the first posting's gap is its document
  number and every later one's is the difference from the previous document
  (≥ 1);
- then, only when the low bit is 0, the term frequency as a varint (≥ 2).

So a posting with tf 1 is one varint; the gap fits in 31 bits, which is why
the document count is below 2^31. A list must decode exactly its `list bytes`
and its df postings.

## Sections 4 and 5

Present exactly when flags bit 1 is set; byte for byte v2's
([positions](lexical-segment-format-v2.md#section-4-positions),
[offsets](lexical-segment-format-v2.md#section-5-offsets)), with every v2 rule.
Section 4's per-posting ordinals follow section 3's posting order, which is
v2's (term-major in dictionary order).

## Validation

In this order; any failure is the existing corruption error (`InvalidLexicalSection`
at the manifest binding, `SS_ERR_CORRUPT_SNAPSHOT` through the C ABI), never
a partial index:

1. **Header.** Magic, version, flags (bit 0 set, no unknown bit), then the
   declared total (88 + the five section lengths, with overflow checks)
   equal to the file's bytes: shorter is `Truncated`, longer `TrailingData`.
2. **Checksum** over the whole section, before any count is trusted.
3. **Bounds the counts imply**, before any allocation sized by them:
   document count below 2^31; document-length bytes between the document
   count and five times it; postings bytes ≥ posting count; dictionary bytes
   ≥ five times the term count; term text ≥ term count; posting count ≥ term
   count; term text at most 255 × term count + dictionary bytes (the shared
   cap); positions and offsets bytes 0 when flags bit 1 is clear.
4. **Section 1**: exactly document count varints, no byte left over.
5. **Section 2**: each entry's rules above; the decoded term text never
   passes the header's term-text bytes, and at the end equals it exactly;
   the dfs sum to the posting count; the list bytes sum to the postings
   bytes; no byte left over.
6. **Section 3** (each list): every gap after the first ≥ 1 (a zero gap is
   damage), every document below the document count (so strictly rising and
   in range), every tf ≥ 2 when stored, exactly df postings in exactly the
   list's bytes.
7. **Sections 4 and 5**: v2's rules (every ordinal below its document's
   length, offsets' token counts equal to the document lengths, no byte left
   over).
8. **Manifest binding**: the manifest's term and posting counts and checksum
   equal the header's; its `lexical_v3` flag set exactly when the section is
   `HYBLEX03` (both lexical sections); `has_positions` equal to flags bit 1
   on the content section.

The reader decodes everything at open (the S6-T4 ruling: strategy (i)), so
steps 1–6 run at `ss_open`, into the same arrays a v1 or v2 section decodes
to; only the decoded term text is new (one block of `term text bytes`,
allocated after step 3). Step 7 is lazy, as for v2 (the first `ss_find`,
S4-T1). A later reader that decodes lists at first use must either run step
6 at open as a decode-and-discard walk or fail the first operation that
decodes a damaged list with `SS_ERR_CORRUPT_SNAPSHOT`.

### A damaged or truncated section

The checksum covers every byte, so a truncated, cut or flipped section fails
step 1 or 2 at open (`ss_open` returns null, `SS_ERR_CORRUPT_SNAPSHOT`) and
no list is decoded. Steps 3–7 catch a section whose checksum is right but
whose content is not: a writer bug, or a file made to pass the checksum. Such
a section is refused — the open, or under a lazy strategy the first
operation that reaches the bad list, fails with the corruption error, and
every later operation on that handle fails the same way — and is never read
as a different index. Nothing is repaired or skipped: the remedy is a
re-index, as for any damaged section.

## Manifest binding

Manifest v2.3 adds flag bit 5 `lexical_v3` (`0x20`) to `HYBMAN02`, after
S4-T1's v2.1 precedent (bit 2, `xxh3_sections`): a library that does not know
bit 5 refuses the manifest with `UnsupportedFlags` before reading any section,
so an old library meets a v3 index as a corrupt snapshot, cleanly, never as a
misread. A v1 manifest cannot bind `HYBLEX03`. Without the bit an old reader
would still refuse (`HYBLEX03` is an unknown magic), but at the section, after
the manifest has been accepted; the bit makes the refusal happen at the first
read and names it.

## Writers and readers

- `searchd index` (full and `--update`) and `searchd apply` write v3 for both
  lexical sections. `import-json` writes what it wrote before v3, byte for
  byte: `HYBLEX01` under its v1 manifest, and with the file-name channel both
  lexical sections `HYBLEX01` under a v2 manifest without bit 5
  (`filename_field.buildV1`; `tests/fixtures/import-filename-98c4a2b/` is
  98c4a2b's output, and `zig/src/compat_98c4a2b_test.zig` checks the bytes).
- Every reader reads `HYBLEX01`, `HYBLEX02` and `HYBLEX03`. A writer caps a
  common prefix of more than 255 bytes at 255 (the suffix carries the rest;
  no term is shortened or refused). An update whose
  previous generation is v2 decodes it as today and publishes v3: the content
  section's carried postings, positions and offsets are carried as they are;
  the file-name section is rebuilt once (as a `HYBLEX01` file-name section is
  carried today only when it is checksummed and `HYBLEX01`, v3 changes the
  carry rule to `HYBLEX03`), then carried.

## Deliberate limitations

No skip data, block maxima or per-block offsets inside a list (measured
unnecessary at these sizes; see the S6-T4 Report). Positions and offsets are
not recoded. The term frequency of a posting with tf ≥ 2 costs a separate
varint even when small.

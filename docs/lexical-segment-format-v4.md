# Immutable lexical segment format v4 (`HYBLEX04`)

Status: **specified first** (S6-T8, 17 Nov 2026, plan item D2 step 3,
candidate C5b of [`index-size.md`](index-size.md)); implemented in
`zig/src/lexical_segment.zig` (header, validation) and `zig/src/postings.zig`
(section 5's coding, position tables, token spans). Every folder writer
(`searchd index`, `searchd apply`, `searchd search`'s in-memory build,
`ss_index_folder`, `ss_apply_changes`) writes it for the **content** lexical
section, under [manifest v2.5](manifest-format-v2.md#v25-lexical-section-v4-s6-t8).
The file-name lexical section has no sections 4 and 5 and stays
[`HYBLEX03`](lexical-segment-format-v3.md). Every reader reads `HYBLEX01`,
`HYBLEX02`, `HYBLEX03` and `HYBLEX04`.

V4 is v3 with section 5 (the highlight offsets `find` reads) recoded at one
byte per token. The header, sections 1 to 4 and every v3 rule are unchanged;
what `find` returns does not change. All integers are little-endian; a
varint is unsigned LEB128, at most five bytes, value below 2^32
(`postings.readVarint`'s rules: a sixth byte, or a fifth byte above 0x0F, is
damage; an overlong form within five bytes, such as `8F 00` for 15, is
accepted, as every varint of v3 and of record v5 is; a writer never writes
one).

## Header (88 bytes)

Byte for byte [v3's header](lexical-segment-format-v3.md#header-88-bytes),
with three fields fixed:

| Offset | Size | Field | v4 value |
|---:|---:|---|---|
| 0 | 8 | magic | ASCII `HYBLEX04` |
| 8 | 2 | version | `4` |
| 10 | 2 | flags | exactly `0x0003`: bit 0 (XXH3-64 checksum) and bit 1 (sections 4 and 5 present) both set; any other value is refused: the section's own header check names it `UnsupportedFlags`, but through a manifest (`ss_open`, the CLI and every surface) the manifest's check of its sections runs first and the open fails with `InvalidLexicalSection`, as for v3 |

Every other field (document, term and posting counts, the average document
length, the five section lengths, the term text bytes, the checksum over
header bytes 0–79 then every payload byte) has v3's meaning and v3's rules.
A v4 section always carries sections 4 and 5, because the only section v4
changes is section 5; a section without them is written `HYBLEX03`.

## Sections 1 to 4

Byte for byte v3's: [document lengths](lexical-segment-format-v3.md#section-1-document-lengths),
[the front-coded dictionary](lexical-segment-format-v3.md#section-2-dictionary),
[the gap-coded postings](lexical-segment-format-v3.md#section-3-postings) and
[the token ordinals](lexical-segment-format-v2.md#section-4-positions), with
every rule of each.

## Section 5: offsets, one byte per token

For each document in document order (the order of section 1):

1. its **token count**, a varint, equal to the document's length in section 1;
2. then, per token in text order, one **token byte**, then at most two
   **escape varints**.

What a token describes is unchanged from v2: its range in the chunk's stored
text (the document record's `text`, which is what a hit's `content` is), in
Unicode codepoints, as a start and a length (≥ 1), mapped back from the NFC
form ([v2 § Section 5](lexical-segment-format-v2.md#section-5-offsets)).

### The token byte

| Bits | Field | Value |
|---|---|---|
| 0–3 (low nibble) | gap field `G` | `min(z, 15)`, where `z` is the zigzag form of the token's gap |
| 4–7 (high nibble) | length field `L` | `min(length, 15)` |

So the byte is `G | (L << 4)`.

- **The gap** is the token's start minus the **previous token's end** (start
  plus length), in codepoints; for the first token of each document the
  previous end is 0, so its gap is its start. Every document's table is
  therefore self-contained: a writer that carries a document copies its bytes
  unchanged.
- **Zigzag.** A gap `g` is coded as `z = 2g` when `g ≥ 0` and `z = −2g − 1`
  when `g < 0` (0 → 0, −1 → 1, 1 → 2, −2 → 3, …, 7 → 14, −8 → 15, 8 → 16).
  Decoding: `g = z / 2` when `z` is even, `g = −(z + 1) / 2` when it is odd.
- **A negative gap** occurs: a token's range may begin before the previous
  token's end. NFC works on regions (an inert codepoint before a run of
  non-inert ones); a region NFC changes maps every one of its normalized
  codepoints to the whole region, so two tokens inside one changed region
  both cover it. For example `a` U+037E U+2126 (GREEK QUESTION MARK, which
  NFC maps to `;`, and OHM SIGN, mapped to Ω) is one region of three
  codepoints, and its tokens `a` and `ω` both cover codepoints 0 to 3: the
  second token's gap is 0 − 3 = −3 (`z` = 5). The writer keeps every start at
  or after the previous token's start (`lexical_build.buildPositional`,
  `apply.buildPositionalFresh`), so a gap is never below minus the previous
  token's length.

### The escapes

A field whose value is 15 or more is written as 15 in its nibble, and its
**whole value** (not the value minus 15) follows as a varint, which must
therefore be 15 or more. When both fields escape, the gap's varint comes
first, then the length's. So a token takes 1 byte (both values below 15),
2 to 6 bytes (one escape) or 3 to 11 (both).

A nibble of 15 always means an escape; there is no other use of 15. A length
nibble of 0 is invalid (every token is at least one codepoint long); a gap
nibble of 0 is a token that starts where the previous one ends.

### Decoding one document

```
count = varint                      # equal to the document's length
end = 0; start = 0
repeat count times:
    byte = next byte
    G = byte & 0x0F;  L = byte >> 4
    if G == 15: G = varint          # must be >= 15
    if L == 15: L = varint          # must be >= 15
    previous_start = start
    start = end + unzigzag(G)       # must be >= 0 and >= previous_start
    length = L                      # must be >= 1
    end = start + length            # must be <= 2^32 - 1
    emit (start, length)
```

## Validation

Steps 1 to 6 are v3's ([Validation](lexical-segment-format-v3.md#validation)),
at `ss_open`: header (magic, version 4, flags exactly `0x0003`, the declared
total against the file), the checksum, the bounds, sections 1 to 3. Section 4
keeps v2's rules. Section 5's rules are below, each with the error that names
it. They run where v3's step 7 runs: lazily, before the first use of positions
or offsets (the first `ss_find`, S4-T1), over the whole section, except rule
11, which needs the chunk's text from the documents section and is checked
when a document's offsets become a returned `find` hit's highlights.

| # | Rule | Error |
|---:|---|---|
| 1 | Each document's token count is a complete varint | `OffsetsTruncated` (the section ends inside it), `OffsetsVarintOverflow` (a sixth byte, or a value of 2^32 or more) |
| 2 | Each document's token count equals its length in section 1 | `OffsetsCountMismatch` |
| 3 | Each token has its byte before the section ends | `OffsetsTruncated` |
| 4 | Each escape varint is complete before the section ends (an escape that overruns) | `OffsetsTruncated` |
| 5 | Each escape varint is well formed: at most five bytes, value below 2^32 | `OffsetsVarintOverflow` |
| 6 | Each escape's value is 15 or more (a smaller value would have been written in its nibble) | `OffsetsNonCanonicalEscape` |
| 7 | Each token's length is at least 1 (a length nibble of 0) | `OffsetsZeroLength` |
| 8 | Each token's start is at least 0: a negative gap never reaches before the chunk's first codepoint | `OffsetsStartBeforeChunk` |
| 9 | Each token's start is at least the previous token's start in the same document | `OffsetsStartDecreases` |
| 10 | Each token's end (start + length) fits a `u32` | `OffsetsEndOverflow` |
| 11 | Each token's end is at most the number of codepoints of its document's text (a decoded offset past the text) | `OffsetsPastText` |
| 12 | No byte is left over after the last document's last token | `OffsetsTrailingData` |

The section is checked document by document, in order, and the first rule
broken names the error. Within one document, the count is read (rule 1) and
compared with the document's length (rule 2) before any of its tokens is read,
so a wrong count is `OffsetsCountMismatch` even when the section would also
run out inside that document's tokens. Within one token the checks run in the
order of the decoding above: the token's byte (rule 3), the gap's escape
(rules 4–6), then the length's (4–6), then rules 7, 8, 9 and 10. A varint (a
count or an escape) is read byte by byte, and before each byte the section's
end is checked first: a varint whose last byte in the section still carries
the continuation bit is `OffsetsTruncated`, even after five such bytes; a
sixth byte present in the section is `OffsetsVarintOverflow`, as is a value of
2^32 or more. Every
error is a corruption error: `SS_ERR_CORRUPT_SNAPSHOT` through the C ABI, and
under the lazy strategy the first `find` and every later one on that handle
fail the same way, as for v3's step 7. Rule 11 fails the `find` that would
return a hit on that document (its text is in another section, so the
lexical section alone cannot check it), and never returns a highlight past
the text. The overlap check between neighbouring chunks (`deduplicate`)
reads offsets only as line numbers, which stop at the text's last line, so
it counts no codepoints and does not check rule 11. Nothing is
repaired or skipped: the remedy is a re-index.

Because the checksum covers every byte, a truncated, cut or flipped section is
refused at the open by v3's steps 1 and 2; rules 1 to 12 catch a section whose
checksum is right but whose content is not (a writer bug, or a file made to
pass the checksum).

## Worked example

Four documents, tokenized by `analyzer-v2` (every space is U+0020):

| Doc | Text | Tokens (start, length) |
|---:|---|---|
| 0 | `Ah` + 8 spaces + `incomprehensibilities ok` | `ah` (0, 2), `incomprehensibilities` (10, 21), `ok` (32, 2) |
| 1 | `x` + 20 spaces + `y abcdefghijklmnopq` | `x` (0, 1), `y` (21, 1), `abcdefghijklmnopq` (23, 17) |
| 2 | `a` U+037E U+2126 | `a` (0, 3), `ω` (0, 3) |
| 3 | `!!!` | none |

Section 5 is these 16 bytes (hex), one line per document:

```
03  20  FF 10 15  22        doc 0: 3 tokens
03  10  1F 28  F2 11        doc 1: 3 tokens
02  30  35                  doc 2: 2 tokens
00                          doc 3: no token
```

- Doc 0, `ah`: gap 0 (`z` 0), length 2: `0x20`. `incomprehensibilities`:
  previous end 2, gap 8, `z` = 16 ≥ 15 and length 21 ≥ 15, so both escape:
  `0xFF`, then 16 (`10`), then 21 (`15`), gap first. `ok`: previous end 31,
  gap 1 (`z` 2), length 2: `0x22`.
- Doc 1, `x`: `0x10`. `y`: previous end 1, gap 20, `z` = 40 escapes, length
  1: `0x1F` then 40 (`28`). `abcdefghijklmnopq`: previous end 22, gap 1
  (`z` 2), length 17 escapes: `0xF2` then 17 (`11`).
- Doc 2: `a` (0, 3): `0x30`. `ω` (0, 3): previous end 3, gap −3, `z` = 5:
  `0x35`.
- Doc 3: a count of 0 and no token byte.

The same four documents in v2's section 5 take 32 bytes (a `u32` count per
document and two varints per token). `zig/src/offsets_v4_test.zig` builds
these documents with the writer and checks these 16 bytes.

## Manifest binding

[Manifest v2.5](manifest-format-v2.md#v25-lexical-section-v4-s6-t8) adds flag
bit 7 `lexical_v4` (`0x0080`) to `HYBMAN02`: with it the content lexical
section must be `HYBLEX04`, without it it must not be (`InvalidLexicalSection`
either way). Bit 7 is set only with bit 5 (`lexical_v3`), whose rule it
narrows: under bits 5 and 7 the content section is `HYBLEX04` and a bound
file-name section `HYBLEX03`. A library before v2.5 refuses a v2.5 manifest on
bit 7 with `UnsupportedFlags` before it reads any section, so an old library
meets a v4 index as a clear refusal, never as a misread.

## Writers and readers

- Every folder writer writes the content section as `HYBLEX04`. `import-json`
  writes what it wrote before, byte for byte (`HYBLEX01`, no positions). The
  file-name section stays `HYBLEX03` and is carried as before.
- The first publish over an older directory (an update, `apply_changes`)
  writes one whole v2.5 generation: the content section's carried documents
  have their section 5 tables transcoded from v2's coding (token by token,
  the same starts and lengths), the fresh ones written in v4's; the result is
  byte for byte a fresh index's. The old generation stays whole until the
  manifest is replaced.
- That transcode accepts from a v2 table exactly what v2's validation
  ([v2](lexical-segment-format-v2.md)'s section 5 rules) accepts, and nothing
  is clamped or repaired: a count other than the document's length, a varint
  that does not read, a length of 0, an end past a `u32` or a table that does
  not end where the next begins fails the publish with v2's error
  (`InvalidPositions`; a section that ends inside a table, or holds a byte
  after the last one, is refused while the tables are found, with
  `InvalidLexicalSection`, as before v4), and the old generation is left as it
  was. One valid v2 table cannot be written in v4: a gap whose zigzag is 2^32
  or more (a token 2^31 codepoints or more from the previous token's end),
  which rule 5 forbids; the publish fails with `InvalidLexicalSection`.
- At that first publish the tables of the documents it removes are not
  written, but they are checked by the same v2 rules
  (`postings.checkPairsTable`), and a table v2 refuses refuses the publish
  (`InvalidPositions`, or `InvalidLexicalSection` where the tables are found),
  the old generation left whole. `main`'s writer dropped them unchecked, so an
  old index whose only damage sat in a removed file's table was published over;
  now it needs a full rebuild (`ss_index_folder` without `update`,
  `searchd index` without `--update`).
- Under v4 (an update over a `HYBLEX04` section), a removed document's table
  is dropped with the document without its rules being checked; only its
  length in bytes is walked, as v2's writer does for v2 tables. The two differ
  because the first publish is the one point where the writer takes in an
  older format, which it must accept exactly as that format's reader does,
  while a v4 section is this writer's own output, checked by every v4 rule
  when it was written and by the reader at each `find` that decodes it.
- Readers keep the section's bytes as they are (`postings.PositionSections`
  records which coding section 5 uses) and decode a document's tokens when a
  `find` hit needs them, as for v2's varints.

## Deliberate limitations

Section 4 (one byte per ordinal already, measured in
[`index-size.md`](index-size.md)) is not recoded. The token count stays per
document although section 1 gives it, so that every document's table is
self-contained for the writer's carry and the reader's position table.

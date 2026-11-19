# Index size: where the bytes go and what to change

**Status:** measurement and design, [S6-T3](tasks/S6-T3.md) (plan item D1 of the
[objective plan](plans/2026-11-16-objective-plan.md)). No format and no engine
source changed; verified 16 Nov 2026 and ruled on ([Rulings](#rulings-16-nov-2026)). Measured on `main` at `7cd2c16` (engine sources as `efbdd0e`),
macOS arm64, Zig 0.16.0, `searchd` built `ReleaseSmall`, 16 Nov 2026. Byte
counts are exact and independent of load; every timing names its load.
Raw tables: [`docs/evidence/s6-t3/`](evidence/s6-t3/README.md).

## In short

- **Today the index is 2.7 to 4.5 times the text it indexes** (one generation,
  file-name channel on): 4.44 on the 10,000-file timing corpus (the orchestrator's
  32,281,645 B reproduced to the byte), 4.05 on ordinary English prose, 2.66 on
  Tamil prose, 3.78 on the repository's fixtures, 4.54 on the family-folder fixture.
- **Where the bytes go:** the text is held twice (chunk text in `documents`,
  file bytes in `source`; each about the corpus size), and the lexical section
  stores every posting as two fixed `u32` (8 bytes; 66 % of `lexical` on the
  timing corpus, 63 % on prose) and every token's highlight offsets (19 % and
  23 % of `lexical`). With the positions, those four account for 81 % of the
  index on the timing corpus and 91 % on prose; the rest is spread over record
  fields, tables, paths, the state and the file-name channel.
- **Generations multiply it.** Each publish writes complete sections. With
  `keep_generations` unset (the default of `searchd index --update` and of the
  Dart binding) five one-file updates of the 10k timing index left 193,688,535 B
  on disk (six full generations); with `2` (what the consumer app passes)
  64,563,990 B, two generations.
- **Recommended, in order** (section [Recommendation](#recommendation-for-d2)):
  (1) varint postings, front-coded dictionary and varint lengths in a new lexical
  version; (2) the text once: chunk records keep their text, the source section
  keeps only the bytes no chunk holds; (3) the highlight offsets at one byte per
  token; (4) the state section and the file-name catalog stop repeating what the
  source table and the body hold. Together, with the channel on: **1.97 (timing
  10k), 1.82 (prose 10k), 1.27 (Tamil 10k), 1.71 (fixtures), 1.91 (family
  folder)**, summed from measured prototype re-encodings. None of the four
  changes what a query, `find` or `read_span` answers.
- **Step 1 has landed** ([below](#landed)): lexical v3, measured 3.41 (timing
  10k), 3.14 (prose 10k), 2.39 (Tamil 10k), 2.88 (fixtures), 3.17 (family
  folder) against the projection's 3.46, 3.17, 2.40, 2.87, 3.15.
- **Step 2 has landed** ([below](#landed); S6-T7): text once,
  measured 2.17 (timing 10k), 2.04 (prose 10k), 1.33 (Tamil 10k), 1.82
  (fixtures), 2.11 (family folder) against the projection's 2.31, 2.10, 1.36,
  1.82, 2.11.
- **Step 3 is built, not yet verified** ([below](#landed); S6-T8): the
  highlight offsets at one byte per token, measured 2.01 (timing 10k), 1.85
  (prose 10k), 1.28 (Tamil 10k), 1.72 (fixtures), 1.93 (family folder) against
  the projection's 2.15, 1.92, 1.32, 1.72, 1.92.
- **Not taken in D2 (ruled 16 Nov 2026, [below](#rulings-16-nov-2026)):**
  leaving the offsets out (to 1.81 timing, 1.63 prose, but `find` words
  measured 0.03–0.84 ms slower at the median, up to 5 ms at p95), block
  compression of the text (to 1.35 timing, 1.18 prose, but chunk text then
  comes from the compressed source at every query hit, measured at 0.37 ms per
  64 KiB block with the standard library's decoder; revisited after steps 1–4
  land), and positions left out. The `keep_generations` default of
  `searchd index` and `searchd apply` changes to two in a separate task
  (D2-5).

## Landed

**Step 1, lexical v3 (S6-T4, verified and merged 16 Nov 2026 on the
maintainer's decision, the timing rule not passed).** Both lexical sections are
[`HYBLEX03`](lexical-segment-format-v3.md) (C1, C2b, C3 and F2) under
[manifest v2.3](manifest-format-v2.md#v23-lexical-sections-v3-s6-t4). Measured
on indexes written by `searchd index --filename-index` (one generation,
channel on, MANIFEST and `INDEX-STATE.json` included), against `main` at
98c4a2b on the same files, and against the step 1 column of the
[projection](#projection):

| Corpus | Corpus bytes | Before (v2) | After (v3) | Change | Projected (step 1) |
| --- | ---: | ---: | ---: | ---: | ---: |
| timing-10k | 7,269,199 | 32,281,645 (4.44) | 24,793,305 (3.41) | −7,488,340 (−23.2 %) | 25,165,379 (3.46) |
| prose-10k | 17,244,024 | 69,778,345 (4.05) | 54,111,784 (3.14) | −15,666,561 (−22.5 %) | 54,654,587 (3.17) |
| tamil-10k | 27,708,457 | 73,831,391 (2.66) | 66,154,883 (2.39) | −7,676,508 (−10.4 %) | 66,529,355 (2.40) |
| fixtures | 4,635,177 | 17,499,412 (3.78) | 13,359,895 (2.88) | −4,139,517 (−23.7 %) | 13,300,298 (2.87) |
| family | 1,237,342 | 5,621,585 (4.54) | 3,917,972 (3.17) | −1,703,613 (−30.3 %) | 3,901,855 (3.15) |

The 10k corpora come in under the projection (it summed re-encodings without
the per-term `list bytes` field; the 255-byte prefix cap and the 88-byte
header cost nothing measurable here), the two small fixtures 0.4 % over it.
Every section is the Phase 1 prototype's to the byte. Nothing a query, `find`,
`outline`, `read_span`, `list_files` or `index_status` answers changed (65,456
answers compared). Open is 17–26 % faster, memory after open 7.1 MB (timing),
15.1 MB (prose) and 6.9 MB (Tamil) lower. Warm query and `find` carry a
small measured cost that does **not** pass the timing rule: on Tamil about
0.1–0.3 µs on warm queries of 3–8 µs and +0.011 and +0.017 ms on two `find`
requests of about 3 ms (the second Verdict's five runs); the builder traced it
to where the added code moves the unchanged query code, and the maintainer
accepted it on 16 Nov 2026 (S6-T4, "Maintainer's decision"). The one-file
update is unchanged; the first update of a v2 index costs 5–8 % once. The numbers, bars and method are in the
[S6-T4 Report](tasks/S6-T4.md) and `docs/evidence/s6-t4/phase2/`.

**Step 2, text once (S6-T7, merged 17 Nov 2026 as `a02b2cc`).** The
documents section is record v5 (a file table holding each path once, raw ids,
varint fields) and the source section `HYBSRC02` (only the bytes no chunk
holds; `read_span` and `outline` rebuild a file from its chunks and check its
SHA-256), under [manifest v2.4](manifest-format-v2.md#v24-text-once-s6-t7);
the format is [`documents-v5-source-v2-format.md`](documents-v5-source-v2-format.md).
Measured the same way, against `main` at `ad71cfb` (step 1) on the same files,
and against the step 2 column of the [projection](#projection):

| Corpus | Corpus bytes | Before (step 1) | After (step 2) | Change | Projected (step 2) |
| --- | ---: | ---: | ---: | ---: | ---: |
| timing-10k | 7,269,199 | 24,793,305 (3.41) | 15,808,625 (2.17) | −8,984,680 (−36.2 %) | 16,788,161 (2.31) |
| prose-10k | 17,244,024 | 54,111,784 (3.14) | 35,196,921 (2.04) | −18,914,863 (−35.0 %) | 36,271,159 (2.10) |
| tamil-10k | 27,708,457 | 66,154,883 (2.39) | 36,731,764 (1.33) | −29,423,119 (−44.5 %) | 37,713,611 (1.36) |
| fixtures | 4,635,177 | 13,359,895 (2.88) | 8,443,782 (1.82) | −4,916,113 (−36.8 %) | 8,425,002 (1.82) |
| family | 1,237,342 | 3,917,972 (3.17) | 2,614,805 (2.11) | −1,303,167 (−33.3 %) | 2,607,693 (2.11) |

J2's index: 260,237 → 169,267 B (−35.0 %). The documents and source sections
are the S6-T7 Phase 1 prototype's to the byte on all six corpora (timing-10k:
documents 8,028,417 B, source 539,719 B). The 10k corpora come in under the
projection, which priced each source record at S6-T3's coding; the two small
fixtures within 0.3 % of it. Answers are byte-identical to `main` on every
surface, fresh and after one update; `read_span` over every file returns its
exact bytes. Open time is within 1 % of `main`'s, memory after open 0.5–0.7 MB
lower on the 10k corpora, and the first `read_span` on a handle 42–76 % faster;
a later `read_span` of the 1.1 MB family log costs about 2 % more CPU (the
rebuild), of the other files measured the same or less. The numbers, bars and
method are in the [S6-T7 Report](tasks/S6-T7.md) and
`docs/evidence/s6-t7/phase2/`.

**Step 3, the highlight offsets at one byte per token (S6-T8, built 17 Nov
2026, not yet verified).** The content lexical section is
[`HYBLEX04`](lexical-segment-format-v4.md): v3 with section 5 recoded as C5b,
per token one byte (the zigzag gap from the previous token's end and the
length, two 4-bit fields, 15 escaping to the whole value as a varint), the
count per document a varint; under
[manifest v2.5](manifest-format-v2.md#v25-lexical-section-v4-s6-t8). Measured
the same way, against `main` at `62324f9` (step 2) on the same files, and
against the step 3 column of the [projection](#projection); percentages
rounded to nearest:

| Corpus | Corpus bytes | Before (step 2) | After (step 3) | Change | Section 5 before → after | Projected (step 3) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| timing-10k | 7,269,199 | 15,808,625 (2.17) | 14,612,980 (2.01) | −1,195,645 (−7.6 %) | 2,351,372 → 1,155,727 (−50.8 %) | 15,592,516 (2.15) |
| prose-10k | 17,244,024 | 35,196,921 (2.04) | 31,967,055 (1.85) | −3,229,866 (−9.2 %) | 6,448,994 → 3,219,128 (−50.1 %) | 33,041,293 (1.92) |
| tamil-10k | 27,708,457 | 36,731,764 (1.33) | 35,533,368 (1.28) | −1,198,396 (−3.3 %) | 2,356,900 → 1,158,504 (−50.8 %) | 36,515,215 (1.32) |
| fixtures | 4,635,177 | 8,443,782 (1.82) | 7,969,705 (1.72) | −474,077 (−5.6 %) | 1,185,351 → 711,274 (−40.0 %) | 7,950,925 (1.72) |
| family | 1,237,342 | 2,614,805 (2.11) | 2,382,441 (1.93) | −232,364 (−8.9 %) | 467,096 → 234,732 (−49.7 %) | 2,375,329 (1.92) |

J2's index: 169,267 → 157,654 B (−6.9 %). The saving on every corpus is
S6-T3's C5b re-encoding to the byte (−1,195,645, −3,229,866 and −1,198,396 B on
the 10k corpora), and every other section is `main`'s byte for byte. The 10k
corpora come in under the projection and the two small corpora over it, the
fixtures by 0.2 % (+18,780 B) and family by 0.3 % (+7,112 B), for one reason: the step 3 projection is step 2's
projection less the C5b saving, the measured saving equals the projected one to
the byte, so each difference is step 2's own difference from its projection,
carried unchanged (step 2 measured +18,780 and +7,112 B over it on the fixtures
and family, and under it on the 10k corpora).
Nothing a query, `find`, `outline`, `read_span`, `list_files` or
`index_status` answers changed: every `find` hit's highlights equal `main`'s,
on a query set with Tamil, combining marks, tokens of 15 codepoints and more,
gaps of 15 and more and tokens at a chunk's ends. In the builder's runs on
the final code (for information; the verifier's five decide) open was 1.5 % to
4.1 % faster (J2 equal within the rule's threshold) and memory after open up
to 3.2 MB lower; the first publish from step 2's format was −0.8 % to +1.8 %
and one-file updates after it −2.1 % to +0.7 %, within the 2 % expected, after
two writer changes made on measurement (a first build was 3.5 % to 13.4 %
slower on the first publish and up to 6.9 % on later updates). A few warm
`both` queries on prose move by 10 to 25 µs with the code's placement in the
`ReleaseSmall` build, as never-run code of the same size moves them. The numbers,
bars and method are in the [S6-T8 Report](tasks/S6-T8.md) and
`docs/evidence/s6-t8/`. Step 4 is next (03-next D2-4).

## How it was measured

| Corpus | Generator (committed) | Files | Text |
| --- | --- | ---: | --- |
| timing 1k, 10k | `scripts/gen_timing_corpus.py <dir> N` | 1,000; 10,000 | invented pseudo-words, 24,000-term vocabulary |
| prose 1k, 10k | `scripts/gen_prose_corpus.py <dir> N` (new) | 1,000; 10,000 | English word forms (3,115), Zipf-Mandelbrot ranks, Markdown notes of log-normal length (median 160 words), front matter in one note in five, half hard-wrapped |
| Tamil 1k, 10k | `scripts/gen_tamil_timing_corpus.py <dir> N` | 1,000; 10,000 | invented Tamil words, 21,600 forms |
| fixtures | the repository's `fixtures/` | 232 indexed | every fixture pack |
| family | `fixtures/family-folder/` | 46 | the S3-T7 fixture (one 1.1 MB log) |

Each corpus was indexed with `searchd index <dir> --out <idx>` and again with
`--filename-index`. `scripts/index_size_budget.py` reads every file of an index
by the format documents ([segment v4](segment-format-v4.md),
[lexical v2](lexical-segment-format-v2.md) and [v1](lexical-segment-format-v1.md),
[source v1](source-section-v1.md), [state v2](state-section-format-v2.md),
[file-name field v1](filename-field-format-v1.md), [manifest v2](manifest-format-v2.md))
and splits it into parts; it refuses a file whose parts do not sum to its size.
`duplication` measures text stored more than once by locating every chunk's
text in its file's bytes through the line map. `candidates` builds each remedy
as a re-encoding of the existing section bytes and counts its bytes; the two
text-once prototypes are decoded back and compared byte for byte (every chunk
rebuilt from the source; every file rebuilt from chunks and gaps, checked
against its SHA-256). The Zig probes in `scripts/prototypes/s6t3/` time the
codecs and the posting decode and measure their binary size. The commands are
in [the evidence README](evidence/s6-t3/README.md).

No Zig benchmark was added under `zig/src/`: `bindings/dart/search_simpli/tool/source_digest.py`
hashes every `zig/src/**/*.zig` except `*_test.zig`, so a new `*_bench.zig` there
would change the native digest. The probes live outside `zig/src/`.

## The corpora

| Corpus | Files | Corpus bytes | Chunks | Distinct terms | Postings | Tokens |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| timing-1k | 1,000 | 916,353 | 2,071 | 24,057 | 128,157 | 139,929 |
| timing-10k | 10,000 | 7,269,199 | 19,959 | 24,057 | 1,023,806 | 1,135,768 |
| prose-1k | 1,000 | 1,676,925 | 1,819 | 3,115 | 217,469 | 310,043 |
| prose-10k | 10,000 | 17,244,024 | 18,766 | 3,115 | 2,238,541 | 3,186,965 |
| tamil-1k | 1,000 | 3,250,702 | 1,963 | 21,600 | 118,713 | 130,490 |
| tamil-10k | 10,000 | 27,708,457 | 19,946 | 21,600 | 1,019,062 | 1,138,558 |
| fixtures | 232 | 4,635,177 | 4,084 | 68,074 | 379,874 | 584,504 |
| family | 46 | 1,237,342 | 1,063 | 17,512 | 190,608 | 231,422 |

Corpus bytes are the bytes of the files indexed (the source section's text
area, which equals the generated corpora byte for byte). Prose has many tokens
per posting (1.42) and few terms; the timing and Tamil corpora have one token
per posting nearly always (1.11, 1.12) and many terms.

## The ratio today

One generation; MANIFEST and `INDEX-STATE.json` included.

| Corpus | Corpus bytes | Index bytes | Ratio | With the file-name channel | Ratio |
| --- | ---: | ---: | ---: | ---: | ---: |
| timing-1k | 916,353 | 4,432,838 | 4.84 | 4,560,085 | 4.98 |
| timing-10k | 7,269,199 | 31,011,398 | 4.27 | 32,281,645 | 4.44 |
| prose-1k | 1,676,925 | 6,705,317 | 4.00 | 6,907,482 | 4.12 |
| prose-10k | 17,244,024 | 68,047,830 | 3.95 | 69,778,345 | 4.05 |
| tamil-1k | 3,250,702 | 9,394,513 | 2.89 | 9,521,760 | 2.93 |
| tamil-10k | 27,708,457 | 72,561,144 | 2.62 | 73,831,391 | 2.66 |
| fixtures | 4,635,177 | 17,466,159 | 3.77 | 17,499,412 | 3.78 |
| family | 1,237,342 | 5,615,029 | 4.54 | 5,621,585 | 4.54 |

The orchestrator's measurement on `efbdd0e` is reproduced exactly: corpus
7,269,199 B, index 32,281,645 B, `lexical-1.hyblex` 12,487,753,
`documents-1.hybseg` 9,273,775, `source-1.hybsrc` 8,279,041, `state-1.hybstate`
970,159, `filenames-1.hybseg` 780,036, `filename-lexical-1.hyblex` 490,091
(plus MANIFEST 696 and `INDEX-STATE.json` 94). The documents, lexical, source
and state sections are byte-identical in size with the channel off and on.

Tamil's ratio is lower because its text is three bytes per character in UTF-8
while its lexical section is about the timing corpus's (similar term and
posting counts), so text dominates.

## Bytes per section (channel on)

| Corpus | documents | lexical | source | state | filenames | filename-lexical | Total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| timing-10k | 9,273,775 (28.7 %) | 12,487,753 (38.7 %) | 8,279,041 (25.6 %) | 970,159 (3.0 %) | 780,036 (2.4 %) | 490,091 (1.5 %) | 32,281,645 |
| prose-10k | 20,071,912 (28.8 %) | 28,358,524 (40.6 %) | 18,529,034 (26.6 %) | 1,087,690 (1.6 %) | 1,031,098 (1.5 %) | 699,297 (1.0 %) | 69,778,345 |
| tamil-10k | 30,037,019 (40.7 %) | 12,835,061 (17.4 %) | 28,718,235 (38.9 %) | 970,159 (1.3 %) | 780,036 (1.1 %) | 490,091 (0.7 %) | 73,831,391 |
| fixtures | 5,597,148 (32.0 %) | 7,021,709 (40.1 %) | 4,821,461 (27.6 %) | 24,805 (0.1 %) | 20,566 (0.1 %) | 12,567 (0.1 %) | 17,499,412 |

Every corpus at 1k and 10k is in [`tables.md`](evidence/s6-t3/tables.md) §3.

## Inside each section

The parts below sum to each file's size. Timing 10k and prose 10k, channel on;
every corpus is in [`tables.md`](evidence/s6-t3/tables.md) §4.

| Section | Part | timing-10k | prose-10k |
| --- | --- | ---: | ---: |
| documents | header | 36 | 36 |
| | record lengths (id, path, text, vector, labels, section path: 6 × u32) | 479,016 | 450,384 |
| | record lines (start, end, heading: 3 × u32) | 239,508 | 225,192 |
| | chunker index, section depth (2 × u16) | 79,836 | 75,064 |
| | source_doc_index (u32) | 79,836 | 75,064 |
| | chunk ids (20 hex digits) | 399,180 | 375,320 |
| | paths (one per chunk) | 419,139 | 615,294 |
| | **chunk text** | **7,239,281** | **17,818,611** |
| | section paths (heading texts) | 337,943 | 436,947 |
| | labels, vectors | 0 | 0 |
| | **total** | 9,273,775 | 20,071,912 |
| lexical | header | 80 | 80 |
| | 1 document lengths (u32) | 79,836 | 75,064 |
| | 2 dictionary: term length + df (2 × u32) | 192,456 | 24,920 |
| | 2 dictionary: posting start + count (2 × u64) | 384,912 | 49,840 |
| | 2 dictionary: term bytes | 152,881 | 19,973 |
| | **3 postings: document index (u32)** | **4,095,224** | **8,954,164** |
| | **3 postings: term frequency (u32)** | **4,095,224** | **8,954,164** |
| | 4 positions: first ordinal per posting (varint) | 1,023,806 | 2,833,310 |
| | 4 positions: later ordinal gaps (varints) | 111,962 | 998,015 |
| | 5 offsets: token count per document (u32) | 79,836 | 75,064 |
| | **5 offsets: start gap varints** | **1,135,768** | **3,186,965** |
| | **5 offsets: length varints** | **1,135,768** | **3,186,965** |
| | **total** | 12,487,753 | 28,358,524 |
| source | header | 48 | 48 |
| | file table: offsets, lengths, line count | 320,000 | 320,000 |
| | file table: sha256 | 320,000 | 320,000 |
| | file table: encoding + reserved | 40,000 | 40,000 |
| | file table: paths | 210,000 | 327,531 |
| | line maps (varints) | 119,794 | 277,431 |
| | **text (original file bytes)** | **7,269,199** | **17,244,024** |
| | **total** | 8,279,041 | 18,529,034 |
| state | headers, string table, roots | 159 | 159 |
| | file records: sha256 | 320,000 | 320,000 |
| | file records: other fields (44 B) | 440,000 | 440,000 |
| | paths | 210,000 | 327,531 |
| | **total** | 970,159 | 1,087,690 |
| filenames (record v3) | header | 36 | 36 |
| | record lengths and lines (7 × u32) | 280,000 | 280,000 |
| | chunk ids (copied from the body anchor) | 200,000 | 200,000 |
| | paths | 210,000 | 327,531 |
| | stems (record text) | 90,000 | 223,531 |
| | **total** | 780,036 | 1,031,098 |
| filename-lexical (`HYBLEX01`) | header | 64 | 64 |
| | document lengths | 40,000 | 40,000 |
| | dictionary (24 B per term + term bytes) | 290,027 | 378,705 |
| | postings (8 B each) | 160,000 | 280,528 |
| | **total** | 490,091 | 699,297 |

What the table says:

- The postings' fixed `u32` pair is the largest single part of the index on
  both: 8.19 MB (25.4 %) on the timing corpus, 17.9 MB (25.7 %) on prose, more
  than the chunk text or the source text. Every
  term frequency on the timing corpus fits one byte; most document gaps fit one
  or two.
- The offsets section (section 5) holds two varints per token: 2.35 MB on the
  timing corpus, 6.45 MB on prose. Only `find`'s highlights read it.
- The dictionary's `u64` start and count are derivable: count equals df (the
  decoder refuses a difference) and start is the running sum of counts.
- In the documents section everything but the chunk text is 22 % of the
  section on the timing corpus and 11 % on prose; a path is repeated per chunk.

## Text stored more than once (measured)

| Corpus | Corpus bytes | Chunk text | Source text | Chunks found as exact source spans | Chunk bytes not found | Chunk overlap | Source bytes in no chunk |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| timing-10k | 7,269,199 | 7,239,281 | 7,269,199 | 19,959 of 19,959 | 0 | 0 | 29,918 |
| prose-10k | 17,244,024 | 17,818,611 | 17,244,024 | 18,766 of 18,766 | 0 | 725,252 | 150,665 |
| tamil-10k | 27,708,457 | 27,678,565 | 27,708,457 | 19,946 of 19,946 | 0 | 0 | 29,892 |
| fixtures | 4,635,177 | 5,225,049 | 4,635,177 | 4,071 of 4,084 | 773 | 592,572 | 3,473 |
| family | 1,237,342 | 1,427,521 | 1,237,342 | 1,060 of 1,063 | 114 | 191,106 | 1,041 |

- **Chunk text against source text.** A chunk is its lines joined with LF and
  stripped (`chunker.zig`, `chunker_md.zig`), so in a file with LF line ends
  it is one contiguous run of the file's bytes. Every chunk of the generated
  corpora was found at an exact byte offset inside its own lines; in the
  fixtures 13 chunks (773 B) were not (files with other line ends). In the family folder 3 chunks (114 B) were not. So the documents
  section's chunk text, 99.6 % (timing) to 115 % (family) of the corpus, is a
  second copy of bytes the source section already holds.
- **Chunk overlap.** The windows overlap by three lines inside long sections:
  725,252 B on prose (4.1 % of its chunk text), 592,572 B on the fixtures. The
  timing and Tamil files are too short to overlap.
- **The source holds little that no chunk holds:** 29,918 B on the timing
  corpus (the blank lines between paragraphs at chunk edges), 150,665 B on
  prose (front matter and blank lines).
- **Other repeats** (10k timing, channel on): each file's path is stored four
  times or more (once per chunk in `documents` 419,139 B, in the source table,
  the state and the catalog 210,000 B each); each file's SHA-256 twice (state
  and source table, 320,000 B each); the catalog copies 200,000 B of chunk ids
  and 90,000 B of stems that its paths and anchors give. Every corpus is in
  [`tables.md`](evidence/s6-t3/tables.md) §5.

## The candidates

Bytes saved are measured on re-encodings of the existing section bytes
(`scripts/index_size_budget.py candidates`), channel on. Effects on time are
**reasoned from the code** unless a measurement is named.

| Corpus | A1 text as spans | A1–A4 | A′ source residual | A′ record coding | B deflate 64 KiB | C1 dictionary | C2b postings | C3 lengths | C5 offsets out | C5b offsets one byte per token | C6 positions + offsets out | D state | F catalog | F2 file-name lexical |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| timing-1k | 904,927 | 1,036,674 | 904,927 | 126,605 | 555,672 | 628,711 | 804,675 | 6,213 | 288,142 | 146,142 | 428,071 | 61,000 | 29,000 | 40,972 |
| timing-10k | 7,159,445 | 8,427,136 | 7,159,445 | 1,217,773 | 4,395,222 | 628,699 | 6,427,690 | 59,877 | 2,351,372 | 1,195,645 | 3,487,140 | 610,000 | 290,000 | 407,165 |
| prose-1k | 1,724,873 | 1,861,767 | 1,653,889 | 132,263 | 994,018 | 78,555 | 1,458,294 | 4,217 | 627,362 | 314,182 | 999,617 | 72,678 | 42,278 | 72,639 |
| prose-10k | 17,743,547 | 19,156,072 | 17,018,295 | 1,365,133 | 10,232,334 | 75,889 | 15,004,251 | 43,618 | 6,448,994 | 3,229,866 | 10,280,319 | 727,531 | 423,531 | 523,420 |
| tamil-1k | 3,239,924 | 3,364,850 | 3,239,924 | 120,000 | 2,673,279 | 847,019 | 745,830 | 5,889 | 268,832 | 136,379 | 399,322 | 61,000 | 29,000 | 40,972 |
| tamil-10k | 27,598,781 | 28,865,636 | 27,598,781 | 1,216,963 | 22,755,090 | 847,019 | 6,395,179 | 59,838 | 2,356,900 | 1,198,396 | 3,495,458 | 610,000 | 290,000 | 407,165 |
| fixtures | 5,207,940 | 5,472,761 | 4,615,388 | 259,908 | 3,605,509 | 1,738,601 | 2,450,240 | 10,273 | 1,185,351 | 474,077 | 1,880,059 | 16,276 | 7,249 | 9,249 |
| family | 1,423,155 | 1,486,569 | 1,232,046 | 62,116 | 784,698 | 432,647 | 1,284,800 | 2,283 | 467,096 | 232,364 | 791,126 | 2,793 | 1,386 | 2,050 |

### A. Chunk records refer to spans of the source section

**What:** a record keeps a `u32` byte offset into its file's source bytes
instead of its text (A1); then drops its path, which the source table holds
under `source_doc_index` (A2); stores its id as 10 raw bytes, not 20 hex
digits (A3); and writes its fixed fields as varints (A4). A chunk whose text
is not an exact span (13 in the fixtures) keeps its text inline.

**Saves** 7,159,445 B (A1) and 8,427,136 B (A1–A4) on the timing corpus, 19.2 MB
(A1–A4) on prose: the documents section goes from 9,273,775 B to 846,639 B.
Round trip: every spanned chunk's text, rebuilt from the source section, equals
the stored text (all corpora).

**Readers that change:** every reader of `Document.text`: the content query's
hit text, `evidence`, `find` (snippets, the recomputed tokens, de-duplication by
lines), the file-name channel's match sections, the title field's derive (paths,
if A2), the MCP and RPC responses through them, the importer, and the writer
(`apply`) that carries records.

**Effects (reasoned):** the text then has to come from the source section at
query time. Either the open reads the source text (the open's bytes stay about
what they are, the section is checksummed at the open instead of at the first
`read_span`), or each hit reads its span with a positioned read (the open
reads 7 MB less, every query adds one small read per hit, and the text's
integrity rests on the source checksum checked at its first use). A2 makes the
open read the source table (1,009,678 B of table and maps at 10k on the timing
corpus, S4-T14's figure). Warm query and `find` gain a read per hit;
`read_span` unchanged; a one-file update writes 7 MB less. Old indexes stay
readable only through a kept segment v4 reader. Library size: small (reasoned).
A is the precondition for B.

### A′. The other way round: chunk text stays, the source keeps the rest

**What:** chunk records keep their text, which is resident after the open
anyway; the source section keeps, per file, only the bytes no chunk holds and a
`u32` offset per chunk; `read_span` and `outline` rebuild the file from its
chunks' text and those gaps, then check its SHA-256 as today. A file with any
chunk that is not an exact span is kept whole. The same record coding as A2–A4
applies to the documents section (path dropped, raw ids, varint fields).

**Saves** 7,159,445 B (source) + 1,217,773 B (record coding) on the timing
corpus; 17,018,295 + 1,365,133 B on prose (A′ keeps the chunk overlap that A
removes: 725,252 B on prose). The source section of the timing corpus goes from
8,279,041 B to 1,119,596 B. Round trip: every rebuilt file's SHA-256 equals the
source table's (all corpora; fixtures: 223 files rebuilt, 9 kept whole, 959 B).

**Readers that change:** `source.zig` (`readSpan`, `outline`, the streamed open,
the writer's `openTable`), the writer's source build and carry in `apply.zig`,
`scripts/source_read_parity.py`. Query, `find`, the open's documents and lexical
paths do not change (record decoding aside).

**Effects (reasoned):** open unchanged except the record decode; warm query and
`find` unchanged; `read_span` copies the file's chunk text from memory the
handle already holds plus the gaps it reads, instead of reading the whole file
from the section (today 0.04–0.08 ms for a 10k-corpus file, S4-T14), then hashes
as today; the first `read_span` on a cold handle checksums a 1.1 MB section
instead of 8.3 MB. A one-file update writes 7 MB less. Coupling: `read_span`
then needs the documents section too; a damaged documents section already
fails the open. Old indexes stay readable through a kept `HYBSRC01` reader.
Library size: small (reasoned). A root with `retain_source` off is unchanged
(no source section).

### B. The source section stored once, block-compressed

**Codec without a dependency:** Zig 0.16's standard library has a deflate
encoder and decoder (`std.compress.flate`); its `zstd`, `xz` and `lzma` are
decoders only, so deflate is the only codec a writer can produce without one.
A small in-tree LZ4-style codec is the alternative.

| Text area after (block table included) | timing-10k | prose-10k | tamil-10k | fixtures |
| --- | ---: | ---: | ---: | ---: |
| today | 7,269,199 | 17,244,024 | 27,708,457 | 4,635,177 |
| deflate 64 KiB, level 6 (zlib) | 2,873,977 | 7,011,690 | 4,953,367 | 1,029,668 |
| deflate 64 KiB blocks aligned to files | 2,875,169 | 7,023,577 | 4,955,060 | 1,028,143 |
| deflate 16 KiB, level 6 | 3,076,706 | 7,768,512 | 5,413,562 | 1,117,245 |
| deflate per file, level 6 | 3,922,392 | 9,176,370 | 6,943,563 | 1,005,837 |
| Zig `std.compress.flate`, 64 KiB, default level | 2,901,121 (no table) | 7,043,990 | 5,067,448 | — |
| LZ4-style 64 KiB (in-tree prototype) | 4,662,645 | 10,877,519 | 11,427,400 | 1,619,863 |

The invented Tamil text compresses to 17.9 % because it is drawn from 162
syllables and 21,600 forms; real Tamil prose would compress less (an
expectation, not measured).

**Measured cost** (Zig probes, `ReleaseSmall`, best of five or seven rounds,
5-minute load 4.03–4.05, [`probes.txt`](evidence/s6-t3/probes.txt)):

| | timing-10k | prose-10k | tamil-10k |
| --- | ---: | ---: | ---: |
| `std.compress.flate` decode, per 64 KiB block | 373 µs | 376 µs | 165 µs |
| … the whole text area | 41.4 ms | 99.2 ms | 69.8 ms |
| `std.compress.flate` encode, the whole text area | 233 ms | 479 ms | 438 ms |
| in-tree LZ4 decode, per 64 KiB block | 92 µs | 94 µs | 60 µs |
| in-tree LZ4 encode, the whole text area | 17 ms | 44 ms | 35 ms |

Binary size (standalone probe, `ReleaseSmall`, against the same program without
a codec): `std.compress.flate` decoder +11,032 B of `__TEXT` (+17,608 B of
file), decoder and encoder +22,832 B (+35,056 B); the in-tree LZ4 decoder
+1,320 B of `__TEXT`, decoder and encoder +2,168 B. The library's delta is
expected to be similar (an expectation: the libraries are 916,928–954,120 B).

**Effects:** with the text only in the source (A), every query hit's text needs
its block decoded: 0.37 ms per 64 KiB block with the standard decoder, against
a warm content query of 0.56 ms at the median today (`find_bench` `knowledge`,
timing and prose 10k, [`find-bench.txt`](evidence/s6-t3/find-bench.txt)), so a
page of 10 hits in different blocks would cost up to 3.7 ms more unless decoded
blocks are cached; a cache that holds the
whole text costs the 41–99 ms decode at first use. `read_span` decodes the
file's block(s): 0.37 ms per block against 0.04–0.08 ms today. A one-file
update re-encodes the changed file's blocks only if blocks are aligned to
files (same ratio, measured above); re-encoding the whole text takes 233 ms on
the timing corpus with the standard encoder. B does not combine with A′: under
A′ the source holds almost nothing.

### C. Tighter lexical coding; offsets and positions optional

- **C1 dictionary:** terms front-coded (shared prefix length, suffix length,
  suffix bytes) with df as a varint; start and count derived. 730,249 → 101,550 B
  on the timing corpus; 1.74 MB saved on the fixtures (68,074 terms).
- **C2 postings:** document gap and tf as varints, 8,190,448 → 2,638,289 B on the
  timing corpus. **C2b** folds tf = 1 into the gap's low bit (a tf varint only
  when tf > 1): 1,762,758 B (1.72 B per posting), smaller than deflate of the
  fixed postings (2,262,867 B). Prose: 17,908,328 → 2,904,077 B.
- **C3 document lengths** as varints: 79,836 → 19,959 B.
- **C5 the offsets section left out:** −2,351,372 B (timing), −6,448,994 B
  (prose). `find` already has the code that re-tokenizes a hit's text for its
  highlights (`find.zig` `spans`, `recompute_offsets`, used for `HYBLEX01`).
  Measured cost with `find_bench` (warm, in process, `ReleaseSmall`, 5-minute
  load 3.54 before and 3.50 after; three repetitions of 200 queries, each
  cell the median of the three; the repetitions agree within 10 % except
  the two smallest medians, timing words 6.2–7.3 µs and Tamil phrase
  19.1–22.1 µs, which spread 16–18 %):

  | `find` median (p95), µs | timing-10k | prose-10k | tamil-10k |
  | --- | ---: | ---: | ---: |
  | words, offsets read | 6.3 (213) | 239 (2,154) | 68 (1,542) |
  | words, re-tokenized | 37 (320) | 694 (7,304) | 904 (2,357) |
  | phrase, offsets read | 20 (920) | 191 (3,099) | 20 (73) |
  | phrase, re-tokenized | 29 (951) | 211 (3,194) | 66 (123) |

  So `find` words gets 0.03 ms (timing) to 0.84 ms (Tamil) slower at the
  median and up to 5.2 ms slower at p95 (prose, 1,115 hits on average; which
  re-tokenizing drives the p95, the page's 20 hits or the overlapping chunks
  `deduplicate` matches, was not isolated). Phrase changes little.
- **C5b the offsets kept at one byte per token:** per token, the codepoints
  between the previous token's end and this token's start (zigzag) and the
  token's length as two 4-bit fields, a value of 15 or more escaping to a
  varint after the byte; the token count per document as a varint. Half the
  offsets section with no change to what `find` does: −1,195,645 B (timing),
  −3,229,866 B (prose), −1,198,396 B (Tamil). Decode cost not measured; it is
  read per hit, like today's varints, so it is expected to be the same order
  (an expectation).
- **C6 positions and offsets both left out:** −3,487,140 B (timing),
  −10,280,319 B (prose). What is lost: `find` `phrase` answers `CAPACITY`
  "re-index required: positions absent" (as for a `HYBLEX01` generation);
  `words` and `prefix` keep working with recomputed highlights. The title field
  loses nothing: it is derived in memory from the record paths
  (`title_field.zig`) and reads no position. Content queries never read
  positions.
- Positions themselves are already one byte per token (first ordinal plus
  gaps); no smaller coding was found worth its cost.

**Readers that change:** `lexical_segment.zig` (a new lexical version), the
open's decode into `TermEntry`/`Posting` arrays, `apply.mergeCarried` (it
copies postings; with gaps it re-encodes each carried run after the remap),
`find.zig` for C5, `filename_field.zig` for F2.

**Effects:** the open decodes the postings into the same arrays, so warm query,
`find` and `read_span` are unchanged; the decode costs more and the open reads
fewer bytes. Measured (Zig probe, `ReleaseSmall`): today's fixed decode of the
timing corpus's 1,023,806 postings 0.27 ms, C2b 2.45 ms (+2.18 ms); prose's
2,238,541 postings 0.60 → 6.09 ms (+5.49 ms); Tamil 0.27 → 2.54 ms. Against the
open measured by `find_bench` (18.9 ms timing, 44.2 ms prose, 23.5 ms Tamil, one
open each) that is about +12 % for timing and prose and +10 % for Tamil. The open
reads 7.1 MB (timing) and 15.1 MB (prose) less, which should offset part of it
(the saving in read and XXH3 time is an expectation, not measured). Old indexes stay
readable through the kept `HYBLEX02`/`HYBLEX01` reader. Library size: small
(the varint code exists for positions; reasoned).

### Baselines today (whole process)

`scripts/prototypes/s6t3/timings.py`: each operation a fresh `searchd` process,
so each includes the open; median of 7 runs (3 for the update), ms
([`timings.jsonl`](evidence/s6-t3/timings.jsonl)).

| | timing-10k | prose-10k |
| --- | ---: | ---: |
| `query` (the first file's heading) | 27.2 | 57.8 |
| `find` words / phrase | 20.3 / 20.2 | 46.7 / 45.7 |
| `read-span` lines 1–5 | 13.2 | 25.8 |
| one-file `index --update --keep-generations 2` | 189.8 | 248.6 |
| 5-minute load before / after | 3.62 / 4.04 | 3.72 / 4.15 |

The timing row is the second of two runs (the first, at load 3.72, agrees
within 6 % except the update's median, 214.5 ms, min 189.7). Tamil was not
timed: the 5-minute load was 4.0 or more at every attempt after the timing run.
D2 measures its before and after against these on the same machine.

### D. The state section

The state repeats, per file, the source table's SHA-256 (32 B), path and size
(8 B): 610,000 B on the timing corpus, 727,531 B on prose (every file's state
SHA-256 equals its source table entry). `chunks` and `chunker` (8 B) are
derivable from the documents section too, but only by reading it. A state
record could refer to its source-table entry for files that have source bytes,
and keep full records for pending, skipped or not-retained files. **Readers:**
`incremental_state.decodeBinary` and the writer's previous-state read only
(no open or query reads the state). **Effects:** none on open, query, `find`,
`read_span`; the writer reads the source table it already reads. Deflate of the
whole state section gives 396,385 B (timing) for reference.

### E. Generations retained on disk

Measured on a copy of the 10k timing corpus, channel on, five one-file updates
(`searchd index --update` after appending a line to one file), total bytes of
the index directory:

| After | `keep_generations` unset | `--keep-generations 2` |
| --- | ---: | ---: |
| the first index | 32,281,645 | 32,281,645 |
| update 1 | 64,562,727 | 64,562,727 |
| update 2 | 96,843,957 | 64,563,102 |
| update 3 | 129,125,335 | 64,563,398 |
| update 4 | 161,406,861 | 64,563,694 |
| update 5 | 193,688,535 (39 files) | 64,563,990 (15 files) |

Each publish writes complete sections, so every update adds a full index.
`keep_generations` is opt-in: `searchd index` and `import-json` take
`--keep-generations N`; the Dart binding's `ApplyChangesOptions`,
`IndexFolderOptions` and the import payload default it to null (nothing
deleted). The consumer app (at its commit `0da355a4`) passes
`keepGenerations = 2` on every change, so its directory holds two full
generations: **twice every ratio in this document**. Every byte saved by A–D is
saved twice there. Delta sections (filed in 03-next) are what would make an
update's write proportional to the change.

### F. The file-name catalog and its lexical section

The catalog (record v3) stores, per file, a path, a stem and a copied chunk id
that its body anchor already gives: 290,000 B of stems and ids on the timing
corpus, 423,531 B on prose (paths 210,000 / 327,531 B more). Its `HYBLEX01`
section takes the same coding as C1–C3 (F2): 490,091 → 82,926 B (timing).
**Readers:** `filename_field.load` and `validate` (lazy, at the first `filename`
or `both` query) and the writer's catalog build and carry (S4-T13). **Effects:**
the first file-name query's load decodes a smaller section; the catalog check
against body anchors stays. Small in bytes; worth taking with C.

### Other things the budget shows

- Section paths (heading texts per chunk): 337,943 B (timing), 663,008 B
  (Tamil). Responses carry them; the source could give them back (`outline`
  computes headings), but only by reading the file. Not recommended.
- Chunk ids as 20 hex digits (399,180 B on the timing corpus): part of A3.
- `MANIFEST` (576–1,062 B) and `INDEX-STATE.json` (94 B): nothing to gain.

## Projection

The steps touch different bytes, so their measured savings add. Ratio in
brackets (index ÷ corpus); one generation.

**The recommended order** (A′: text stays in the chunks; the offsets kept at one
byte per token), with the C5 variant (offsets left out) in the last column:

| Corpus | Today | 1. lexical coding (C1, C2b, C3) | 2. + A′ and record coding | 3. + offsets one byte per token (C5b) | 4. + state, catalog (D, F, F2) | 4 with the offsets left out (C5) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| timing-1k | 4,560,085 (4.98) | 3,120,486 (3.41) | 2,088,954 (2.28) | 1,942,812 (2.12) | 1,811,840 (1.98) | 1,669,840 (1.82) |
| timing-10k | 32,281,645 (4.44) | 25,165,379 (3.46) | 16,788,161 (2.31) | 15,592,516 (2.15) | 14,285,351 (1.97) | 13,129,624 (1.81) |
| prose-1k | 6,907,482 (4.12) | 5,366,416 (3.20) | 3,580,264 (2.14) | 3,266,082 (1.95) | 3,078,487 (1.84) | 2,765,307 (1.65) |
| prose-10k | 69,778,345 (4.05) | 54,654,587 (3.17) | 36,271,159 (2.10) | 33,041,293 (1.92) | 31,366,811 (1.82) | 28,147,683 (1.63) |
| tamil-1k | 9,521,760 (2.93) | 7,923,022 (2.44) | 4,563,098 (1.40) | 4,426,719 (1.36) | 4,295,747 (1.32) | 4,163,294 (1.28) |
| tamil-10k | 73,831,391 (2.66) | 66,529,355 (2.40) | 37,713,611 (1.36) | 36,515,215 (1.32) | 35,208,050 (1.27) | 34,049,546 (1.23) |
| fixtures | 17,499,412 (3.78) | 13,300,298 (2.87) | 8,425,002 (1.82) | 7,950,925 (1.72) | 7,918,151 (1.71) | 7,206,877 (1.55) |
| family | 5,621,585 (4.54) | 3,901,855 (3.15) | 2,607,693 (2.11) | 2,375,329 (1.92) | 2,369,100 (1.91) | 2,134,368 (1.72) |

Channel on. Without the channel, after step 4: timing-10k 13,712,269 (1.89),
prose-10k 30,583,247 (1.77), tamil-10k 34,634,968 (1.25), fixtures 7,901,396
(1.70), family 2,365,980 (1.91); every row is in
[`tables.md`](evidence/s6-t3/tables.md) §8.

**The alternative, not taken now (ruling 2)** (A then B: text once in the source as
spans, then compressed), channel on, after the same lexical, C5b offsets, state
and catalog steps: timing-10k 9,840,211 (1.35), prose-10k 20,361,833 (1.18),
tamil-10k 12,403,068 (0.45, low-entropy invented text), fixtures 3,715,177
(0.80), family 1,391,995 (1.12); [`tables.md`](evidence/s6-t3/tables.md) §7.

## Recommendation for D2

The order below is the one ruled on 16 Nov 2026 ([Rulings](#rulings-16-nov-2026)).
One format version per step, each with a reader for the previous version, a
migration note, and before/after numbers for size, open, warm query, `find`,
`read_span` and one-file update (ruling 6):

1. **Lexical v3: C2b postings, C1 dictionary, C3 lengths**, and the same coding
   for the file-name lexical section (F2). Largest saving for the least change: no
   reader above the decode changes. Saves 22 % (timing 10k), 22 % (prose 10k),
   10 % (Tamil 10k) of today's index without F2 (23 %, 22 %, 10 % with it; the
   projection table above counts F2 in its column 4, so its columns 1–3 move by
   F2 while the totals after step 4 do not). Cost measured: +2.2 ms (timing) to
   +5.5 ms (prose) of posting decode in the open.
2. **Text once, A′: the source section keeps only what no chunk holds**, with
   the record coding (raw ids, varint fields, and the path once: in the source
   section's file table, other sections referring to a file by its ordinal
   there, ruling 5; corrected by S6-T7: the table is in the documents section
   and the open reads no source byte). Saves about one corpus size. The query
   path does not change; `read_span` and `outline` rebuild a file from
   resident chunk text.
3. **The offsets at one byte per token** (C5b), so `find` is unchanged; its
   decode cost is measured in that step's task. Positions stay mandatory (C6
   not taken) and the offsets are kept (C5 not taken).
4. **State and catalog stop repeating** (D, F): writer-side and lazy-load
   readers only.

Then, separately: **D2-5**, `searchd index` and `searchd apply` default to
keeping two generations, with an explicit option to keep all (ruling 4), and
**block compression (B)**, revisited after steps 1–4 land with its own
measurement of `read_span`, query latency and library size (ruling 2).

**Target ratios** (one generation, channel on; the evidence is the projection
above, each a sum of measured re-encodings; each target sits 2–6 % above its
projection for the headers, tables and record fields a real encoder adds):

| Corpus | Today | Target after D2 (steps 1–4) |
| --- | ---: | ---: |
| timing 1k / 10k | 4.98 / 4.44 | 2.05 / 2.05 |
| prose 1k / 10k | 4.12 / 4.05 | 1.90 / 1.90 |
| Tamil 1k / 10k | 2.93 / 2.66 | 1.40 / 1.35 |
| fixtures | 3.78 | 1.80 |
| family folder | 4.54 | 2.00 |

With the offsets left out (C5) instead of step 3, each target is about 0.15
lower on the timing and prose corpora (projection 1.81–1.82 timing, 1.63–1.65
prose). With `keep_generations: 2`, as the app runs it, the directory is twice
these.

## Rulings (16 Nov 2026)

The orchestrator ruled on the builder's six questions (kept after the rulings) on 16 Nov 2026
([S6-T3](tasks/S6-T3.md), *Rulings on the Report*):

1. **A′, not A.** The source section keeps only the bytes no chunk holds; the
   query path is unchanged.
2. **Block compression (B) is not taken now.** It is revisited, with its own
   measurement of `read_span`, query latency and library size, after steps 1–4
   land.
3. **The offsets at one byte per token (C5b)**, so `find` is unchanged; its
   decode cost is measured in that step's task. Positions stay mandatory (C6
   not taken).
4. **`keep_generations`:** the CLI's unset default (nothing pruned; five
   one-file updates left 193,688,535 B) is a trap for a new user. A separate
   task, D2-5, makes `searchd index` and `searchd apply` default to keeping two
   generations, with an explicit option to keep all; the C ABI and Dart
   defaults do not change in that task. It goes through the capability process
   as a behaviour change.
5. **The single copy of each path** lives in the source section's file table;
   other sections refer to a file by its ordinal there. *Corrected by the S6-T7
   Phase 1 ruling (17 Nov 2026):* the file table lives in the **documents**
   section ([`documents-v5-source-v2-format.md`](documents-v5-source-v2-format.md)).
   The query path and the open must not depend on the source section, which
   roots that do not retain source do not have, and a damaged source must not
   break a query. The state, catalog and meta paths become ordinals in step 4.
6. **One format version per step**, each with a reader for the previous
   version, a migration note and before/after numbers for size, open, warm
   query, `find`, `read_span` and one-file update.

The order of D2 is the four steps of [the recommendation](#recommendation-for-d2),
with the targets above.

### The questions as the builder put them

1. **A′ or A.** A′ keeps the query path and resident memory as they are and
   rebuilds files for `read_span`; A shrinks what the open reads and what stays
   resident but moves every hit's text read to the source section, and is the
   only way to B. This document recommends A′.
2. **Block compression (B) at all**, and if so which codec: `std.compress.flate`
   (no dependency, better ratio, 0.37 ms per 64 KiB block to decode, +11 KB to
   +23 KB of `__TEXT`) or an in-tree LZ4-style codec (four times faster to
   decode, +1.3 KB to +2.2 KB, larger output). Only with A, and only with a
   block cache or an accepted per-hit cost.
3. **The offsets: one byte per token (C5b, recommended) or left out (C5)**, and
   **positions optional per index** (C6) with its default. C5 trades about
   0.15 of ratio on the timing and prose corpora for `find` words 0.03–0.84 ms
   slower at the median (5.2 ms at p95 on prose); C6 also loses phrase `find`.
4. **The default of `keep_generations`** in `searchd index --update`, the C ABI
   and the Dart binding: unset today keeps every generation. That is a contract
   change, not a format change.
5. **Where the one copy of each path lives** (documents or source table) after
   A′; A2 puts it in the source table, which the open would then read
   (1.0 MB at 10k).
6. Whether D2 ships the four steps as one lexical and one segment/source
   version, or one version per step (the plan says one format version at a
   time).

## Reproduce

See [`docs/evidence/s6-t3/README.md`](evidence/s6-t3/README.md).

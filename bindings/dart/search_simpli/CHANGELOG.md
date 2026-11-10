# Changelog

## 0.7.0 (S5-T5; contract 2.6.0; minor: ranking change)

Verb forms in the word-form groups (`fold-groups-v2`,
`docs/fold-groups-v2.md`). A query word of 4 to 49 letters a-z (after
folding) is also searched as its `-ing` and `-ed` verb forms that a chunk
in scope or a visible file's name holds (`paint`, `paints`, `painted`,
`painting`; `hop`, `hopped`, `hoping`; `tidy`, `tidied`). Code written for
0.6.x compiles and behaves the same against 0.7.0, but a query now also
finds the other verb forms of its words.

- **Contracts 2.6.0** (`contracts/CONTRACTS_VERSION`). As before the
  package accepts exactly its own contract version: a 2.5.0 library is
  refused at `open` with `ContractsVersionMismatchException`, and the
  natives move with the package.
- **The weights.** A word no chunk in scope and no visible file's name
  holds takes its forms at full weight (and `fuzzy-v1` does not also run
  on it). A word the files hold takes a form at half weight, and only when
  the form is held by no more chunks than the word itself, so a word's
  group never takes a document frequency above the word's own through its
  verb forms.
- **The report.** `SearchRetrieval.foldPolicyId` is `"fold-groups-v2"`.
  The forms are listed in the `queryTermGrouped` warning's
  `SearchWarning.members`, in the group's order; there is no new warning
  code and no new field.
- **No index format change.** Nothing is stored in the index and nothing
  is kept between queries; every index a 0.6.x library wrote opens and
  answers the same way. No C ABI signature changed.

## 0.6.0 (S5-T4; contract 2.5.0; minor: ranking change and additive result fields)

Query-side folding and light stemming (`fold-groups-v1`,
`docs/fold-groups-v1.md`). A query word is also searched as the words of
the files in scope, and of the visible file names, that share its fold
key: case and compatibility forms folded (full-width letters, ligatures,
`ß` as `ss`), accents dropped from Latin letters (`café` and `cafe`), an
English plural taken off (`boxes` and `box`, `ponies` and `pony`, with a
short keep list such as `glasses`), and seven Tamil plural and case
suffixes taken off while two Tamil letters stay. Code written for 0.5.x
compiles and behaves the same against 0.6.0, but a query now also finds
the other forms of its words.

- **Contracts 2.5.0** (`contracts/CONTRACTS_VERSION`). As before the
  package accepts exactly its own contract version: a 2.4.0 library is
  refused at `open` with `ContractsVersionMismatchException`, and the
  natives move with the package.
- **The members.** Every word that shares the key and is held by a chunk
  in scope (roots, labels and the path prefix), or by a visible file's
  name under the prefix. The typed word first, then the most chunks in
  scope, then bytes. A word only hidden chunks or files hold is never
  used or reported. There is no cap on the members.
- **The scoring.** The members score as one word, as fuzzy-v1's do: one
  document frequency (the largest of theirs), and each chunk adds its best
  member's part, every member weighted 1.0. A file's title part does the
  same over the names. `both` uses the same groups for its body and title
  parts; `filename` is never grouped. `fuzzy-v1` runs only on the words
  that have no group. A query with no group ranks exactly as under 0.5.x.
- **New, nullable:** `SearchRetrieval.foldPolicyId` (`"fold-groups-v1"`
  whenever the lexical channel ran under `content` or `both` on an
  `analyzer-v2` index), `SearchWarningCode.queryTermGrouped` and
  `SearchWarning.members`: a word with a group gets a `queryTermGrouped`
  warning with the other words searched (the word itself left out). An
  unmatched word keeps its `queryTermUnmatched` warning, and its
  `queryTermGrouped` warning follows it; the grouped warnings of words the
  files hold come after every unmatched word's, in query order.
- **`ascii-alnum-v1` indexes** are not grouped and carry no
  `foldPolicyId`.
- **No index format change.** Nothing is stored in the index: the key map
  is built from the dictionary and the file names at the first grouped
  query on a handle (kept with the handle, freed at close). Every index a
  0.5.x library wrote opens unchanged, and nothing is rebuilt. No C ABI
  signature changed.
- **Natives** rebuilt on the Mac: macOS 936,792 B (0.5.0: 884,632),
  Android 910,944 B (858,224), iOS framework binary 917,904 B (865,096);
  `native/SOURCE-SHA256` is `81f9c76b…`.

## 0.5.0 (S5-T3; contract 2.4.0; minor: ranking change and additive result fields)

Misspelling tolerance (`fuzzy-v1`, `docs/fuzzy-v1.md`). A query word that
no chunk in scope and no visible file's name holds, written in Latin
letters and at least 5 code points long, is also searched as up to 3
dictionary words within one edit (5 code points) or two (6 or more), an
edit being an insertion, a deletion, a substitution or a swap of two
neighbours (optimal string alignment). The first letter is kept. Code
written for 0.4.x compiles and behaves the same against 0.5.0, but a
query with a misspelt word now finds what the right word finds.

- **Contracts 2.4.0** (`contracts/CONTRACTS_VERSION`). As before the
  package accepts exactly its own contract version: a 2.3.0 library is
  refused at `open` with `ContractsVersionMismatchException`, and the
  natives move with the package.
- **The words kept.** Fewest edits first, then the most chunks in scope
  (roots and labels; a path prefix decides membership, not the count),
  then bytes. A word only hidden chunks or files hold is never used or
  reported. A file-name word no chunk holds counts as one chunk.
- **The scoring.** The kept words score as one word: one document
  frequency (the largest of theirs), and each chunk adds its best word's
  part, weighted 1.0 at one edit and 0.5 at two. A file's title part does
  the same over the names. `both` uses the same words for its body and
  title parts; `filename` is never expanded. A query with no such word
  ranks exactly as under 0.4.x.
- **New, nullable:** `SearchRetrieval.fuzzyPolicyId` (`"fuzzy-v1"`
  whenever the lexical channel ran under `content` or `both` on an
  `analyzer-v2` index), `SearchWarningCode.queryTermExpanded` and
  `SearchWarning.expansions`: the typed word keeps its
  `queryTermUnmatched` warning, and a `queryTermExpanded` warning with the
  words searched, best first, follows it.
- **`ascii-alnum-v1` indexes** are not expanded and carry no
  `fuzzyPolicyId`.
- **No index format change.** Nothing is stored: the words are found at
  query time from the dictionary the index already holds. Every index a
  0.4.x library wrote opens unchanged, and nothing is rebuilt. No C ABI
  signature changed.
- **Natives** rebuilt on the Mac: macOS 884,632 B (0.4.0: 866,168),
  Android 858,224 B (842,272), iOS framework binary 865,096 B (846,680);
  `native/SOURCE-SHA256` is `8f73bf9c…`.

## 0.4.0 (S5-T2; contract 2.3.0; minor: ranking change and additive result fields)

The title field (`title-field-v1`, `docs/title-field-v1.md`). A file's
folder names (relative to its root, never the root id) and its file stem,
tokenized with `analyzer-v2`, are a short field scored with BM25 (k1 1.2,
b 0.75) times its coverage of the query's distinct terms, weighted 2.5.
The part joins the lexical channel. Code written for 0.3.x compiles and
behaves the same against 0.4.0, but rankings change wherever a query word
names a folder or a file.

- **Contracts 2.3.0** (`contracts/CONTRACTS_VERSION`). As before the
  package accepts exactly its own contract version: a 2.2.0 library is
  refused at `open` with `ContractsVersionMismatchException`, and the
  natives move with the package.
- **`content` (the default).** With a lexical channel (`lexical` or
  `hybrid` mode), each file's title part is added to its best in-scope
  chunk (an exact tie goes to the smaller chunk id), or, when no chunk of
  the file matches the body, to its first chunk; the channel's
  `candidate_k` cut comes after the sum. `ranking.lexical.score` is the
  body score plus that part.
- **`both`.** A score-level merge, one result per file: the file's best
  body chunk's BM25 plus its title part, ordered by score, then path, then
  chunk id. `candidate_k` is still validated (≥ `topK`) but cuts no
  channel before the sum. `ranking.lexical.rank` and
  `ranking.filename.rank` stay positions within each channel's first
  `candidate_k`; the scores are reported whenever positive, and
  `matchedIn` names a channel that scored the file. `filename` is
  unchanged.
- **New, nullable:** `SearchRetrieval.titlePolicyId` (`"title-field-v1"`
  whenever the lexical channel ran under `content` or `both`) and
  `SearchResultItem.titleScore` (`ranking.title.score`). Under `content`
  only the chunk that received its file's part carries `ranking.title`;
  under `both` every result does, with a null score when the file's title
  took no part.
- **Scope.** The title statistics (file count, average length, document
  frequency) are over the files the request can see: roots and labels
  narrow them, a path prefix does not.
- **No index format change.** The field is derived from a generation's
  records at its first `content` or `both` query on a handle, once per
  opened generation, and never at `open`. Every index a 0.3.x library
  wrote opens unchanged, and nothing is rebuilt. No C ABI signature
  changed.
- **Natives** rebuilt on the Mac: macOS 866,168 B (0.3.12: 843,240),
  Android 842,272 B (806,544), iOS framework binary 846,680 B (807,624);
  `native/SOURCE-SHA256` is `62c37f1f…`.

## 0.3.12 (S4-T18; contract 2.2.0; patch: the library's `memcpy`, no format or API change)

The library's `memcpy`, `memmove` and `memset` copy 16 bytes at a time.
They were `compiler_rt`'s `ReleaseSmall` versions, which move one byte per
loop step. No Dart API, C ABI, contract (`contracts/` stays 2.2.0), index
format or result changed: every section a generation writes and every
query and `find` page are byte for byte what 0.3.11 writes and answers. An
index any 0.3.x library wrote opens and updates unchanged, and nothing is
rebuilt. The natives changed (rebuilt twice on the Mac, byte-identical;
their bytes differ from 0.3.11's, two of the sizes happen not to: macOS
843,240 B, as 0.3.11's; Android 806,544 B against 805,744 B; iOS framework
binary 807,624 B, as 0.3.11's); `native/SOURCE-SHA256` is `7a8f13ff…`.

- **What `memcpy` was and is, per target.** Zig 0.16 links its own
  `compiler_rt` into every shared library and executable. In `ReleaseSmall`
  that `memcpy`, `memmove` and `memset` are byte loops, and they were the
  library's on every target. Each copy cost about one cycle per byte
  (0.3.11 on the 10,000-file corpus: 9,273,775 B in 2.06 ms warm, 4.5 GB/s).
  The library now links its own `fastmem` object (`zig/src/fastmem.zig`)
  into the macOS dylib, the Android `.so`, the iOS framework and `searchd`.
  Its `memcpy`, `memmove` and `memset` are hidden and nothing new is
  exported. They move 16-byte vectors, use overlapping windows for short
  lengths and the last bytes, and are exact for overlapping `memmove`
  ranges in both directions. A `ReleaseSmall` build compiles this one
  object `ReleaseFast` and stripped: in `ReleaseSmall` the machine outliner
  gave `memcpy` a stack frame and turned its 2–32 byte paths into calls,
  and most of the library's copies are that short (`find` makes 56,424 of
  1–15 B). `compiler_rt`'s three are no longer in any
  artifact. Zeroing still calls `libSystem`'s `bzero` on macOS and iOS; on
  Android it goes through the library's `memset`. `strlen` stays
  `compiler_rt`'s (two call sites, request strings).
- **The iOS framework's link** localizes `compiler_rt.o`'s three symbols
  before Apple's linker sees them (`tool/build_native.sh`, `nmedit -R`).
  Without that step, Apple's linker refuses the duplicate definitions.
  `tool/check_native.sh` checks that `memcpy` in all three natives moves
  16-byte registers and has no byte loop. The 0.3.11 natives fail that
  check.
- **On the 10,000-file timing corpus** (`ReleaseSmall`, interleaved with
  0.3.11's source, p50; the second figure is the same source with symbols
  kept, a second code layout): one changed file 47.5–47.7 → 39.5–40.4 ms
  with filename search off and 56.6–56.9 → 49.3–49.6 ms with it on
  (47.5–48.5 → 40.0–41.0 and 56.3–57.1 → 48.9–49.7); the full build
  637.4 → 587.6 ms off and 651.8 → 604.3 ms on (7.8 % and 7.3 %); `find`
  3.43–3.45 → 3.01–3.04 ms (3.41–3.43 → 3.00–3.02); `search_knowledge`'s
  content query 0.399–0.401 → 0.139–0.142 ms (0.396–0.399 → 0.137–0.142);
  the first query after a cold open 0.087–0.090 → 0.058–0.061 ms for
  content, 3.80–3.84 → 3.22–3.25 ms for filename and 3.92–3.93 → 3.30–3.32
  ms for `both` (3.19–3.21 and 3.25–3.28 in the second layout); the
  documents section's 9,273,775 B copy 2.02–2.08 → 0.141–0.145 ms warm
  (4.5 → 64–66 GB/s) and 2.43–2.49 → 0.60–0.62 ms cold. `ss_open`, `read_span`
  and `outline` are where they were (numbers in `docs/tasks/S4-T18.md`).

## 0.3.11 (S4-T17; contract 2.2.0; patch: reader only, no format or API change)

`find` ranks its hits by sorting a list of positions and checks scope by
pointer, so its time no longer depends on where the compiler puts a byte
loop. No Dart API, C ABI, contract (`contracts/` stays 2.2.0), index format,
writer or result changed: every `find` page and every query answers byte for
byte as 0.3.10 does, every section a generation writes is what 0.3.10
writes; an index any 0.3.x library wrote opens and updates unchanged and
nothing is rebuilt. The natives changed (rebuilt twice on the Mac,
byte-identical: macOS 843,240 B, 16,704 B larger than 0.3.10's 826,536 B
unsigned, from the `ReleaseSmall` outliner's layout, not from code size:
`__text` grew 640 B; Android 805,744 B; iOS framework binary 807,624 B);
`native/SOURCE-SHA256` is `2c401431…`.

- **The ranking sorts 4-byte positions.** Every kept hit is still ranked
  in full (score, root, path, start line, record number: a total order),
  but the sort moves positions into the candidate list and each hit is then
  copied once in rank order. Sorting the 64-byte hit records themselves
  moved each one a byte at a time, and the `ReleaseSmall` outliner made that
  a call per byte in some builds (0.3.10's). The full order is kept, not a
  bounded top page: `files` lists every file in the order it first appears
  in the whole ranking.
- **Scope by pointer.** The per-posting scope check took the engine
  (464 B) and the request (184 B) by value and copied both for every
  posting it checked; it takes them by pointer now, and so does the prefix
  expansion's per-term check.
- **On the 10,000-file timing corpus** (`find` `the`, words, 20 a page,
  `ReleaseSmall`, p50 of 30, two interleaved runs, two processes per build
  and run): 7.78–7.83 ms (0.3.10 as shipped) and 7.03–7.13 ms (the same
  source with symbols kept, a second code layout) → **3.42–3.45 ms in both
  layouts**; `ss_open`, the reads, the queries and the first query after an
  open where they were; `find`'s NFR-13 peak at 15,000 files on one handle
  61,221,729 → 60,915,647 B (numbers in `docs/tasks/S4-T17.md`).

## 0.3.10 (S4-T16; contract 2.2.0; patch: writer only, no format or API change)

One changed file no longer re-does every unchanged file in the writer's
`loadPrevious`, its documents pass and the documents encode. No Dart API, C
ABI, contract (`contracts/` stays 2.2.0), index format, reader or result
changed: every section a generation writes is byte for byte what 0.3.9
writes for the same files, and every query and read answers as 0.3.9 does;
an index any 0.3.x library wrote opens and updates unchanged and nothing is
rebuilt. The natives changed (rebuilt twice on the Mac, byte-identical:
macOS 826,536 B, Android 804,560 B, iOS framework binary 807,088 B);
`native/SOURCE-SHA256` is `1a7887aa…`.

- **The previous documents by range.** A generation the writer wrote keeps
  each path's records together and in path order, so each path maps to one
  range of the previous section (checked in the one pass that builds the
  map; any other generation, such as an `import-json` one, takes the list
  per path as before).
- **One walk where there were lookups.** `loadPrevious` sizes its tables
  once, fills the chunker and initial tables in one step, answers "has
  previous records" by one forward walk when the state's records ascend,
  and skips the records-not-in-state loop when the walk has matched every
  path.
- **No sort and no search for unchanged files.** The documents pass places
  each file the state put, still under its key with the same record slice,
  by its state position and merges in only the added, moved and re-put
  files (the result is the sort's); a file's previous source entry comes
  from a cursor over the section's table, which is in the same order.
- **The documents section is validated once.** `segment.encodeAllocV4`
  validates and sizes in one walk, allocates exactly and writes; the
  writer had validated every record twice and walked the vectors three
  times. Every refusal keeps its name.
- **On the 10,000-file timing corpus** (`ReleaseSmall`, one changed file,
  stage timers on, p50 of ten, two interleaved runs): the three stages
  20.4–20.6 → 8.6–8.7 ms; the call's stages 58.4–58.5 → 46.8–47.0 ms with
  the filename channel off and 67.3–68.1 → 55.7–55.9 ms on; the full build,
  `ss_open`, the first query after an open, the queries and the reads where
  they were; NFR-13 at 15,000 files on one handle unchanged. `find` (`the`,
  words, 20 a page) measures 5.84 → 7.79 ms with its code unchanged: its
  sort swaps 64-byte hit records a byte at a time, and in this build the
  `ReleaseSmall` outliner turns each byte into a call; S4-T17 takes the fix
  (numbers in `docs/tasks/S4-T16.md`).

## 0.3.9 (S4-T15; contract 2.2.0; patch: reader only, no format or API change)

The `both` and filename queries keep a bounded top `candidate_k` per channel
instead of sorting every scored file. No Dart API, C ABI, contract
(`contracts/` stays 2.2.0), index format, writer or result changed: every
query answers byte for byte as 0.3.8 does, every section a generation writes
is what 0.3.8 writes; an index any 0.3.x library wrote opens and updates
unchanged and nothing is rebuilt. The natives changed (rebuilt twice on the
Mac, byte-identical: macOS 825,976 B, Android 798,960 B, iOS framework binary
806,416 B); `native/SOURCE-SHA256` is `1f27e1b1…`.

- **A bounded selection, the same order.** Each channel (the body's best
  chunk per file, and the file names) keeps its top
  `min(candidate_k, candidates)` in a heap under exactly the order the full
  sort used (score descending, then path bytes, then the chunk id). That
  order is total over a channel's candidates, so the kept list is the full
  sort's first `candidate_k`, element for element; the fusion (equal RRF,
  k = 60), the `top_k` cut and the hit order are untouched.
- **Identical results.** The query capture's 2,762 queries and, asking every
  query also as `filename` and `both` at eight depths over the 10,000-file
  corpus and the family fixture, 16,490 queries are byte-identical to
  0.3.8's; a random test compares the selection with the full sort over 30
  corpora (64,082 candidates).
- **On the 10,000-file timing corpus** (`ReleaseSmall`, warm p50, filename
  channel on, 20 interleaved rounds, two runs): the `both` query 3.25–3.48 →
  0.49–0.53 ms (the body sort alone had been 2.38 ms, the filename sort
  0.60 ms), and its spread over 20 rounds 0.10–0.24 → 0.02–0.04 ms; the
  filename query 0.77–0.83 → 0.25–0.27 ms; `ss_open`, `find`, the reads and
  the content query where they were; NFR-13 at 15,000 files on one handle
  `both` 58,866,083 → 57,696,077 B and filename 58,503,099 → 56,986,061 B
  peak (numbers in `docs/tasks/S4-T15.md`).

## 0.3.8 (S4-T14; contract 2.2.0; patch: reader and writer, no format or API change)

A source section's line map is checked where its file is read, not for the
whole folder at first use and not at the writer's open. No Dart API, C ABI,
contract (`contracts/` stays 2.2.0), index format or result for an
undamaged index changed: every section a generation writes is byte for byte
what 0.3.7 writes for the same files, and every `read_span`, `outline` and
query answers as 0.3.7 does; an index any 0.3.x library wrote opens and
updates unchanged and nothing is rebuilt. The natives changed (rebuilt twice
on the Mac, byte-identical: macOS 843,640 B, Android 805,632 B, iOS
framework binary 807,648 B); `native/SOURCE-SHA256` is `7e628aad…`.

- **First use checks the section, not every map.** The first `read_span` or
  `outline` on a handle still checks the section's size, header, files
  table and checksum over the streamed text (so `index_status` moves from
  `unverified` to `verified` or `unavailable` on the same evidence) and
  bounds every line map by its varints, but walks no map against its bytes
  and builds no sparse line index.
- **Each read checks its one file.** A file's first `read_span` or
  `outline` on a handle checks its line map and encoding byte against the
  bytes it has just read and hashed, once per file per handle (one bit per
  file: 1,256 B at 10,000 files). A map that disagrees answers `capacity`
  "re-index required: source section unavailable (InvalidLineMap)" for that
  file alone; every other file answers and `index_status` stays `verified`
  (0.3.7 refused every file). The first request to such a file answers that
  message even where the size limit would otherwise refuse the span.
- **The writer's open bounds the maps instead of walking them.** A
  checksum-valid map that disagrees with its bytes (only a wrong writer
  makes one) is carried as it is and costs its one file until an update
  changes that file.
- **On the 10,000-file timing corpus** (`ReleaseSmall`, p50): the first
  `read_span` on a cold handle 9.3–9.8 → 1.26 ms; the open of the previous
  generation 20.7 → 10.7–10.9 ms; one changed file 68.4 → 59.0 ms with the
  filename channel off and 78.0 → 69.2 ms with it on (two interleaved runs
  of five); a file's first read on a handle about 0.13 ms per MiB more
  (0.58 against 0.44 ms for a 1,133,158-byte file), later reads unchanged;
  the full 10k build within 1 %; `ss_open`, `find` and the queries where
  they were (numbers in `docs/tasks/S4-T14.md`).

## 0.3.7 (S4-T13; contract 2.2.0; patch: writer only, no format or API change)

The writer's open of the previous generation checks each section once, and
the filename channel carries its lexical section when no path changed. No
Dart API, C ABI, contract (`contracts/` stays 2.2.0), index format, reader
or result changed: every section a generation writes is byte for byte what
0.3.6 writes for the same files; an index any 0.3.x library wrote opens and
updates unchanged and nothing is rebuilt. The natives changed (rebuilt twice
on the Mac, byte-identical: macOS 843,992 B, Android 806,928 B, iOS
framework binary 808,184 B); `native/SOURCE-SHA256` is `9f013deb…`.

- **The previous lexical section is decoded without its positions walk.**
  Its checksum is still computed and compared with the manifest's. A
  carried posting's position bytes are copied, not interpreted, and a
  checksum-valid section whose positions are wrong (only a wrong writer
  makes one) is still refused before anything is published: by the merge's
  checked walk (`InvalidLexicalSection`, the S4-T12 end-of-walk checks, now
  reachable from a file) or by the new section's own validation
  (`InvalidPositions`).
- **The previous source section's checksum is computed once.** Its line
  maps are still checked against their bytes at the writer's open, so a
  checksum-valid section with a wrong line map refuses the update
  (`InvalidLineMap`, nothing published).
- **The filename channel's lexical section is carried** when the update
  keeps every path, in order, with its labels: the previous
  `filename-lexical-N.hyblex` is copied after its size, checksum, kind and
  counts are checked; only the catalog is re-encoded. A rename, add, remove
  or label change, or a previous section that fails a check, takes the full
  build.
- **On the 10,000-file timing corpus** (`ReleaseSmall`, p50): the open of
  the previous generation 26.3 → 21.6 ms off and 26.2 → 21.0 ms on; the
  filename build and its check 12.8 → 4.7 ms; one changed file 73.8 →
  68.2 ms with the filename channel off and 91.0 → 78.0 ms with it on (two
  interleaved runs of five); the full 10k build unchanged (within 0.2 %).
  `ss_open`, `find` and the queries are where they were (numbers in
  `docs/tasks/S4-T13.md`).

## 0.3.6 (S4-T12; contract 2.2.0; patch: writer only, no format or API change)

Writing a lexical section validates it once. No Dart API, C ABI, contract
(`contracts/` stays 2.2.0), index format, reader or result changed: every
section a generation writes is byte for byte what 0.3.5 writes for the same
files; an index any 0.3.x library wrote opens and updates unchanged and
nothing is rebuilt. The natives changed (rebuilt twice on the Mac,
byte-identical: macOS 826,696 B, Android 802,816 B, iOS framework binary
807,648 B); `native/SOURCE-SHA256` is `ccb31963…`.

- **One validation per lexical section written.** The writers sized the
  section with `encodedLength` and then wrote it with `encode`, and each
  ran the whole index check; they now call one function that checks once,
  sizes, allocates and writes. Every refusal keeps its name; `encode` on
  its own still refuses an invalid index.
- **No hash set for a sorted dictionary.** A positional (`HYBLEX02`)
  dictionary must be sorted, so its duplicate check is one pass over
  neighbours; `HYBLEX01` (`import-json`, the filename channel's section)
  keeps the hash set.
- **The merge's end-of-walk checks refuse in every build.** Two checks that
  were Debug asserts in front of the same refusal (dropped by
  `ReleaseSmall`) are now plain refusals (`InvalidLexicalSection`). No file
  reached them: the decoder refuses such a section first.
- **On the 10,000-file timing corpus** (`ReleaseSmall`, p50): the lexical
  section's encode in one changed file 15.9 ms → 8.8 ms; one changed file
  80.6 ms → 74.3 ms with the filename channel off and 98.9 ms → 92.3 ms
  with it on (a second run 79.7 → 74.3 and 98.0 → 92.2); the full 10k
  build about 2.5 % faster. `ss_open`, `find`, the content and filename
  queries are where they were; the warm `both` query measured 0.44 ms
  slower in this build with no reader changed (numbers and the reason in
  `docs/tasks/S4-T12.md`).

## 0.3.5 (S4-T11; contract 2.2.0; patch: writer only, no format or API change)

One changed file costs less to write. No Dart API, C ABI, contract
(`contracts/` stays 2.2.0), index format, reader or result changed: every
section a generation writes is byte for byte what a full index of the same
files writes, as before; an index any 0.3.x library wrote opens and updates
unchanged and nothing is rebuilt. The natives changed (rebuilt twice on the
Mac, byte-identical: macOS 826,936 B, Android 802,768 B, iOS framework
binary 807,320 B); `native/SOURCE-SHA256` is `4a0db851…`.

- **The lexical section is carried, not rebuilt.** `apply_changes` (and
  `searchd index --update`) used to turn every unchanged document's
  positions back into one entry per token, sort the whole corpus again and
  re-encode every posting. It now merges the previous dictionary with the
  changed files' terms by bytes, keeps each unchanged posting with its
  document number remapped, and copies its position bytes as they are.
  On the 10,000-file timing corpus the lexical build of one changed file
  went from 33.8 ms to 4.9 ms (p50).
- **The source section keeps each unchanged file's record.** The SHA-256,
  the line map and the encoding byte of a file whose bytes did not change
  are copied from the previous source section instead of being hashed and
  scanned again; the bytes are still copied whole. Source line maps
  10.9 ms → 0.35 ms, SHA-256 2.7 ms → 0.03 ms.
- **One changed file, 10,000 files, p50 of five:** 122.1 ms → 77.8 ms with
  the filename channel off, 140.0 ms → 96.0 ms with it on (NFR-12's bound
  is 200 ms). `ss_open`, the queries, `find` and the full build are where
  they were (the numbers are in `docs/tasks/S4-T11.md`).

## 0.3.4 (S4-T10; contract 2.2.0; patch: no format or API change)

`read_span` and `outline` hold only the file they answer about. No Dart
API, C ABI, contract (`contracts/` stays 2.2.0), index format, writer or
result changed; an index any 0.3.x library wrote opens unchanged and
nothing is rebuilt. The natives changed (rebuilt twice on the Mac,
byte-identical: macOS 826,376 B, Android 793,184 B, iOS framework binary
790,512 B); `native/SOURCE-SHA256` is `b19b2725…`.

- **One handle's peak live bytes.** The first `read_span` or `outline`
  used to read the whole source section (every retained file's bytes) and
  keep it for the life of the handle. It now keeps only the section's
  header, files table and line maps (1,009,678 B at 10,000 files), reads
  the text once through a buffer of at most 1 MiB to check the checksum
  and the line maps, and then each call reads its own file's bytes and
  checks them against the file's SHA-256 (a mismatch answers `CAPACITY`
  "re-index required: source section unavailable
  (SourceFileSha256Mismatch)"). Measured with the engine's
  capped-allocator test, every operation in turn on one handle, filename
  channel on, highest peak: 10,000 files 51,053,247 B before, 43,739,911 B
  after; 15,000 files 71,326,060 → 61,221,469 B; 20,000 files 93,656,572 →
  79,207,415 B. At 15,000 files every operation on one handle now stays
  under the 64 MiB workspace cap (NFR-13).
- **Time.** The first `read_span` after an open is faster (it no longer
  copies the text); a later `read_span` or `outline` reads one file from
  disk instead of memory; `ss_open`, `find`, the queries and one changed
  file stay where they were (the numbers are in `docs/tasks/S4-T10.md`).

## 0.3.3 (S4-T9; contract 2.2.0; patch: no format or API change)

The open holds only what it reads. No Dart API, C ABI, contract
(`contracts/` stays 2.2.0), index format or result changed; an index any
0.3.x library wrote opens unchanged and nothing is rebuilt. The natives
changed (rebuilt twice on the Mac, byte-identical: macOS 826,344 B, Android
788,000 B, iOS framework binary 789,840 B); `native/SOURCE-SHA256` is
`d1240609…`.

- **The open's peak live bytes.** `ss_open` used to take one arena request
  for the documents and lexical sections plus a reservation for the source
  section and the filename sections it does not read, and the arena sized
  that block at about 1.5 times the request. It now allocates one exact
  block from the C allocator for what it reads (the manifest, the two
  sections, the tables decoded from them), and the source section and the
  filename sections get one exact block each at their first use; `ss_close`
  frees them. Measured with the engine's capped-allocator test (filename
  channel on, peak live bytes): 10,000 files 50,128,018 B before,
  33,567,893 B after; 15,000 files 74,149,978 → 49,138,697 B; 20,000 files
  98,275,150 → 64,782,850 B. At 15,000 files every operation, each on its
  own handle, now stays under the 64 MiB workspace cap (NFR-13).
- **Time.** `ss_open` at 10,000 files, the first `read_span`, the first
  filename query and one changed file stay where they were (the numbers
  are in `docs/tasks/S4-T9.md`).

## 0.3.2 (S4-T6; contract 2.2.0; patch: no API change)

A crash in `searchd`, not in this package's library. No Dart API, C ABI or
contract changed (`contracts/` stays 2.2.0); the three native binaries are
byte-identical to 0.3.1's, rebuilt twice on the Mac (macOS 825,736 B,
Android 787,216 B, iOS framework binary 789,304 B); `native/SOURCE-SHA256`
changes (`7762a23a…`) because the sources it digests changed.

- **The crash.** A release build of `searchd serve --allow-write`
  (`ReleaseSmall`, `ReleaseFast`, `ReleaseSafe`) answered `apply_changes`
  and then died with signal 11 on the next call that loads a table lazily
  (`read_span`, `outline`, `find`, `search_knowledge`, `list_files`),
  without a reply. Since S4-T1 (0.2.1) the reloaded generation kept an
  allocator that pointed at a freed `ArenaAllocator`; Debug builds never
  reuse freed memory, so every Debug suite stayed green. `searchd mcp` held
  the same dangling pointer into a stack slot.
- **The fix.** The served generation owns an arena on the heap that never
  moves (`rpc.Generation`); a reload opens the new generation, then closes
  the old one, files included (the old reload also left the old
  generation's section files open, one set per write).
- **A release library's handle after a write on the same directory**
  (the contract, now stated in `search_simpli.h` and tested in Debug and
  `ReleaseSmall` by `zig/tests/abi_test.c`): a handle opened before
  `ss_apply_changes` / `SearchSimpli.applyChanges` on the same directory
  keeps answering the generation it opened, also after the write prunes
  that generation's files (`keepGenerations`); close it and open again to
  see the new generation. The library path never had the defect: the same
  test passes against the 0.3.1 library in both build modes.
- CI now runs the engine tests, the C ABI harness and the Python suites
  against a `ReleaseSmall` build too.
- **The stamp moved once, the binaries did not (S4-T8).** `tool/source_digest.py`
  no longer digests the engine's test files (`zig/src/**/*_test.zig`, 19 files;
  none is built into the libraries), so `native/SOURCE-SHA256` changes from
  `7762a23a…` to `00794146…` with the three binaries byte-identical to the
  ones above. A consumer that keys on the stamp treats `7762a23a…` and
  `00794146…` as the same core.

## 0.3.1 (S4-T4; contract 2.2.0; patch: no API change)

The cheaper edit. No Dart API, C ABI or contract changed (`contracts/` stays
2.2.0); the natives are rebuilt (`native/SOURCE-SHA256` `db21322e…`).

- **Recovery state: one copy, binary.** Each generation's bound state section
  `state-N.hybstate` is now the `HYBSTA02` binary form
  (`docs/state-section-format-v2.md`): 970,159 B on the 10k timing corpus
  against 2,522,562 B of JSON (`HYBSTA01`). `INDEX-STATE.json` becomes a
  version 3 pointer to it (generation, analyzer, section file name; 94 B
  against 2,522,530 B), so a generation writes 970,253 B of state instead of
  5,045,092 B. Writers still accept a full version 2 `INDEX-STATE.json` and a
  `HYBSTA01` section, so directories written by 0.2.x and 0.3.0 open and
  update (the first update writes the new forms).
- **One changed file in the 10k index** (`applyChanges`, `ReleaseSmall`, five
  runs, p50): 123.2 ms without filename search (0.3.0: 147.7 ms) and 141.6 ms
  with it (0.3.0: 172.0 ms). The filename sections are byte-identical to
  0.3.0's; `open` (7.12–7.23 ms against 7.19–7.22 ms) and filename queries
  (p50 0.026 ms at 10k over RPC) are unchanged.
- **Rollback rule:** a 0.3.0 library still opens and queries a directory 0.3.1
  has updated, but refuses to update it (`SS_ERR_CORRUPT_SNAPSHOT`,
  `InvalidStateSection`); a library older than 0.3.0 refuses it at `open`, as
  before. Keep the previous directory (or rebuild one with the older library)
  to roll back to; never roll the library back over a directory 0.3.1 has
  updated and keep writing to it.

## 0.3.0 (S4-T2, PR #21; contract 2.2.0; minor: new public API)

PR #21 (the filename channel, recovery bound to the commit point, scoped
writers) integrated onto main after S4-T1. Everything below is additive: code
written for 0.2.1 compiles and behaves the same against 0.3.0.

- **Contracts 2.2.0** (`contracts/CONTRACTS_VERSION`). As before the package
  accepts exactly its own contract version, so a 2.1.0 library is refused at
  `open` with `ContractsVersionMismatchException`; the natives move with the
  package.
- **Filename search (CAP-16, `filename-field-v1`), opt-in.** New:
  `SearchField` (`content`, `filename`, `both`), `query(searchField:)`
  (filename and both need `mode: RetrievalMode.lexical`; anything else throws
  `ArgumentError`), `SearchResultItem.matchedIn`, `.basename` and
  `.matchSections` (`MatchSection*`: separate filename and content
  citations), `SnapshotStatus.filenamePolicyId` (nullable; set on enabled
  directories only), `ApplyChangesOptions.filenameIndex` and
  `IndexFolderOptions.filenameIndex` (nullable: omitted keeps a directory's
  setting), and `SnapshotInterchangeV2`. The channel is chosen when a
  directory is created: pass `filenameIndex: true` to the first
  `applyChanges` (or `indexFolder`) on a new, empty directory; an existing
  directory needs a fresh one rebuilt from every file's bytes, then a switch.
  A value that differs from the directory's setting raises
  `FilenameSettingMismatch`; a filename query on a directory without the
  channel raises `FilenameIndexUnavailable`.
- **Index format: manifest v2.2** (`docs/manifest-format-v2.md`). A
  filename-enabled generation sets manifest v2 flag bit 3 (same magic and
  version; PR #21's interim `HYBMAN03` is not written or read). Every
  generation `applyChanges` or `indexFolder` writes also binds its recovery
  state as its own section, `state-N.hybstate` (flag bit 4), which only the
  next writer reads; `open` never does. Indexes written by 0.2.0 and 0.2.1
  open and update. **Rollback rule:** a library older than 0.3.0 refuses
  every folder generation 0.3.0 writes (`UnsupportedFlags`, bit 4, with or
  without filename search), so do not roll the library back over a
  directory 0.3.0 has updated: keep the previous directory (or rebuild one
  with the older library) to roll back to.
- **Scoped writers** (RPC/MCP servers started with `--roots`/`--labels`)
  cannot declare roots, change label policy or read files; trusted Dart and C
  callers are unaffected.

## 0.2.1 (S4-T1; contract 2.1.0; additive)

- **`SnapshotStatus.source`** (nullable `String`): the source section's state
  from `ss_status`, `absent`, `unverified`, `verified` or `unavailable`.
  `SearchSimpli.open` no longer reads or checks the source section (nor builds
  the statistics and position tables); the first `readSpan`, `outline` or
  `listFiles` that needs it does, so a damaged source section surfaces there
  as `SS_ERR_CAPACITY` ("re-index required: source section unavailable …"),
  not at `open`. No ABI function changed.
- **Contracts 2.1.0** (`contracts/CONTRACTS_VERSION`): the status schema
  gains `source`. As before, the package accepts exactly its own contract
  version, so a 2.0.0 library is refused with
  `ContractsVersionMismatchException`; the shipped native libraries are
  rebuilt at 2.1.0.
- **Index format** (manifest v2.1, `docs/manifest-format-v2.md`): generations
  written by this release use XXH3-64 section checksums. Indexes written by
  0.2.0 still open and update (the first update writes v2.1); a 0.2.0 library
  refuses a v2.1 index (`UnsupportedFlags`).

## 0.2.0 (S3-T8; contract 2.0.0; breaking: an old library is refused)

The folder-knowledge release (CAP-19, series S3). The package version moves
from 0.1.0 to 0.2.0 because a native library older than this release is now
refused. The three shipped native libraries (macOS arm64, Android arm64, iOS
arm64 framework, 16 KiB aligned) are rebuilt from the same source
(`native/SOURCE-SHA256`), and the details below (added by S3-T4) are what
changed.

- **Six new ABI functions** (`zig/include/search_simpli.h`, contract 2.0.0):
  `ss_find`, `ss_outline`, `ss_read_span`, `ss_list_files`, `ss_roots` and
  `ss_apply_changes`. The ten functions of contract 1.x keep their signatures.
- **Contracts 2.0.0** (`contracts/CONTRACTS_VERSION`), a major: new methods and
  result fields, old requests keep working.
- **New Dart methods** on `SearchSimpli`: `find`, `outline`, `readSpan`,
  `listFiles`, `roots`, and the static `SearchSimpli.applyChanges`
  (alongside `open`, `status`, `query`, `evidence` and the static
  `indexFolder`).
- **New exception behaviour:** `ContractsVersionMismatchException` is thrown by
  `SearchSimpli.open` and `SearchSimpli.applyChanges` when the library reports
  another contract version or lacks one of the six functions.

## Contract 2.0.0 (S3-T4)

- **Requires a native library at contract 2.0.0.** `SearchSimpli.open` and
  `SearchSimpli.applyChanges` throw `ContractsVersionMismatchException` for
  an older library (it reports another version, or lacks `ss_find`,
  `ss_outline`, `ss_read_span`, `ss_list_files`, `ss_roots` or
  `ss_apply_changes`).
- New: `find`, `outline`, `readSpan`, `listFiles`, `roots` on `SearchSimpli`,
  and the static `SearchSimpli.applyChanges`, with typed results
  (`FindResult`, `FindHit`, `OutlineResult`, `SpanResult`, `FileListResult`,
  `ListedFile`, `RootsResult`, `RootInfo`, `ApplyChangesReport`,
  `ApplyChangesOptions`, `FindMode`, `FileStatus`, `ResultScope`,
  `ResultWarning`). Each result keeps the engine's JSON as `json`.
- `query` and `evidence` take `roots`; evidence items carry `rootId`,
  `sectionPath` and `neighbours` (`EvidenceNeighbours`, `ChunkRef`).
- `SnapshotStatus` gains `files`, `pending`, `truncated`, `roots`,
  `pendingPaths`, `hasSource`, `hasPositions`, `chunkers`; its counts are
  now over the default scope (every root, no labels), so a labelled file is
  not counted.
- `SearchSimpliException.code`: the `SS_ERR_*` name in the message.
- Bindings regenerated from `zig/include/search_simpli.h` (`ffigen`);
  native libraries rebuilt.

The consumer app regenerates its `search/contracts` Dart types at its pin
bump to this contract.

## Contract 1.2.0 and earlier

See `PROJECT-STATE.md` and the task files in `docs/tasks/` (S1-T2 onwards).

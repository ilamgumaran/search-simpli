# Luxir: what it is, what our engine is, and what to take from it

**Date:** 2026-10-08 · **Branch:** `research/luxir` (from `main` `dbff430`) · **Status:** research only. No code, no task files, no board edits.

**Question asked by the owner:** Yonik Seeley, who wrote Solr, has released a new search engine, **Luxir** (<https://luxir.org>, <https://github.com/luxir-search/luxir>; C++, Apache 2.0, pre-1.0). Research it, pull out the learnings, and improve our engine.

**How to read this.** Section 1 describes Luxir as it is published, and section 2 describes our engine from its code, under the same headings so the two can be compared. Section 3 is the ranked learnings. Each learning has a measurement bar, written before anything is built. Section 4 is the proposed `S2-T*` task list. Section 5 lists what not to copy. Section 6 has the board candidates. Section 7 lists what could not be established.

**Citations.**
- Our engine: `file:line` against `main` `dbff430` (`zig/src/…` unless another path is given).
- Luxir site: **[site: page]** means `https://luxir.org/docs/latest/<page>/`. `latest` is the 0.1.0 release (2026-09-21). All pages were fetched on 2026-10-08.
- Luxir repository: **[repo: path Lnn]** means `https://raw.githubusercontent.com/luxir-search/luxir/main/<path>`, at commit `5f6e043` (2026-10-06, 46 commits after `v0.1.0`). Line numbers refer to that commit.
- Luxir's docs make many claims without numbers. These are marked **claimed, not measured**.
- Measurements of our engine were taken on an Apple M1 (8 cores, 8 GB, macOS 15.7). The exact commands are in Appendix A.

---

## 0. The answer in brief

Luxir is a scale-up server engine for very large corpora on many-core x86 machines. Most of what makes it fast does not apply to an index of a few thousand chunks on one phone with one user. **Two things it does carefully do apply to us:**

1. **It runs one analysis chain at index time and at query time.** That chain folds Unicode properly (NFKC case folding, accent folding) and applies light English stemming (possessives, KStem).
2. **It never does work for documents that cannot reach the top k.**

Laying our engine next to Luxir's turned up three findings that are more urgent than any Luxir feature. All three were measured for this document.

- **The family app does not use the Unicode analyzer.** The app publishes through `ss_import_json` (`simpli-helper` `packages/vizhi_core/lib/src/search/engine/search_simpli_engine.dart:213`). That path accepts only `ascii-alnum-v1` (`importer.zig:13`, `importer.zig:51`, `contracts/snapshot-interchange.schema.json:10`).
  - **Measured:** the Tamil fixture published through that path has **0 terms** and scores **success@1 0.00** (10/10 misses). The same passages through `searchd index` (analyzer-v2) score 1.00.
  - Accented words are split: `café` is indexed as `caf`, and `crêpes` as `cr` + `pes`.
- **The app's publish path is slow.** It builds the lexical index with the pre-S1-T3 dictionary build (`importer.zig:101` → `postings.build`, linear `findTerm` at `postings.zig:148-153`).
  - **Measured:** **12.19 s** for 1,000 documents and **108.25 s** for 10,000. `searchd index` does the same corpus in 0.12 s and 0.92 s.
  - The app rebuilds the whole index on every import (`search_simpli_engine.dart:131-137`).
- **Query time is spent sorting, not scoring.** Every query sorts the whole corpus three times (`hybrid.zig:143-151`), lexical mode included.
  - **Measured:** p50 is **8.0-11.6 ms** at 10,000 chunks, against 0.36-0.85 ms at 1,000.
  - A sampling profile puts about 94% of query time in `std.sort.pdq` and about 0% in postings scoring.
  - So Luxir's block-max/MaxScore pruning would save nothing here. Plain top-k selection would remove most of the cost.

The learnings ranked highest, each with its bar in one line (full bars are in §3):

| # | Learning | Bar, in one line |
|---|---|---|
| 1 | Use one Unicode analysis chain on **every** publish path (Luxir: query-time analysis matches index time) | Tamil fixture through `ss_import_json`: 0.00 → **1.00** success@1. Full rankings identical to `searchd index` on every judged fixture. |
| 2 | Linear-time dictionary build on the import path | `import-json` of the 10k corpus: 108.25 s → **≤ 2 s**. Byte-identical query JSON on every golden. |
| 3 | Top-k selection over **matched** chunks only, instead of three full sorts (the cheap half of Luxir's "skip what cannot reach the top k") | Byte-identical `ss_query` output on all goldens and 200 random queries. p50 at 10k chunks: 8-12 ms → **≤ 2 ms** (M1). |
| 4 | Fuzzy matching for a query word that is in no chunk, with Luxir's blended statistics so a misspelling never outranks an exact hit | J2 misspelling slice success@1 **+0.25** absolute. **Zero** rank-1 losses on J2's exact-term control slice. |
| 5 | Accent and NFKC folding, Tamil-safe word segmentation, and English plural/possessive stemming that touches only lowercase ASCII words (Luxir's own guard) | J2 morphology/accent slice success@1 **+0.20**. Tamil slice **no loss**. Zero control rank-1 losses. |
| 6 | A warnings channel and opt-in profile in the `ss_query` report | Rankings byte-identical with the fields stripped. Every dropped query word is reported. Profile off by default and costs ≤ 2% p50. |

"J2" is the harder judged fixture that the search-simpli orchestrator has queued ("then a harder judged benchmark", `docs/journey/03-next.md:7`). **Every relevance learning (4, 5, title/path field, phrase/proximity) is gated on J2.** The existing fixtures cannot measure them:
- The app's relevance-smoke fixture already scores 1.0 on every metric (M12-T0 Report criterion 3; re-measured here: success@1 1.00).
- The Tamil fixture scores 1.00 through `searchd index`.
- The 20-query mixed fixture scores 0.60 success@1, but its misses are paraphrase misses written for the semantic channel, not misspellings or inflection (§3.0).

§3.0 lists the slices J2 needs to contain for these bars to be decidable.

---

## 1. Luxir in one page, as published

**What it is.** Luxir is "a native-code search engine with full-text relevance, vector similarity, faceting, analytics, and geo search in one index" [site: (index)]. It is "from Yonik Seeley, original author of Apache Solr" (<https://luxir.org/>).
- It is written in C++26 on a GCC 16 snapshot. It depends on TBB, Boost, gRPC/Protobuf, FAISS, FastPFOR, LZ4, xxHash and uni-algo [repo: docs/dev/build-setup.md L15-27; NOTICE].
- Version 0.1.0 (2026-09-21) is the only release [site: download; repo: CMakeLists.txt L5].
- It is pre-1.0: "expect to reindex when upgrading" [repo: README.md L125-131]. Binaries are Linux x86-64 only.

**What it optimises for.**
- Its design starts "from the economics of cloud compute… one big node is now as economical a unit of capacity as a cluster of small ones" [repo: docs/design/architecture.md L11-30].
- "Scales up before it scales out."
- "Many cores, large memories, fast NVMe, and SIMD are baseline assumptions: work-stealing parallelism throughout, memory-mapped immutable data, vectorized codecs, and allocation discipline on every hot path."
- "Frugal with memory": no garbage collector, arenas and pools [same].
- The author's reasons for native code are no GC pauses, smaller RAM, direct SIMD, predictable latency and no warm-up (<https://yonik.com/blog/introducing-luxir/>).

**Index and segment model.**
- "An index is a set of immutable segments plus a small metadata file naming the current commit point. Writers never modify what readers are using. A search pins a consistent snapshot for its whole lifetime" [repo: docs/design/architecture.md L34-47].
- Segments merge in the background under a log-level policy with merge factor 10 [repo: src/luxir/index/IndexWriter.h L146-283; `--indexing.merge-factor`, src/luxir/LuxirConfig.cpp L167-169].
- A single merge runs in parallel, one task per field, admitted against a RAM budget [repo: architecture.md L66-72].

**Codecs, dictionary, mmap.**
- "Segments are read via mmap, and the on-disk format is the in-memory format: postings, columns, and vector index data are consumed in place, with no deserialization step" [site: design/architecture].
- Postings come in blocks of 128 documents, using FastPFOR frame-of-reference SIMD bit-packing, an all-consecutive marker, or a bitset, with StreamVByte for tails [repo: src/luxir/reader/Postings.h L18-35; src/luxir/codec/Codec.h L14-19].
- The term dictionary is built from front-coded blocks of 32 terms, each term carrying one XXH3 byte to reject misses, with a byte trie routing seeks to blocks [repo: src/luxir/index/PostingsWriter.h ~L1340-1400; src/luxir/index/TrieBuilder.h L19-60].
- Norms take one byte per document, encoded with Lucene's SmallFloat [repo: src/luxir/search/Similarity.h L22-90].

**Scoring and pruning.**
- Scoring is BM25 with k1 = 1.2 and b = 0.75, fixed and not configurable [repo: src/luxir/search/Similarity.h L115; src/luxir/query/TermQuery.h L134-139]. It follows Lucene "to make scores compatible" [Similarity.h L95-96].
- "A top-k request that does not ask for an exact total runs with block-max pruning: postings carry per-block score upper bounds, and a MaxScore-based scorer skips blocks and documents that cannot reach the current top k" [site: design/architecture].
- Per-block "Pareto frontiers" of (norm → max tf) give the bounds [repo: PostingsWriter.h L684-718]. WAND is also implemented for `min_match > 1` [repo: src/luxir/query/BooleanQuery.h L1375-1435].
- The top-k heap breaks ties by (segment, docid), "a deterministic total order, independent of collection/merge order" [repo: src/luxir/search/Collector.h L70-77].

**Text analysis.**
- Tokenizers: `unicode_word` (UAX#29), `whitespace`, `keyword`.
- Filters: `nfkc_cf` (NFKC case folding "to a fixpoint"), `lowercase`, `fold` (accents and diacritics), `english_possessive`, `kstem` [site: guide/schema, "Text analysis"].
- The default `_t` text template is `unicode_word` + `nfkc_cf` + `fold` + `kstem` [repo: docs/guide/schema.md L77-82].
- KStem guard: "Tokens containing anything outside lowercase ASCII letters, or with lengths outside 3-49 letters, pass through unstemmed" [site: guide/schema].
- "Query-time analysis matches index-time analysis" [site: features].
- Not available: Porter or Snowball stemming, stopwords, synonyms, and any language other than English [not found in docs or `src/`].

**Query types.** Queries form a single request tree of named ops: `top_docs`, `field_facet`, `range_facet`, `query_facet`, `expr_op` and `fusion` [site: guide/searching]. The query arms are:
- `match`, `any_of`, `phrase` (with slop; "an adjacent transposition costs 2"), `prefix`, `wildcard`, `regex`, `range`;
- `fuzzy`, `boolean`, `boost`, `constant_score`, `rescore`, `simple_query`, `expr`;
- `knn`, `geo_box`, `geo_distance` [repo: protos/luxir_types.proto L193-216].

Fuzzy matching works like this:
- It uses byte-wise Levenshtein distance 0-2. By default the distance is 0 for words of ≤ 2 bytes, 1 for 3-5 bytes and 2 above that. `prefix_length` is 1 and `max_expansions` is 50 [site: guide/query-reference, "Fuzzy"].
- It rewrites to a disjunction of term queries that share **one blended statistic**: "docFreq/ttf = max across the kept expanded terms… Per-term IDF would invert relevance". Each clause is boosted by `1 - distance/denominator` [repo: src/luxir/query/FuzzyQuery.h L182-225; src/luxir/reader/FuzzySeekEnum.h L28-33].
- The stated purpose is "so a rare misspelling never outranks the exact term" [site: features] (claimed, not measured).

Multi-field `simple_query` "scores add across fields". There is no BM25F and no per-field k1 or b [repo: docs/guide/query-reference.md L416; not found in `src/`].

**Vector search and filtered kNN.**
- By default vector search is an exact scan of the full-precision column. The only approximate index is IVF+PQ through FAISS, "There is no HNSW yet". It is built per segment, only on request at commit, and only above a size and cost floor. Candidates "are always rescored from the full-precision column" [site: guide/vector-search; design/vector-search].
- "The filter is applied during the candidate search, so `k: 20` means twenty filtered neighbors." The search deepens automatically when a filter starves it [site: guide/vector-search].
- "A parallel run returns bit-identical results to a serial run" [site: design/vector-search].

**Fusion.**
- RRF is the only method, with k = 60 [repo: protos/luxir_types.proto L140-182; src/luxir/search/ops/FusionOp.h L26-31].
- Each source has its own query and limit, and a shared filter is computed once.
- Facets under a fusion "see every document in any source's ranked list after filters… the fusion's `limit` and `offset` do not change facet counts" [site: guide/vector-search, "Hybrid search with RRF"].

**Faceting and analytics.**
- Facet types: field facets, range facets (including calendar-aware date ranges), query facets and expression metrics.
- Counts are "exact by default". Multi-select is supported through `selected`. A request is capped at 100,000 buckets [site: guide/faceting].

**Ingest and commits.**
- Ingest is JSON or unbounded NDJSON over HTTP, or a gRPC stream. There is no delete-by-query and no partial update [site: guide/indexing].
- Crash safety: "files are written to a temporary name, synced, and atomically renamed, and a commit point is published only after the files it names are durable" [site: design/architecture].
- On `main` (after 0.1.0), operations.md describes the sequence as: sync data files, sync the directory, write the manifest with an xxh3 footer, sync the manifest, sync the directory, then acknowledge. "Once the new root is durable, obsolete manifests and unreferenced data are removed" [repo: docs/guide/operations.md L188-213].
- There is no WAL: "Updates accepted since that commit can be lost" [repo: operations.md L33-34].
- The default storage backend is in-memory [site: guide/operations].

**Operations.**
- HTTP/JSON and gRPC run as peers. JSON parsing is strict: unknown keys are errors. There is one error shape [site: guide/http-api; guide/grpc].
- **Warnings channel:** "declared degradations (a clamped fuzzy distance, a skipped calendar bucket) carry a code and a message in the response instead of silently changing the query" [site: features]. Codes include `fuzzy_clamped`, `calendar_bucket_skipped` and `field_narrowed`.
- **Profiling:** `profile: true` is opt-in and reports per-segment strategy, `thread_id` and `elapsed_us`, but only string facets are instrumented [site: guide/searching].
- `?explain=request` echoes the canonical request. There is no per-document score explanation [site: guide/http-api].

**Threading.**
- TBB work-stealing runs "across segments (and within segments) and across the independent operations in a request" [site: design/architecture].
- **The default is serial.** `max_parallel: 0` "executes serially on the transport thread", and `-1` is unlimited [site: guide/searching, "Request-level controls"].

**Measured performance.** The only measurements are on the author's blog, not on luxir.org, whose features page says "Benchmark results are not yet published".
- Setup: a pre-release build against Elasticsearch 9.5.4 and OpenSearch 3.8.0 on a 16-core Ryzen. The corpus was 10M Wikipedia chunks force-merged to one segment, with caches off, over 60 query-type cells.
- Throughput: geometric-mean **1.6× Elasticsearch and 2.0× OpenSearch** at 1 connection.
- Memory: peak RSS **3.2 vs 10.2 vs 10.5 GiB**.
- Latency: a medium-frequency term at **0.12 vs 0.25 vs 0.27 ms** median top-10.
- The page's own limits: "One corpus, one segment, one machine… says nothing about multi-segment indexes, cold starts, relevance, or indexing" (<https://yonik.com/bench/full-text/>).

**Not shipped** [repo: README.md L123-132; docs/guide/operations.md L362-376; each guide's "Limits"]:
- replication (partly on `main` since 2026-09-23, after the release), distributed query, TLS, authentication;
- HNSW, highlighting/snippets, spellcheck/suggest, synonyms, non-English stemming;
- page-after cursors, delete-by-query, partial updates;
- `max_parallel > 1`, and profiling outside string facets.

---

## 2. Our engine in one page, from the code

**What it is.**
- A Zig 0.16 library with a C ABI: `ss_open`, `ss_close`, `ss_status`, `ss_query`, `ss_evidence`, `ss_import_json`, `ss_index_folder`, `ss_free`, `ss_version`, `ss_last_error` (`zig/include/search_simpli.h:89-300`).
- A CLI on top of it (`cli.zig`).
- The release libraries are about 382 KB (`PROJECT-STATE.md:25`).

**Index and segment model.**
- One generation is one immutable document section (`HYBSEG01` v3) plus one lexical section (`HYBLEX01`), bound by a `HYBMAN01` manifest (`engine.zig:32-57`, `manifest.zig`).
- There is exactly **one segment per generation**. Every publish rebuilds the whole lexical index: "No delta segments, write-ahead log, background compaction, or query-time segment fan-out" (`docs/incremental-indexing.md:42-49`, `:143-145`).
- There is no merge policy because nothing merges.

**Publish paths.** There are two, and they differ.

| Path | Who uses it | Analyzer | Dictionary build |
|---|---|---|---|
| `ss_index_folder` / `searchd index` | CLI, future folder indexing | `analyzer-v2` by default (`indexer.zig:134-139`) | hash maps, linear (`lexical_build.zig:51-93`) |
| `ss_import_json` / `searchd import-json` | **the family app today** (`search_simpli_engine.dart:213`) | `ascii-alnum-v1` only (`importer.zig:13`, `:51`; schema `contracts/snapshot-interchange.schema.json:10`) | `postings.build`: linear `findTerm` per token (`postings.zig:63`, `:148-153`), plus `isFirstOccurrence`/`termFrequency` re-scanning the chunk from the start for each token (`postings.zig:62`, `:96`; `analysis.zig:39-55`) |

**Postings and dictionary encoding** (`lexical_segment.zig:78-123`):
- a 64-byte header;
- `u32` document lengths;
- each dictionary entry as `u32 len, u32 df, u64 postings_start, u64 postings_length` followed by the raw term bytes, in first-seen order and unsorted;
- each posting as `u32 doc, u32 tf`, uncompressed;
- an FNV-1a checksum over all of it (`:306-320`).

There are no positions, no skip data, no compression and no per-block maxima.

**Read in place or deserialised?** Deserialised.
- `ss_open` reads every section file into a malloc'd buffer (`abi.zig:129-138`, `publication.zig:39-57`).
- It then decodes into separate arrays (`abi.zig:140-160`). Postings are **copied** element by element (`lexical_segment.zig:215-222`).
- On every open it rebuilds a hash set of all terms to check for duplicates (`lexical_segment.zig:192-202`).
- Terms and chunk text are borrowed slices of the read buffer (`lexical_segment.zig:199`, `segment.zig:164-166`).
- There is no mmap anywhere in `zig/src`.

**Query execution, end to end** (`ss_query` → `abi.zig:262-325`):
1. Options JSON is parsed strictly: an unknown key fails with `UnknownField`, measured below (`abi.zig:273-278`). `top_k` must be 1-100 and `candidate_k` 1-10,000, default 100 (`abi.zig:269`, `:284-285`).
2. **Per query, three arrays the size of the whole corpus are allocated**: scores, results and evidence (`abi.zig:296-302`).
3. The query is tokenised by the snapshot's analyzer (`engine.zig:82-101`).
4. Term lookup is a **linear scan of the whole dictionary** per query word: `findExact` (`lexical_build.zig:156-161`) or the case-insensitive `findTerm` (`postings.zig:148-153`). A query word missing from the dictionary is dropped silently (`lexical_build.zig:139`, `orelse continue`).
5. Postings are walked and BM25 is added into the dense score array (`lexical_build.zig:141-151`). Only matching chunks get a nonzero score.
6. `finishSearch` (`hybrid.zig:122-156`):
   - zeroes scores outside `path_prefix` or the principal's labels (`:128-135`);
   - **sorts every chunk in the corpus by lexical score**, then again by semantic score, then again by fused score (`:143-151`), using `std.sort.pdq` over ~100-byte `Result` structs (`:217-229`, `:245-256`). This happens even in lexical mode, where every semantic score is 0;
   - drops ranks beyond `candidate_k` (`:146-147`);
   - sets the fused score to RRF with k = 60 (`:148-149`, `scoring.zig:43-47`, `hybrid.zig:19`);
   - returns the first `top_k` chunks with a positive fused score (`:153-155`).
   - Ties break on `document_index`, a total order (`:231-236`, `:253-256`).
7. **No pruning: every matching chunk is scored, and every chunk, matching or not, is sorted three times.**

**BM25.**
- k1 = 1.2 and b = 0.75 (`scoring.zig:3-6`). These are the same defaults as Luxir's, and like Luxir they are not exposed through `ss_query`.
- idf = `ln(1 + (N - df + 0.5)/(df + 0.5))` (`scoring.zig:21`).
- Length normalisation uses the **exact** token count of the chunk against the corpus average (`scoring.zig:22`, `lexical_build.zig:55-56`, `:104-107`). It is not one-byte-quantised like Lucene or Luxir.

**Analyzer.**
- `analyzer-v2` (`analyzer_v2.zig:75-103`) does three things: NFC normalisation; splitting on maximal runs of Unicode letters and digits (`L*`, `N*`); and **simple** per-codepoint case folding. So `ß`, `ﬁ` and `İ` do not fold (`analyzer_v2.zig:22-29`).
- It does not do: NFKC, accent folding, stemming, possessive removal, stopwords or synonyms. Digits are kept as tokens, so `v2` is one token (`analyzer_v2.zig:110-116`).
- **Tamil words are split at every vowel sign and virama**, because combining marks (`Mn`/`Mc`) are not letters. `தமிழ் மொழி` becomes `தம`, `ழ`, `ம`, `ழ` (`analyzer_v2.zig:119-131`). This is kept on purpose for parity with the Python reference (`analyzer_v2.zig:10-20`).
- `ascii-alnum-v1`, which the app uses, keeps only ASCII letters and digits (`analysis.zig:65-67`). Tamil yields no tokens at all.

**Positions, phrase, proximity, fuzzy, prefix.** None. A posting is `(doc, tf)` (`postings.zig:7-10`).

**Field weighting.**
- Only chunk text is tokenised (`indexer.zig:267-270`, `:617`; `importer.zig:101` over `documents[].text`).
- The file path is stored for citation and filtering only (`indexer.zig:245-252`). It is never searched or boosted. A title appears only if it happens to be inside the chunk text.

**Filters.**
- `path_prefix`: a byte prefix on the path (`hybrid.zig:158-161`).
- `principal_labels`: all-required labels (`hybrid.zig:163-177`).
- Both are applied before ranks are assigned in both channels (`hybrid.zig:128-135`), so a filtered-out chunk takes no rank in either channel. Nothing else is filterable.

**Fusion.**
- RRF, k = 60 (`hybrid.zig:19`), over independent per-channel ranks cut at the shared `candidate_k` (`hybrid.zig:146-147`).
- There are no per-channel weights, and `rrf_k` is not exposed through the ABI (`abi.zig:217-222`).
- Vector scoring is an exact cosine over every chunk (`hybrid.zig:136-140`, `scoring.zig:27-41`).
- The app pins lexical mode (`search_simpli_engine.dart:234-239`).

**Incremental indexing and publication.**
- `--update` hashes every file (SHA-256). It re-chunks only changed files and reconstructs unchanged chunks' tokens from the previous postings (`indexer.zig:403-424`, `:458-…`). It then rebuilds the whole index.
- Each section is written to a random temp name with `O_CREAT|O_EXCL`, **fsynced**, then renamed. Immutable sections use `renamePreserve`; `MANIFEST` uses a replacing rename (`publication.zig:90-126`). `MANIFEST` is written last (`publication.zig:20-35`).
- The **directory is never fsynced** after a rename (no other `sync` in `zig/src`).
- Old generations are never removed: "No query-reader leases or generation garbage collection" (`docs/incremental-indexing.md:151-153`). The app's own comment confirms that a snapshot directory "keeps every generation `ss_import_json` has ever written" (`search_simpli_engine.dart:29-32`). The app republishes the whole set on every import (`search_simpli_engine.dart:131-137`, `:203-221`).

**Report shape.**
- `ss_query` returns `tool`, `query`, `index{version, generation, analyzer_id, embedding_model_id}`, `retrieval{mode, vector_dimensions, authorization}`, and `results[]` of `{chunk_id, citation{path, start_line, end_line}, content, score, ranking{lexical{rank, score}, vector{rank, score}}}`, followed by `answer_policy` (`rpc.zig:260-343`).
- There is no warnings field, no timing, and no account of dropped query words. A query with no match returns `"results":[]` and nothing else (measured below).
- `ss_index_folder` returns the count/paths report (`search_simpli.h:269-286`).

**Threading.**
- Each call is single-threaded. The library's I/O is `std.Io.Threaded.global_single_threaded` (`abi.zig:63`).
- One handle may be queried from several threads at once, because the snapshot is immutable and scratch is per call (`search_simpli.h:39-48`).

**What the ABI exposes.** The ten functions above, plus four `ss_query` options: `retrieval_mode`, `candidate_k`, `path_prefix` and `principal_labels` (`search_simpli.h:143-155`). Nothing else.

### 2.1 Measured here (both measurements requested, plus three that fell out of them)

The corpus came from `scripts/gen_timing_corpus.py` with its default 24,000-word guaranteed vocabulary:
- 1,000 files, **916,353 bytes**;
- 10,000 files, **7,269,199 bytes**.

The `du` sizes are 3.9 MB and 39 MB. The README's "~3.9 MB" is the `du` figure.

The `searchd` binary was built ReleaseSafe from `dbff430`. Queries ran in-process through the shipped macOS `libsearch_simpli.dylib` (ReleaseSmall, the bytes the app ships), by opening one handle and timing 200 `ss_query` calls per query in lexical mode with top_k 5. Commands are in Appendix A.

**M1. `searchd index` (analyzer-v2, the folder path), three fresh runs each.**

| Corpus | Chunks | Terms | Postings | Wall (3 runs) | Peak memory footprint | Snapshot on disk |
|---|---:|---:|---:|---|---:|---:|
| 1k files | 1,004 | 24,057 | 117,668 | 0.13 / 0.12 / 0.12 s | 37.3 MB | 2.7 MB |
| 10k files | 10,003 | 24,057 | 925,927 | 0.92 / 0.92 / 0.91 s | 212.7 MB | 17 MB (7.9 MB documents, 8.2 MB lexical, 1.2 MB `INDEX-STATE.json`) |

**M2. Query latency in-process (`ss_query`, lexical, top_k 5), p50 / p95 over 200 calls.**

| Query | 1k chunks | 10k chunks |
|---|---|---|
| `benico` (one rare word) | 0.38 / 0.58 ms | 11.56 / 11.79 ms |
| `hybrid retrieval` | 0.69 / 0.71 ms | 8.00 / 8.25 ms |
| `how does the hybrid retrieval work for a search` | 0.85 / 0.87 ms | 9.33 / 9.55 ms |
| `the and of to in` (very common words) | 0.73 / 0.79 ms | 9.27 / 9.57 ms |
| `ss_open` once | 18.2 ms | 76.5 ms |
| Process peak footprint (Python + library + handle) | 16.1 MB | 37.8 MB |

Ten times the chunks costs 13-30× the time. **The rare one-word query is the slowest at 10k.** Scoring cannot explain that, because the work per query word is tiny next to the corpus size.

**M3. Where query time goes.**

`sample` was run for 3 s against the same loop (`benico`, 10k), using a ReleaseSafe build of the library so that symbols are present. Of 2,125 samples inside `queryImpl`:
- `hybrid.assignRanks` → `pdq` (`hybrid.zig:221`): **1,412**;
- `sortByFusedScore` → `pdq` (`hybrid.zig:246`): **577**;
- the per-query allocations (`abi.zig:299-301`): 136;
- **postings scoring did not appear** among the frames above 20 samples.

So about 94% of query time is sorting chunks that mostly have a score of zero.

**M4. The app's publish path (`searchd import-json`, `ascii-alnum-v1`, one interchange document per file).**

| Corpus | Wall | Peak footprint | vs. `searchd index` on the same files |
|---|---:|---:|---|
| 1k docs | **12.19 s** | 15.3 MB | 0.12 s (≈100×) |
| 10k docs | **108.25 s** | 102.8 MB | 0.92 s (≈118×) |

Query latency on that index is the same as M2 (10k: `benico` p50 11.73 ms), because the same sort dominates.

**M5. What the app's analyzer finds.** Each probe is one-chunk documents published through `import-json`; the results were confirmed with `searchd query --json`.

| Probe | `ascii-alnum-v1` (app) | `analyzer-v2` (`searchd index`) |
|---|---|---|
| `தமிழ்` against a Tamil chunk | no result (index has **0 terms** for Tamil) | found |
| `ம` (a bare consonant fragment) | no result | **found**: v2 indexes fragments, so a one-letter query matches |
| `café` against "café" | found, **as `caf`** | found |
| `cafe` against "café" | found, by the accident `caf` | **not found** (no accent folding) |
| `crepes` against "crêpes" | not found | not found |
| `dinosaurus` (misspelt) against "dinosaurs… dinosaur" | not found | not found |
| `dino` (prefix) | not found | not found |
| Tamil fixture, 10 judged queries | **success@1 0.00**, 0 terms indexed | success@1 1.00 |

Judged baselines through `searchd index` (analyzer-v2, lexical), from this run:
- `fixtures/mixed-judgments.json`: 20 queries, success@1 **0.60**, MRR@10 0.775, recall@10 1.00. There are 8 misses, at ranks 2-3.
- `fixtures/tamil/judgments.json`: 1.00 / 1.00 / 1.00.
- `fixtures/relevance-smoke/judgments.json`: 1.00 / 1.00 / 1.00.

---

## 3. Learnings, ranked

Each learning has five parts: the Luxir idea; what it would mean here; whether it is worth it at our size; the smallest version worth building; and a **bar, pre-registered here**. The bars follow the style of `simpli-helper` `docs/decisions/ADR-010-citation-rate.md:372-385`: lettered conditions, numbers fixed before the build, and an instruction for what happens if they fail.

Two decisions frame the ranking:
- **What the reader sees is rank 1.** The app shows "read for this answer" and the **top-ranked source** (ADR-010 `:495-500`), and the small model reads the top evidence. So the relevance metric is **success@1**, with MRR@10 as the secondary metric. recall@10 only shows the problem is reachable.
- **Size.** Our corpus is thousands to tens of thousands of chunks, on one phone, with one user and one query at a time. Luxir's machinery for very large corpora is ranked against measured costs, not against what Luxir needs.

### 3.0 The judged fixture these bars need (J2)

**Today's fixtures cannot decide the relevance learnings.**
- relevance-smoke and Tamil are already at 1.00.
- The mixed fixture is at 0.60. Its eight misses are paraphrase misses written to show the vector channel ("merge keyword and meaning-based result lists" → `search/hybrid.md`). None of them is a misspelling, a plural, an accent or a title-intent query.

The mixed fixture is still useful as a **no-regression check**: none of learnings 4, 5, 7 or 8 may lower its 0.60 / 0.775.

**The gate is J2**, the "harder judged benchmark" queued after the leak measurement (`docs/journey/03-next.md:7`). For the bars below to be decidable, J2 needs these slices, each with invented content and kid-and-parent phrasing, judged before any of the builds below:

| Slice | Minimum queries | Example (invented) |
|---|---:|---|
| **control**: exact words, already working | 20 | "volcano project due date" |
| **misspelling** | 15 | "dinosoar bones", "multiplicaton tables" |
| **morphology**: plural, possessive, -ing/-ed | 12 | "the dinosaur's teeth" vs "dinosaurs teeth", "ponies" vs "pony" |
| **accent/compatibility**: é, ï, full-width, ligatures | 6 | "cafe menu", "naive" for "naïve" |
| **Tamil**: inflected forms and suffixed nouns | 10 | a plural or case-suffixed form of a word that appears in its base form |
| **title intent**: the answer is in the file named for the query | 10 | "science homework" → `school/science-homework.md` |
| **phrase**: word order or adjacency decides | 8 | "hot dog" vs a chunk where "hot" and "dog" are far apart |

Without a slice, the matching learning stays **unmeasurable and is not built**.

### 1. One analysis chain on every publish path

- **Luxir.** "Query-time analysis matches index-time analysis" [site: features]. Analysis is one declared chain per field, and the recommended fold is `nfkc_cf` over UAX#29 words [site: guide/schema].
- **Here.** There are two chains, and the app is on the wrong one.
  - The app publishes through `ss_import_json`, whose contract pins `ascii-alnum-v1` (`contracts/snapshot-interchange.schema.json:10`, `importer.zig:51`).
  - Measured (M5): the family's Tamil text is **unsearchable** on the phone (0 terms), and accented words are split into fragments.
  - analyzer-v2, which S1-T1 built and proved on Tamil 10/10, never reaches the app.
- **Worth it?** Yes, and before anything else in this document. It is a correctness gap in the shipped product, not an optimisation.
- **Smallest version.**
  - `ss_import_json` accepts `"analyzer_id": "analyzer-v2"`, and builds and records it the same way `indexer.indexFolder` does (`indexer.zig:267-298`).
  - `ascii-alnum-v1` stays accepted, so old snapshots and the Python export keep working.
  - The schema's `const` becomes an `enum`, and `CONTRACTS_VERSION` gets a minor bump (1.0.0 → 1.1.0), because a new accepted value is additive.
  - The Dart `SnapshotInterchangeV1` gains the field. Switching the app over is a separate app task.
- **Bar.**
  - (a) Tamil fixture published through `import-json` with `analyzer-v2`: success@1 0.00 → **1.00**.
  - (b) For every judged fixture in `fixtures/` and the chunk/BM25 goldens, the full ranked list (path, lines, score to 1e-6) through `import-json` + v2 is **identical** to `searchd index` on the same chunks.
  - (c) `ascii-alnum-v1` imports are **byte-identical** to today's on the existing goldens (`zig build test-abi` 12/12 unchanged).
  - (d) **Not worth it would look like** any one of (a)-(c) failing. The numbers then come back to the orchestrator before the app is switched.
- **J2?** No. It is decidable on existing fixtures.

### 2. Linear-time dictionary build on the import path

- **Luxir.** Allocation discipline and pipelined indexing [repo: docs/design/architecture.md L11-30, L52-72]. More to the point, S1-T3 already applied this lesson to the folder path and not to the import path.
- **Here.**
  - `postings.build` scans the growing term list for each token (`postings.zig:63`, `:148-153`), and re-scans each chunk from its start for each token (`postings.zig:62`, `:96`).
  - Measured (M4): 12.19 s for 1k documents and 108.25 s for 10k, on an M1. A phone is slower, and the app rebuilds on every import.
- **Worth it?** Yes. It is the same fix S1-T3 made in `lexical_build.zig:42-93`.
- **Smallest version.** Build the ASCII index through the hash-map path, keyed on the ASCII-lowercased token. It must keep exactly the same df, tf and document lengths, and the same case-insensitive matching (`postings.zig:148-153`). If learning 1 lands first and the app moves to v2, this matters only for remaining v1 callers. It is still a small fix.
- **Bar.**
  - (a) `searchd import-json` of the 10k corpus: 108.25 s → **≤ 2 s** wall on the same M1 (ReleaseSafe, `/usr/bin/time -l`).
  - (b) Query JSON **byte-identical** to the pre-change binary for the 36 BM25-conformance queries, the ABI goldens, and 50 random queries over the 1k corpus.
  - (c) Lexical section bytes may differ only in term order. If they differ in anything else, the change fails.
  - (d) Not worth it: (b) cannot be met without changing the persisted format.
- **J2?** No.

### 3. Top-k selection over matched chunks only

- **Luxir.** "A MaxScore-based scorer skips blocks and documents that cannot reach the current top k" [site: design/architecture]. The heap breaks ties on (segment, docid) as a total order [repo: src/luxir/search/Collector.h L70-77].
- **Here.**
  - We already avoid scoring non-matching chunks (postings).
  - We then **sort the whole corpus three times**, including thousands of chunks with score 0, and sort the semantic channel in lexical mode (`hybrid.zig:143-151`).
  - Measured (M2/M3): 8-12 ms p50 at 10k chunks on an M1, about 94% of it in `pdq`. Scoring is not visible in the profile, so **block-max/MaxScore would save nothing measurable here**.
- **Worth it?** Yes. It is cheap, the gain is large, and the semantics do not change. Every query (on a phone, on battery) does this work.
- **Smallest version.**
  - Collect the indices of chunks with a nonzero lexical score.
  - Assign lexical ranks by sorting **only those**, or by a bounded selection when `candidate_k` is smaller than the matched set.
  - Skip the semantic pass entirely in lexical mode, or when the snapshot has zero dimensions.
  - Fuse over the union of the two candidate sets, with the same `document_index` tiebreak (`hybrid.zig:231-236`).
  - Per-query scratch shrinks from three corpus-sized arrays (`abi.zig:296-302`) to sizes proportional to matched chunks plus `candidate_k`.
- **Bar.**
  - (a) `ss_query` output is **byte-identical** to the current library for:
    - every judged fixture query;
    - the ABI goldens (`zig build test-abi`);
    - 200 random 1-6-word queries from the 10k corpus vocabulary, in all three modes where vectors exist (the hybrid case uses the existing vector test fixtures).
  - (b) Lexical p50 at 10k chunks **≤ 2 ms** for each of the four M2 queries (M1, shipped ReleaseSmall build, same harness).
  - (c) No query slower than today at 1k chunks.
  - (d) Not worth it: (a) fails anywhere, which means the semantics changed. A smaller gain than (b) is reported, not shipped silently.
- **J2?** No. **Block-max/MaxScore is explicitly not proposed.** It would need impacts in the postings format, and the profile shows nothing for it to save.

### 4. Fuzzy matching for misspelt words, with blended statistics

- **Luxir.**
  - Levenshtein distance ≤ 2, scaled to word length: 0 for ≤ 2 bytes, 1 for 3-5, 2 above.
  - `prefix_length` 1 and `max_expansions` 50.
  - Expanded terms share **one blended df (the max)**, so "a rare misspelling never outranks the exact term", and each expansion is damped by `1 - distance/denominator` [site: guide/query-reference "Fuzzy"; repo: src/luxir/query/FuzzyQuery.h L182-225, src/luxir/reader/FuzzySeekEnum.h L28-33].
  - Luxir only applies this when the user writes `~` or `fuzzy`.
- **Here.**
  - Children misspell, and a misspelt word today is **dropped silently** (`lexical_build.zig:139`).
  - "dinosaurus" finds nothing (M5).
  - An app user will not type `~`, so the trigger has to be automatic.
- **Worth it?** Probably the largest relevance gain available for kids' queries. It is cheap at our size: a bounded-distance check over a 24k-term dictionary is a linear pass, and the lookup is already linear (`lexical_build.zig:156-161`).
- **Smallest version.**
  - Expand only a query word that **occurs in no chunk** (df = 0). A word that exists is never expanded, so control queries cannot change.
  - Use Luxir's defaults: edit limits by length, prefix 1, at most 50 expansions. For multi-byte scripts, count edits on code points, not bytes. Luxir's byte-wise distance would treat a Tamil letter as three edits.
  - Score each expansion with the blended max df and a damping factor below 1, so an exact match on another word always weighs more.
  - Report each expansion in the warnings channel (learning 6), so the app can say "showing results for *dinosaur*".
- **Bar.**
  - (a) J2 misspelling slice: success@1 improves by **≥ 0.25 absolute**.
  - (b) J2 control slice: **zero** queries lose rank 1. This is guaranteed by construction, and the bar still checks it.
  - (c) Mixed fixture: success@1 not below 0.60 and MRR not below 0.775.
  - (d) Tamil slice: no rank-1 loss.
  - (e) p50 at 10k chunks rises by ≤ 1 ms for a query with one misspelt word (measured after learning 3).
  - (f) **Not worth it:** a gain below +0.10 on (a), or any control loss. Then fuzzy stays off and the dropped-word warning alone ships.
- **J2?** Yes: the misspelling and control slices.

### 5. Folding and light stemming: NFKC + accents, Tamil-safe words, plurals/possessives

- **Luxir.**
  - `nfkc_cf` (NFKC case folding to a fixpoint), `fold` (accents) and `english_possessive`.
  - `kstem`, which leaves alone any token "containing anything outside lowercase ASCII letters, or with lengths outside 3-49 letters".
  - UAX#29 word segmentation, which keeps combining marks inside a word [site: guide/schema; repo: src/luxir/analysis/Analyzer.cpp L30-31, L61-65].
- **Here.** Three separate gaps.
  1. NFC with simple folding misses compatibility forms and full folds (`analyzer_v2.zig:22-29`). With no accent folding, `cafe` misses "café" (M5).
  2. Tamil words are split at every vowel sign (`analyzer_v2.zig:119-131`), so a query matches a bag of consonant fragments. Even a one-letter query matches (M5). Recall is high and precision is poor. The fixture cannot show this, because its ten passages are about ten different subjects.
  3. Plurals and possessives do not meet: "dinosaurs" vs "dinosaur's" vs "dinosaur".
- **What this would do to Tamil, stated plainly.**
  - An accent-folding step that strips **all** combining marks (`Mn`) would delete Tamil vowel signs and the virama, merging different words. It must be limited to Latin, Greek and Cyrillic diacritics, or to marks on base letters from those scripts.
  - Luxir's docs do not say how `fold` treats Indic marks (§7).
  - KStem's ASCII guard means stemming never touches Tamil. Our version must keep that guard.
  - Keeping marks inside words (UAX#29-like) makes Tamil tokens whole words. That fixes the fragment matching, but it also means an inflected Tamil word no longer shares fragments with its base form. A recall loss on inflected Tamil is possible, and is what the Tamil slice is for.
- **Worth it?** Accent/NFKC: yes, and cheap. Tamil-safe segmentation: yes, gated on the Tamil slice. Stemming: only a minimal English plural/possessive stemmer. Full KStem carries a Krovetz dictionary of tens of thousands of entries, against a 382 KB library and an app under a 60 MiB ceiling (ADR 0002). The size cost must be measured before KStem itself is proposed.
- **Smallest version.**
  - A new `analyzer-v3`, recorded in the manifest. v2 stays, with Python parity, for existing snapshots.
  - NFKC + full case fold.
  - Latin-script diacritic folding.
  - Combining marks kept inside a word.
  - Possessive removal (`'s`, `’s`).
  - An "S-stemmer" (`ies→y`, `es`, `s`, with Lucene-style exceptions), applied only to lowercase ASCII tokens of 3-49 letters, as Luxir's guard does.
  - The same chain at query time, as today (`engine.zig:91-101`).
- **Bar.**
  - (a) J2 morphology + accent slices combined: success@1 improves by **≥ 0.20 absolute**.
  - (b) J2 Tamil slice: **no** rank-1 loss against v2, and the existing Tamil fixture stays 10/10.
  - (c) J2 control slice: **zero** rank-1 losses.
  - (d) Mixed fixture success@1 ≥ 0.60.
  - (e) Indexing the 10k corpus ≤ 1.5× the v2 time (M1).
  - (f) Library growth ≤ 64 KB.
  - (g) **Not worth it:** (a) below +0.10, or any loss on (b) or (c). Ship only the parts that pass, each measured alone. Folding and stemming are measured separately, so one cannot hide the other.
- **J2?** Yes: the morphology, accent, Tamil and control slices.

### 6. Warnings channel and opt-in profile in the report

- **Luxir.** "Declared degradations… carry a code and a message in the response instead of silently changing the query" [site: features]. `profile: true` is opt-in and reports per-step timings [site: guide/searching]. Strict request parsing [site: guide/http-api]. We already have strict parsing: an unknown option key fails with `UnknownField`, measured.
- **Here.** Today `ss_query` cannot say why a result list is empty or poor:
  - a dropped word (`lexical_build.zig:139`);
  - a query that is only punctuation;
  - a `candidate_k` that cut ranks;
  - a vector ignored in lexical mode (`abi.zig:287-293`).

  The app wants to tell a child "I couldn't find *dinosaurus*". A tester wants per-phase timings without attaching `sample`, which is how M3 had to be done.
- **Worth it?** Yes. It is small, additive, and makes every later learning measurable on a device.
- **Smallest version.**
  - A `warnings` array of `{code, message, term?}` with codes `query_term_unmatched`, `query_empty_after_analysis`, `vector_ignored`, and later `fuzzy_expanded` and `candidate_depth_cut`.
  - `"profile": true` in `options_json` adds `profile{tokenize_us, score_us, rank_us, serialize_us, matched_chunks}`.
  - Both are additive JSON (`CONTRACTS_VERSION` minor bump), mirrored in the Dart types, and documented in the header.
- **Bar.**
  - (a) With `warnings` and `profile` removed, the output is byte-identical on every golden.
  - (b) Every query word that matches no chunk appears in `warnings` (checked over J2 and the 200 random queries plus 50 with planted unknown words).
  - (c) With profile off, p50 changes by ≤ 2%. With profile on, by ≤ 10%.
  - (d) Not worth it: the app finds no use for the field in its next task. The field is then kept only for testers.
- **J2?** No.

### 7. A title/path field (a second, small field), not BM25F

- **Luxir.** No BM25F: multi-field `simple_query` "scores add across fields". Boosts multiply [repo: docs/guide/query-reference.md L416; site: guide/query-language "Per-clause scores"].
- **Here.** The path is never searched (`indexer.zig:245-252`, `:267-270`). A child who asks for "my science homework" names the file, not its contents.
- **Worth it?** Likely, for this app. Kids name things by subject and file name, and the app's files have human titles. Not measurable today.
- **Smallest version.**
  - Tokenise the path's folder names and file stem with the same analyzer into a second, tiny lexical index (one entry per file, attached to each of its chunks).
  - Score it with BM25 and add it to the text score with weight `w`, where `w` is fixed **before** J2 is run (proposed: 0.5).
  - No format change to `HYBLEX01`: a second lexical section, versioned in the manifest.
- **Bar.**
  - (a) J2 title-intent slice: success@1 **+0.30**.
  - (b) Control: zero rank-1 losses.
  - (c) Mixed fixture ≥ 0.60.
  - (d) Not worth it: below +0.15 on (a), or any control loss. Re-tuning `w` after seeing J2 is not allowed. A new `w` needs a new pre-registered bar.
- **J2?** Yes.

### 8. Positions, phrase and proximity

- **Luxir.** Positions in postings; `phrase` with slop, where "an adjacent transposition costs 2". Measured phrase latency only on Wikipedia at 10M documents [site: guide/query-language; yonik.com/bench/full-text].
- **Here.** We have no positions (`postings.zig:7-10`). Two-word ideas ("hot dog", "solar system", "times tables") rank no better when adjacent.
- **Worth it?** Unknown. It is the most expensive item here: a format change (`HYBLEX02`), roughly doubling postings bytes, and changes to `reconstructTokensFromPostings` (`indexer.zig:403-424`). Rank it last, and only behind a J2 phrase slice that shows a loss.
- **Smallest version.** A proximity bonus, not a phrase operator: for multi-word queries, a small additive score when two query words occur within a window of 3 tokens in the chunk. Positions are stored as delta-varints after each posting.
- **Bar.**
  - (a) J2 phrase slice: success@1 **+0.25**.
  - (b) Control: zero losses.
  - (c) Lexical section size ≤ 2.2× today on the 10k corpus.
  - (d) Index time ≤ 1.5×.
  - (e) Not worth it: (a) below +0.10.
- **J2?** Yes.

### 9. Read in place (mmap-like) instead of deserialising

- **Luxir.** "The on-disk format is the in-memory format… consumed in place, with no deserialization step" [site: design/architecture; repo: src/luxir/store/FSDirectory.h L21-45; `MAX_ALIGN = 8`, src/luxir/codec/Codec.h L29-36].
- **Here.**
  - We read whole files, copy postings element by element, and rebuild a term hash set on every open (`abi.zig:129-160`, `lexical_segment.zig:192-222`).
  - `ss_open` takes 76.5 ms at 10k chunks on an M1 (M2), and the app re-opens after every import (`search_simpli_engine.dart:217`).
  - Memory holds the file bytes **and** a decoded copy of the postings.
- **Worth it?** Not yet proven. 76 ms is not felt next to the import that precedes it. Memory is the better argument, and it is unmeasured on a phone. F-02 ("open/startup time, resident memory") is the gate.
- **Smallest version.** Keep `readFile` (no mmap, so no Android file-mapping questions). Align the postings and length sections to 4 bytes in a new format minor version, borrow them as slices instead of copying, and move the duplicate-term check to publish time.
- **Bar.**
  - (a) `ss_open` at 10k chunks: ≤ 25 ms on an M1.
  - (b) Resident memory after open falls by ≥ the postings bytes (7.4 MB at 10k).
  - (c) All goldens identical.
  - (d) Not worth it: F-02's phone numbers show open < 150 ms and resident memory < 50 MB at the app's real size. The work then waits.
- **J2?** No. **F-02 (phone measurement)?** Yes.

### 10. Crash safety: sync the directory; prune old generations

- **Luxir.** On `main`, the publish sequence syncs data files, then the directory, then writes the manifest with a checksum footer, syncs it, syncs the directory again, and only then acknowledges. "Once the new root is durable, obsolete manifests and unreferenced data are removed." Startup sweeps unreferenced files [repo: docs/guide/operations.md L188-213; src/luxir/store/FSDirectory.h L459-485].
- **Here.**
  - We fsync each file but **never the directory** (`publication.zig:113-121`). After a power loss, ext4 or f2fs may persist the `MANIFEST` rename without the section renames that precede it. `ss_open` then fails closed. That is not corruption, but it leaves no openable index until the next publish.
  - We also **never delete superseded generations** (`docs/incremental-indexing.md:151-153`). The app republishes the whole index on every import (`search_simpli_engine.dart:131-137`), so its storage grows by one full snapshot per import. At the 10k size that is 16 MB per generation (M1).
- **Worth it?** Yes, both. They are small and serve a phone directly. The **merge policy is not**: one segment rewritten whole costs 0.9 s at 10k (M1) and needs no merging.
- **Smallest version.**
  - (i) `fsync` the directory after the section renames and again after the `MANIFEST` rename.
  - (ii) An opt-in `"keep_generations": N` on `ss_index_folder`/`ss_import_json`, default unchanged. After a successful publish it deletes generation files older than the newest N, never the current one. In-process, the app knows when no handle uses the old generation.
- **Bar.**
  - (a) A test with a recording directory shim (or `dtruss` on macOS) shows the directory sync after each rename, in order.
  - (b) Publishing 20 generations of the 1k corpus with `keep_generations: 2` leaves exactly 2 generations' files plus control files, and `lifecycle.scan` reports no orphans.
  - (c) Index time changes ≤ 5%.
  - (d) The `SIGKILL` recovery run from S1-T3 is repeated and still recovers.
  - (e) Not worth it: none of this is a relevance claim, so the only way it fails is (a)-(d).
- **J2?** No.

### 11. When vectors arrive: filters inside kNN, exact scan, fusion

- **Luxir.**
  - "Until you build an approximate index, every search scans the full-precision vector column… results are exact."
  - IVF+PQ is built only above a size and cost floor.
  - Filters apply inside candidate search.
  - RRF k = 60 with per-source limits and a shared filter computed once.
  - Facets see the fused union [site: guide/vector-search; design/vector-search].
- **Here.**
  - We already filter before ranks in both channels (`hybrid.zig:128-141`). That is Luxir's "filter inside the search" in its exact-scan form.
  - We already fuse with RRF k = 60, with a total-order tiebreak.
  - We already use exact cosine.
  - What we lack: per-channel depth (one shared `candidate_k`, `hybrid.zig:146-147`), and `rrf_k` and channel weights in the ABI (`abi.zig:217-222`). F-01 asks for weights. Luxir ships none ("RRF is the only method"), which is weak evidence that unweighted RRF is a sane default.
- **Worth it?** Not now. Hybrid waits on M12-T1 (an embedding channel and the J2 comparison, `simpli-helper` `docs/tasks/M12-T1.md:85-104`). When it arrives:
  - **Keep exact scan.** At our size Luxir would not build ANN either; it is size-gated.
  - Make `candidate_k` per channel.
  - **Do not build facets.**
- **Smallest version.** None now. Recorded as a design rule for M12-T1: exact scan, filter before rank, per-channel depth, `rrf_k` exposed, no ANN until F-02 shows exact scan over 384-d vectors at the app's size above the latency budget.
- **Bar (for when it is built).**
  - (a) Exact-scan hybrid p50 at the app's chunk count with 384-d vectors is ≤ 30 ms on the phone (F-02).
  - (b) J2: RRF recall@10 ≥ lexical's, which is M12-T1's own criterion 4.
- **J2?** Yes, plus F-02 and M12-T1.

### 12. Parallel search across segments, and determinism

- **Luxir.** Work-stealing across segments, but **serial by default** (`max_parallel: 0`). Determinism by total-order cuts [site: guide/searching; repo: src/luxir/search/Collector.h L70-77].
- **Here.** One segment, one user, about 1 ms per query after learning 3. Determinism already holds: ties break on `document_index` (`hybrid.zig:231-236`, `:253-256`), and two runs produce byte-identical sections (`PROJECT-STATE.md:50`).
- **Worth it?** No. Splitting one small segment across 8 cores to save a millisecond costs battery and complexity. Luxir's own default (serial) agrees. **Keep the determinism property** as a test: any future parallel code must give byte-identical output.

### 13. The request-tree idea against `ss_query`'s options

- **Luxir.** One request tree of named ops with nested facets, fusion and metrics. `?explain=request` echoes the canonical request [site: guide/searching; guide/http-api].
- **Here.** Four flat options (`search_simpli.h:143-155`), which are enough for a chat app's retrieval call.
- **Worth it?** The tree, no. **Echoing the effective request is worth taking:** today the result echoes `query` and `mode` (`rpc.zig:270-297`), not `top_k`, `candidate_k` or `path_prefix`. Add them to `retrieval{}` alongside learning 6.
- **Bar:** the same as learning 6 (additive fields, byte-identical otherwise).

### Learnings considered and not ranked

- **SIMD/PFor postings codecs.** Our 8.2 MB lexical section at 10k chunks is not a constraint shown by any measurement. Revisit only if F-02 shows storage or memory pressure.
- **One-byte norms.** Our exact lengths are more precise, and nothing measured favours the change.
- **Prefix matching on the last typed word.** Luxir's `prefix` is constant-scoring [site: guide/query-language]. The app submits whole messages, not keystrokes, and "dino" for "dinosaur" is the only shape it would catch. Add a J2 query or two for it. Below fuzzy unless J2 shows truncated words.

---

## 4. Proposed task list (not written as task files)

These are in build order. The first five need no new fixture. The relevance tasks wait for J2.

| Id | Purpose (one line) | Size | Bar | Needs J2? | Files it would touch |
|---|---|---|---|---|---|
| **S2-T1** | Accept `analyzer-v2` on `ss_import_json`, so the app's path indexes Tamil and Unicode (learning 1) | M | §3 L1 (a)-(d) | No | `zig/src/importer.zig`, `contracts/snapshot-interchange.schema.json`, `contracts/CONTRACTS_VERSION`, `zig/include/search_simpli.h` (doc), `bindings/dart/search_simpli/lib/src/*` (interchange type), `tests/` goldens, `docs/zig-engine-api.md` |
| **S2-T2** | Linear-time ASCII dictionary build on the import path (learning 2) | S | §3 L2 (a)-(d) | No | `zig/src/postings.zig` or `zig/src/importer.zig` (route through `lexical_build.zig`), `zig/src/bm25_conformance_test.zig` |
| **S2-T3** | Top-k selection over matched chunks; no semantic pass in lexical mode (learning 3) | S | §3 L3 (a)-(d) | No | `zig/src/hybrid.zig`, `zig/src/abi.zig` (scratch sizes), `zig/src/rpc.zig`/`service.zig` (scratch), `zig/src/benchmark.zig` |
| **S2-T4** | `warnings`, opt-in `profile`, and echo of the effective request in the `ss_query` report (learnings 6, 13) | S | §3 L6 (a)-(d) | No | `zig/src/rpc.zig`, `zig/src/abi.zig`, `zig/src/engine.zig`, `zig/src/lexical_build.zig`, `contracts/search-tool.schema.json`, `contracts/CONTRACTS_VERSION`, `zig/include/search_simpli.h`, Dart result types |
| **S2-T5** | Directory fsync on publish; opt-in `keep_generations` pruning (learning 10) | S | §3 L10 (a)-(e) | No | `zig/src/publication.zig`, `zig/src/lifecycle.zig`, `zig/src/indexer.zig`, `zig/src/importer.zig`, `zig/src/abi.zig`, `zig/include/search_simpli.h`, `docs/publication-recovery.md`, `docs/generation-lifecycle.md` |
| **S2-T6** | Fuzzy expansion for absent query words, with blended df and damping, reported as a warning (learning 4) | M | §3 L4 (a)-(f) | **Yes** (misspelling + control) | `zig/src/lexical_build.zig`, `zig/src/postings.zig`, new `zig/src/fuzzy.zig`, `zig/src/engine.zig`, report fields from S2-T4 |
| **S2-T7** | `analyzer-v3`: NFKC + full fold, Latin diacritic fold, marks kept inside words, possessive + S-stemmer on lowercase ASCII only (learning 5) | M | §3 L5 (a)-(g) | **Yes** (morphology, accent, Tamil, control) | new `zig/src/analyzer_v3.zig`, `zig/src/nfc.zig` (NFKC), `scripts/gen_unicode_tables.py`, `zig/src/unicode_tables.zig`, `zig/src/indexer.zig`, `zig/src/engine.zig`, `zig/src/importer.zig` |
| **S2-T8** | Path/title as a second small field, added with a fixed weight (learning 7) | M | §3 L7 (a)-(d) | **Yes** (title + control) | `zig/src/indexer.zig`, `zig/src/importer.zig`, `zig/src/manifest.zig` (new section), `zig/src/engine.zig`, `zig/src/hybrid.zig`, `docs/manifest-format-v1.md` |
| **S2-T9** | Borrow aligned postings in place; duplicate check at publish only (learning 9) | M | §3 L9 (a)-(d) | No. **Needs F-02 phone numbers** | `zig/src/lexical_segment.zig`, `zig/src/abi.zig`, `zig/src/snapshot_open.zig`, `docs/lexical-segment-format-v1.md` |
| **S2-T10** | Positions and a proximity bonus (learning 8) | L | §3 L8 (a)-(e) | **Yes** (phrase + control) | `zig/src/lexical_build.zig`, `zig/src/lexical_segment.zig` (`HYBLEX02`), `zig/src/indexer.zig` (`reconstructTokensFromPostings`), `zig/src/scoring.zig`, new format doc |

On ordering:
- S2-T1 and S2-T2 both touch `importer.zig` and could be one task. They are kept apart because T1 changes a contract and T2 must not.
- S2-T3 should land before S2-T6, so fuzzy's latency bar (L4 e) is measured on the fast path.
- S2-T4 should land before S2-T6 and S2-T7, which report through it.
- Learning 11 is not a task. It is a design rule handed to M12-T1.

**A request to the J2 owner**, not a task here: §3.0's slice table.

---

## 5. What not to copy, and why

These parts of Luxir answer a different problem. They are listed so nobody reads the comparison as a to-do list.

- **Scale-up economics and the work-stealing scheduler.** Luxir is designed for "one big node" and "many cores, large memories, fast NVMe" [repo: docs/design/architecture.md L11-30]. We run one query for one user on a phone battery, at about 1 ms per query after S2-T3. Even Luxir defaults to serial execution [site: guide/searching].
- **Block-max/MaxScore/WAND and impacts in the postings.** These pay off when scoring postings dominates, as for a "'the'-sized term with ~35K block headers" [repo: src/luxir/query/ImpactsIndex.h L16-33]. In our profile, scoring did not register at all (M3).
- **SIMD codecs, roaring bitsets, a trie-routed block dictionary.** These are built for 10M-document segments. Our largest measured index is 8.2 MB of lexical data.
- **Segments, merge policy, and concurrent merges.** We rewrite one segment per generation in 0.9 s at 10k chunks (M1). Merging exists to avoid exactly that rewrite at sizes we do not have.
- **Faceting with exact counts over millions of documents, and multi-select facets.** No caller of ours facets. A family app asks one question and shows one source.
- **The request tree, `expr` query language and `rescore` expressions.** The app's call is a query string plus four options. A query language for children would be a hazard.
- **gRPC, HTTP-as-a-server, multi-tenancy, NDJSON streaming ingest, `field_map`.** We are an in-process library behind an FFI, with a loopback-only CLI server. Ingest is a folder or one interchange document.
- **Schema templates and suffix-typed fields (`_t`, `_s`, `_v`…).** We have one field (chunk text) and, with S2-T8, a second.
- **Geo.** Nothing in a family's files needs it.
- **IVF+PQ approximate vectors.** Luxir itself size-gates it and defaults to exact scan [site: guide/vector-search]. At thousands of chunks, exact scan is the right answer until F-02 says otherwise.
- **An in-memory default backend and "updates since the last commit can be lost".** Our only mode is durable publish, and it should stay that way.
- **Byte-wise Levenshtein.** We copy the fuzzy defaults but count edits on code points, because a Tamil letter is three UTF-8 bytes.

---

## 6. Board candidates (for the owner to move; the board is not edited here)

Written in `IMPROVEMENT-BOARD.md`'s own template (`IMPROVEMENT-BOARD.md:77-87`). Each one names the learning it comes from.

```
### F-03 — The app's publish path indexes Unicode and Tamil
- **Why:** The family app publishes through `ss_import_json`, which accepts only
  `ascii-alnum-v1`; measured 2026-10-08, the Tamil fixture published that way
  has 0 terms and success@1 0.00, and accented words split (`café` → `caf`).
  The Unicode analyzer built in S1-T1 never reaches the phone.
- **What:** Accept `analyzer-v2` in the interchange contract (additive, minor
  version bump); build it with the hash-map builder. Keep v1 accepted.
- **Exit check:** Tamil fixture through `import-json` 1.00 success@1; full
  rankings identical to `searchd index` on every judged fixture; v1 imports
  byte-identical to today.
- **HIO tie:** Use-side. The family's own language becomes searchable.
- **Owner-type:** agent
- **Status:** proposed
- **Owner:**
- **Links:** docs/research/2026-10-luxir-learnings.md §2.1 M5, §3 L1

### F-04 — Linear-time import build
- **Why:** `import-json` uses the pre-S1-T3 dictionary build: 12.19 s for
  1,000 documents and 108.25 s for 10,000 on an M1 (`searchd index`: 0.12 s,
  0.92 s), and the app rebuilds on every import.
- **What:** Route the ASCII import build through the hash-map path with the
  same df/tf/length semantics.
- **Exit check:** 10k import ≤ 2 s on the same machine; query JSON
  byte-identical on all goldens.
- **HIO tie:** Use-side. Imports stop stalling the app.
- **Owner-type:** agent
- **Status:** proposed
- **Owner:**
- **Links:** docs/research/2026-10-luxir-learnings.md §2.1 M4, §3 L2

### F-05 — Rank only what matched
- **Why:** About 94% of query time is three full-corpus sorts, lexical mode
  included (8-12 ms p50 at 10k chunks on an M1); scoring is not visible
  in the profile.
- **What:** Top-k selection over matched chunks; skip the semantic pass when
  there are no vectors.
- **Exit check:** byte-identical `ss_query` output on goldens and 200 random
  queries; p50 ≤ 2 ms at 10k chunks.
- **HIO tie:** Build-side. Evidence before complexity (no block-max needed).
- **Owner-type:** agent
- **Status:** proposed
- **Owner:**
- **Links:** docs/research/2026-10-luxir-learnings.md §2.1 M2-M3, §3 L3

### S-03 — Say when a query word matched nothing
- **Why:** A misspelt or unknown word is dropped silently; the app cannot tell
  a child "I couldn't find *dinosaurus*", and testers cannot see per-phase
  timings on a device.
- **What:** A `warnings` array and an opt-in `profile` in the `ss_query`
  report; echo the effective request.
- **Exit check:** byte-identical output with the new fields removed; every
  unmatched word reported; profile off costs ≤ 2%.
- **HIO tie:** Use-side. The system says what it did not understand.
- **Owner-type:** either
- **Status:** proposed
- **Owner:**
- **Links:** docs/research/2026-10-luxir-learnings.md §3 L6

### F-06 — Misspelling tolerance and light folding, gated on J2
- **Why:** Children misspell and inflect; today `dinosaurus`, `cafe` (for
  café) and `crepes` find nothing. Luxir's blended fuzzy scoring and
  ASCII-guarded stemming are a tested shape for this.
- **What:** Fuzzy expansion for words absent from the index; analyzer-v3
  (NFKC, Latin diacritic fold, Tamil-safe words, possessive + plural
  stemming on lowercase ASCII only). Each part measured alone.
- **Exit check:** the pre-registered bars in §3 L4 and L5 on J2's
  misspelling, morphology, accent, Tamil and control slices.
- **HIO tie:** Use-side.
- **Owner-type:** either
- **Status:** blocked (needs J2 with the §3.0 slices)
- **Owner:**
- **Links:** docs/research/2026-10-luxir-learnings.md §3.0, §3 L4-L5

### F-07 — Durable publish on a phone: directory sync and generation pruning
- **Why:** Publication never fsyncs the directory, and superseded
  generations are never deleted; the app republishes the whole index on
  every import, so storage grows by a full snapshot each time.
- **What:** fsync the directory after renames; opt-in `keep_generations`.
- **Exit check:** ordered directory syncs shown by test; 20 publishes with
  `keep_generations: 2` leave 2 generations; SIGKILL recovery still works.
- **HIO tie:** Build-side.
- **Owner-type:** agent
- **Status:** proposed
- **Owner:**
- **Links:** docs/research/2026-10-luxir-learnings.md §3 L10
```

The existing **F-02** gains two consumers: §3 L9 (read-in-place) and §3 L11 (exact-scan hybrid at 384 dimensions).

---

## 7. What could not be established about Luxir

- **How `fold` treats non-Latin combining marks** (Tamil vowel signs, virama). The docs say "accent and diacritic folding" [site: guide/schema], and the implementation was not traced into uni-algo. So whether Luxir's `_t` template would damage Tamil is **unknown**.
- **How the UAX#29 tokenizer handles Tamil in practice.** UAX#29 keeps `Extend` marks inside words, so Tamil words should stay whole, but this was not observed running. Luxir ships Linux x86-64 binaries only and was not run for this document.
- **Relevance quality.** Luxir publishes no relevance evaluation of any kind. The benchmark page says it "says nothing about… relevance" (<https://yonik.com/bench/full-text/>). Whether blended fuzzy scoring actually keeps "a rare misspelling" below "the exact term" is **claimed, not measured**.
- **The term dictionary's lookup cost, and the merge policy's behaviour under churn.** Both are read from source comments only [repo: TrieBuilder.h; IndexWriter.h L146-283]. No numbers.
- **Every performance figure on luxir.org.** "Pareto frontiers… eliminate scoring work", "zero-copy", "adaptive facet execution", "faster than the fastest Lucene-based engines": **claimed, not measured** on the site. The site itself says "Benchmark results are not yet published" [site: features].
  - The yonik.com figures are measured, but only for full-text throughput and latency on one 10M-document, one-segment corpus with a pre-release build.
  - Vector, faceting and indexing benchmarks are listed as "Coming" (<https://yonik.com/bench/>).
- **Whether Luxir's determinism guarantee covers text search under parallelism.** The docs state bit-identical parallel results for **vector** search only [site: design/vector-search]. The text top-k heap is a total order [repo: Collector.h L70-77], but no doc states the guarantee for text queries.
- **Fuzzy truncation reporting.** The docs disagree: "Truncation is not reported in the response" [site: guide/query-reference] versus "the operator/clause budget may lower it with a warning" [site: reference/protobuf, `FuzzyQuery.max_expansions`].
- **Replication status.** The docs disagree: replication is "not shipped" per README.md and features.md, but `docs/guide/replication.md` exists on `main` since 2026-09-23, after 0.1.0. The 0.1.0 position is the one used above.
- **The durable publish sequence.** The full sync sequence and the removal of obsolete files are described on `main` [repo: docs/guide/operations.md L188-213] and in the unreleased dev docs. The 0.1.0 site states only the shorter "written to a temporary name, synced, and atomically renamed" [site: design/architecture].

---

## Appendix A. Commands (bounded; `$S` is a scratch directory outside the repository)

Toolchain and build:
```sh
cd zig
perl -e 'alarm 590; exec @ARGV' -- <zig-0.16.0>/zig build -Doptimize=ReleaseSafe -p $S/searchd-rs
perl -e 'alarm 590; exec @ARGV' -- <zig-0.16.0>/zig build lib -Doptimize=ReleaseSafe -p $S/lib-rs   # for symbolised profiling only
```

Corpora:
```sh
python3 scripts/gen_timing_corpus.py $S/corpus/c1k 1000
python3 scripts/gen_timing_corpus.py $S/corpus/c10k 10000
find $S/corpus/c1k -type f | xargs cat | wc -c     # 916353
find $S/corpus/c10k -type f | xargs cat | wc -c    # 7269199
```

M1, folder index, three fresh runs each:
```sh
perl -e 'alarm 300; exec @ARGV' -- /usr/bin/time -l $S/searchd-rs/bin/searchd index $S/corpus/c10k --out $S/idx-c10k-r
```

M2, in-process query latency. `qbench.py` is a 40-line ctypes harness kept in `$S/tools`, not committed: one `ss_open`, then 200 × `ss_query(handle, q, NULL, 0, 5, '{"retrieval_mode":"lexical"}')`, timed with `perf_counter`, reporting p50, p95 and max.
```sh
perl -e 'alarm 300; exec @ARGV' -- /usr/bin/time -l python3 -I $S/tools/qbench.py \
  bindings/dart/search_simpli/native/macos-arm64/libsearch_simpli.dylib $S/idx-c10k 200 \
  "benico" "hybrid retrieval" "how does the hybrid retrieval work for a search" "the and of to in"
```

M3, profile:
```sh
python3 -I $S/tools/qbench.py $S/lib-rs/lib/aarch64-macos/libsearch_simpli.dylib $S/idx-c10k 400 benico &
sample <pid> 3 -file $S/sample2.txt
```

M4, the app's publish path. `to_interchange.py` packages each file as one interchange document with `analyzer_id: "ascii-alnum-v1"`.
```sh
python3 -I $S/tools/to_interchange.py $S/corpus/c10k $S/c10k.json
perl -e 'alarm 590; exec @ARGV' -- /usr/bin/time -l $S/searchd-rs/bin/searchd import-json $S/imp-c10k $S/c10k.json
```

M5 and the judged baselines. `judge.py` runs `searchd query --json --top-k 10` per judged query and computes success@1, MRR@10 and recall@10.
```sh
$S/searchd-rs/bin/searchd index fixtures/mixed-knowledge --out $S/j-mixed
python3 -I $S/tools/judge.py $S/searchd-rs/bin/searchd $S/j-mixed fixtures/mixed-judgments.json
# Tamil through the app path: the fixture's passages packaged as ascii-alnum-v1 interchange, then
$S/searchd-rs/bin/searchd import-json $S/j-tamil-imp $S/tamil.json   # → terms=0 postings=0
python3 -I $S/tools/judge.py $S/searchd-rs/bin/searchd $S/j-tamil-imp fixtures/tamil/judgments.json   # → success@1 0.00
```

Raw outputs, abbreviated (the full figures are in §2.1):
```
indexed corpus/c10k: analyzer=analyzer-v2 generation=1 files_indexed=10000 ... documents=10003 terms=24057 postings=925927
        0.92 real         0.69 user         0.21 sys
imported generation 1: documents=10000 terms=24057 postings=925833 vector_dimensions=0
      108.25 real       108.03 user         0.07 sys
open_ms 76.49
query 'benico'           results=5 p50_ms=11.563 p95_ms=11.785 max_ms=12.462
ss_query with options {"bogus":1} -> ss_query: UnknownField
```

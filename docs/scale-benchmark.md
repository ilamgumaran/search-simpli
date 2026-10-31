# Scale benchmark: measure before adding machinery

## Question

Where does the current files-and-folders system stop being simple enough, and which scalable mechanisms are justified by evidence rather than intuition?

This experiment separates two costs:

1. **Build/update cost** in the Python behavioral reference: directory traversal, file reads, hashing, chunk reuse, vector movement, and JSON serialization size.
2. **Query cost** in Zig: postings scoring, exhaustive cosine scoring, independent channel ranks, candidate-depth cutoff, RRF, and final ordering.

It does not measure real embedding inference, representative relevance, concurrent load, disk-backed startup, or 384-dimensional Zig queries. Those remain explicit follow-ups.

Raw results are preserved in:

- `benchmarks/python-scale-2026-07-12.json`
- `benchmarks/zig-ranking-scale-2026-07-12.json`

## Python files-and-folders build

The harness creates one small Markdown file and one chunk per document. It measures a full build and an unchanged incremental build. The 384-dimensional provider is synthetic: it exercises vector validation, normalization, copying, reuse, and JSON storage, but deliberately excludes model inference.

| Files/chunks | No-vector full | No-vector unchanged | No-vector JSON | Synthetic-384 full | Synthetic-384 unchanged | Vector JSON |
|---:|---:|---:|---:|---:|---:|---:|
| 100 | 14.6 ms | 10.6 ms | 65,776 B | 62.9 ms | 40.1 ms | 219,259 B |
| 1,000 | 110.1 ms | 165.7 ms | 660,485 B | 467.1 ms | 512.7 ms | 2,193,669 B |
| 5,000 | 591.6 ms | 524.2 ms | 3,311,665 B | 4,538.5 ms | 2,018.4 ms | 10,976,849 B |

All unchanged neural runs reused every chunk and invoked the document embedding provider zero times.

### Interpretation

Incremental reuse does not make an unchanged scan free. The current safety contract still enumerates each path, reads every selected file, computes SHA-256, creates new Python objects, and compares the prior metadata. Its lower bound is therefore linear in files plus bytes read. At 1,000 files, the one-shot unchanged runs were slower than full builds in both modes; this benchmark has no repetitions or confidence intervals, so that individual reversal is not a stable performance claim. It is evidence that incremental reuse is primarily an **extraction and embedding cost avoidance mechanism**, not yet a fast filesystem change detector.

At 5,000 chunks, unchanged synthetic-vector preparation fell from 4.54 s to 2.02 s and performed no embeddings. A real neural model would add inference to the full-build side, so its avoided cost can be much larger, but that must be measured with the selected runtime and hardware.

The JSON reference artifact grows linearly and is verbose. At 5,000 chunks, adding 384-dimensional vectors increased it from 3.31 MB to 10.98 MB, about 3.3 times. Binary `f32` vectors alone would require 7.68 MB, showing that vectors—not merely JSON punctuation—are already the dominant payload. The reference format remains useful because it is inspectable; it is not the target production segment format.

### What would justify more update machinery?

- If directory reading/hashing violates freshness, add a filesystem watcher or journal and retain periodic reconciliation.
- If complete Zig publication violates write amplification or freshness, add immutable delta segments and tombstones, then compact in the background.
- If only neural inference is expensive, keep complete publication and batch/embed changed chunks—the current middle tier already solves that problem.
- Do not use modification time alone as authoritative content identity unless missed changes are an accepted tradeoff.

Run the benchmark with:

```sh
python3 benchmark_scale.py --sizes 100 1000 5000 --dimensions 384 \
  --out benchmarks/python-scale-local.json
```

## Zig query ranking

The Zig harness constructs the real in-memory postings index and query engine. Every synthetic document matches both query terms and has an equal 32-dimensional vector, intentionally forcing exhaustive candidate handling. `top_k=10` and `candidate_k=100` are fixed.

The original rank assignment compared every positive result with every other result. Channel ranking was O(n²), and final insertion sorting was also O(n²) in the worst case. The baseline showed the expected curve:

| Candidates | Original hybrid p50 | Final hybrid p50 | Speedup |
|---:|---:|---:|---:|
| 500 | 486.8 µs | 24.0 µs | 20.3x |
| 1,000 | 1,886.7 µs | 48.6 µs | 38.8x |
| 2,000 | 7,746.4 µs | 104.3 µs | 74.3x |
| 4,000 | 43,249.8 µs | 207.7 µs | 208.3x |
| 8,000 | 174,570.3 µs | 417.5 µs | 418.2x |

The final implementation continued to 16,000 candidates at 827 µs p50 and 32,000 at 1.69 ms p50 in the recorded run.

### What was tried

**Nested rank scan plus insertion sort — failed at scale.** It was easy to inspect and correct for the seed, but doubling candidates approached four times the latency. At 8,000 candidates, ranking made an otherwise small exact scan take 174.6 ms median.

**In-place heap sort — theoretically better, operationally poor.** Sorting each channel and assigning ranks in one pass removed the nested rank scan and gave O(n log n) worst-case complexity without allocation. Stage timing showed postings scoring at only tens of microseconds, while the heap-based ranking still took 43.0 ms median at 8,000 candidates. It improved the original, but its constants on the result records were not acceptable.

**In-place pattern-defeating quicksort (`std.sort.pdq`) — worked.** It preserves the same total ordering—score descending, document index ascending—then assigns ranks in one pass. The semantic channel repeats this independently, candidate ranks beyond `candidate_k` are removed, RRF is calculated, and the results receive the same deterministic fused ordering. At 8,000 candidates the median fell to 0.417 ms. A focused test locks channel ties, cutoffs, and fused ordering.

The query-time model is now approximately:

```text
postings for query terms  O(Pq)
exact vector scoring      O(A * dimensions)
three in-place sorts      O(A log A)
fusion/result scan        O(A)
```

`Pq` is the number of visited postings and `A` is the number of authorized documents retained in the current result workspace. `candidate_k` controls fusion depth; it does **not** yet prevent exhaustive vector scoring or full channel sorts.

Run the benchmark with a release build:

```sh
cd zig
zig build -Doptimize=ReleaseFast
./zig-out/bin/searchd benchmark 8000 32 51 hybrid
```

## Positions, `find` and `HYBLEX02` (S3-T2)

CAP-19 NFR-10 (phrase p50 ≤ 5 ms, words p50 ≤ 1 ms at 10k chunks) and NFR-11
(`HYBLEX02` ≤ 2.5× `HYBLEX01`), measured with the §13 profile of
[`folder-knowledge-implementation.md`](folder-knowledge-implementation.md):
MacBook Pro, Apple M5 Pro (18 cores), 48 GB, macOS 26.6.2 (25G83), Zig 0.16.0,
other sessions running (load average 1.4–1.8). "Before" is `main` at
`73fc226` (S3-T1 merged), "after" the S3-T2 branch; both `searchd index <corpus>
--out <dir> --analyzer v2`. Corpora: the 10k generator
(`scripts/gen_timing_corpus.py <dir> 10000`: 10,000 Markdown files, 7,269,199
bytes, sha256 `3a520dd5…ed96e38`, 19,959 chunks, 1,135,768 tokens) and the
family-folder fixture with its three roots side by side (998 chunks).

Section sizes (bytes; documents, source and manifest are identical before and after):

| Corpus | documents | source (retained) | lexical before (`HYBLEX01`) | lexical after (`HYBLEX02`) | ratio | of which section 4 | section 5 | rollback "positions only" (no section 5) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 10k corpus | 9,273,775 | 8,279,041 | 9,000,597 | 12,487,753 | **1.39×** | 1,135,768 | 2,351,372 | 10,136,381 (1.13×) |
| fixture | 1,420,186 | 1,170,496 | 1,969,322 | 2,721,533 | **1.38×** | 309,813 | 442,382 | 2,279,151 (1.16×) |

Sections 1–3 are the same size before and after (the sorted dictionary has the
same bytes in another order). Section 4 is one byte per token on the 10k
corpus (1.41 on the fixture, whose long log chunks have ordinals above 127);
section 5 is four bytes per chunk plus two per token on both.

`searchd index`, three runs each (wall seconds; peak RSS from `/usr/bin/time -l`):

| Corpus, build | before: seconds | before: peak RSS | after: seconds | after: peak RSS |
|---|---|---:|---|---:|
| 10k, ReleaseFast | 0.46, 0.45, 0.45 | 266,076,160 | 0.61, 0.43, 0.43 | 118,390,784 |
| 10k, ReleaseSmall | 0.67, 0.68, 0.67 | 265,814,016 | 0.85, 0.67, 0.67 | 118,128,640 |
| fixture, ReleaseFast | 0.05, 0.05, 0.05 | 61,571,072 | 0.05, 0.05, 0.05 | 31,408,128 |
| fixture, ReleaseSmall | 0.08, 0.08, 0.08 | 61,292,544 | 0.08, 0.10, 0.10 | 31,244,288 |

The first "after" run each time is the cold one. Peak RSS falls by more than
half because the positional build keeps its working buffers out of the
indexing arena: the analyzer used to leave a normalized copy and a codepoint
array per chunk in the arena (the S3-T2 tokenizer streams NFC with an offset
map and allocates only its exact-size result).

Query latency, `zig/src/find_bench.zig` (open the index, draw queries from the
indexed chunks, 5 warm-up then 200 timed per mode, three repetitions;
microseconds p50 / p95 per repetition; `find` with page size 20;
`search_knowledge` = `Engine.queryTokenized`, lexical, top 10):

| Mode (10k corpus, 19,959 chunks) | ReleaseFast | ReleaseSmall | mean hits |
|---|---|---|---:|
| `search_knowledge` before | 65.4 / 105.2, 61.9 / 99.8, 62.3 / 103.0 | 86.6 / 126.0, 84.6 / 122.7, 83.9 / 126.0 | 10.0 |
| `search_knowledge` after | 31.5 / 102.1, 30.3 / 101.9, 31.3 / 105.1 | 48.2 / 132.3, 48.8 / 130.9, 48.1 / 133.6 | 10.0 |
| `find` words | **5.6** / 223.7, 5.0 / 211.7, 5.1 / 212.7 | **6.5** / 245.8, 5.7 / 235.2, 5.7 / 232.0 | 144.6 |
| `find` phrase (three adjacent tokens) | **17.6** / 750.3, 16.8 / 716.0, 16.1 / 715.8 | **23.1** / 888.5, 20.5 / 844.6, 19.9 / 837.0 | 1.2 |
| `find` prefix (four codepoints + `*`) | 663.9 / 2,599.9, 660.9 / 2,587.1, 659.1 / 2,583.7 | 744.7 / 2,953.3, 749.5 / 2,944.7, 739.8 / 2,926.3 | 4,559.8 |
| words, offsets recomputed (rollback) | 27.3 / 297.0, 27.0 / 291.7, 26.8 / 293.8 | 40.7 / 354.1, 38.5 / 349.0, 37.7 / 341.6 | 144.6 |
| phrase, offsets recomputed (rollback) | 24.1 / 750.8, 22.8 / 742.3, 22.8 / 738.9 | 30.8 / 879.3, 28.8 / 864.4, 28.6 / 874.7 | 1.2 |

| Mode (fixture, 998 chunks) | ReleaseFast | ReleaseSmall | mean hits |
|---|---|---|---:|
| `search_knowledge` before | 23.7 / 25.4, 23.3 / 24.8, 23.2 / 25.2 | 30.6 / 33.2, 30.4 / 33.8, 29.9 / 32.5 | 9.6 |
| `search_knowledge` after | 21.5 / 22.8, 20.8 / 21.9, 21.1 / 22.8 | 36.5 / 43.0, 36.2 / 41.6, 35.8 / 42.7 | 9.6 |
| `find` words | 85.0 / 112.7, 83.3 / 114.9, 83.0 / 109.9 | 97.5 / 127.4, 99.8 / 128.3, 98.5 / 125.0 | 75.6 |
| `find` phrase | 14.6 / 17.4, 14.5 / 16.8, 14.1 / 16.5 | 16.2 / 19.3, 16.3 / 19.0, 15.7 / 18.3 | 1.0 |
| `find` prefix | 294.2 / 667.9, 294.8 / 674.5, 287.0 / 656.3 | 328.8 / 767.4, 327.2 / 756.4, 328.6 / 726.9 | 226.9 |
| words, offsets recomputed (rollback) | 891.9 / 1,108.3, 880.0 / 1,088.9, 875.4 / 1,102.7 | 1,291.9 / 1,616.7, 1,250.3 / 1,570.0, 1,268.7 / 1,578.0 | 75.6 |
| phrase, offsets recomputed (rollback) | 37.5 / 41.4, 37.7 / 42.1, 38.3 / 42.0 | 53.7 / 57.2, 53.5 / 57.1, 53.2 / 56.6 | 1.0 |

NFR-10 is met with a wide margin (phrase p50 at most 23.1 µs against 5 ms,
words p50 at most 6.5 µs against 1 ms), and NFR-11 at 1.39×. `search_knowledge`
got faster on the 10k corpus in both builds (a sorted dictionary is
binary-searched; the v1 lookup scanned every term) and on the fixture in
ReleaseFast, but slower on the fixture in ReleaseSmall (p50 about 30 → 36 µs,
reproduced in two more runs: 30.3–31.3 before, 35.6–36.9 after); this
measurement does not explain that difference. Scores are unchanged (the BM25
golden test).
The fixture's words queries are slower than the 10k corpus's because many of
them hit the overlapping line windows of its 15,500-line log file, so
deduplication compares shared lines; recomputing offsets there (the rollback)
re-tokenizes every such chunk and costs about ten times more.

Opening the index and the query process: open 70.9 → 84.3 ms (ReleaseFast) and
73.7 → 87.9 ms (ReleaseSmall) on the 10k corpus, 10.0 → 12.7 and 10.7 → 13.9 ms
on the fixture (sections 4 and 5 are validated and the position tables built
at open). Peak RSS of the timing process: 10k 41,910,272 → 49,315,840 bytes
with `search_knowledge` alone, 59,015,168 with all four modes; fixture
13,500,416 → 16,941,056 with all four modes (the two rollback modes add the
re-tokenized chunks to the query arena: 39,944,192).

## Three operating options

### 1. Simplest local option

Use the Python scanner, one replaceable JSON index, BM25, an optional local embedding provider, exhaustive vectors, and the JSON-lines knowledge tools. This is the best place to change chunking, contracts, and evaluation. The current measurements support thousands of small files, but an actual limit must include the user's file sizes, model latency, and acceptable refresh time.

### 2. Practical durable single node

Use Python or dedicated workers for extraction/embedding, publish the existing Zig binary segments atomically, and serve long-lived Zig readers. Keep exact vector scan and full deterministic fusion while they meet p95 latency. Add startup, resident-memory, 384-dimensional, and concurrent-query benchmarks before choosing ANN or compression.

### 3. Full-scale platform

When measured limits require it:

- generate lexical top-N with block-max/WAND-style pruning rather than scoring every posting;
- generate semantic top-N with HNSW or another measured ANN structure while keeping exact scan as the recall oracle;
- fuse only the union of channel candidates instead of sorting every document;
- use memory-mapped compact segments, vector quantization only under a memory constraint, and reader-safe segment compaction;
- shard only after one node fails capacity, throughput, or availability goals.

Each mechanism changes correctness, update cost, or operational complexity. It therefore needs a before/after latency measurement and a relevance/recall regression gate.

## Next measurements

1. Repeat Zig query tests with 384-dimensional non-identical vectors and realistic authorization selectivity.
2. Measure persisted snapshot bytes, open/startup time, and resident memory at 10k, 100k, and 1M chunks where feasible.
3. Measure parallel queries and p95/p99 under a long-lived service, not process startup.
4. Measure full versus incremental preparation with the chosen real embedding provider.
5. Run all performance work alongside representative judged relevance; a fast wrong answer is not a successful search system.

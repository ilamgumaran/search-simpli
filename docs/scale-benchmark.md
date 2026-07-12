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

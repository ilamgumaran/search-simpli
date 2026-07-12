# Architecture: one contract, two implementations

## Product invariant

A caller asks a question and receives ranked, cited evidence. Whether that caller is a command-line user, an LLM tool, a skill, or an agent should not change the underlying retrieval behavior.

```text
files/folders -> extract -> chunk -> index -> retrieve -> fuse -> evidence pack -> answer model
                                ^                           |
                                +------ evaluation --------+
```

Generation is downstream of retrieval. This keeps authorization, provenance, relevance testing, and engine replacement understandable.

## Option A: smallest useful local system

Use this for one person or agent, thousands of files, and experimentation.

| Concern | Choice |
|---|---|
| Source | Local directory tree |
| Extraction | UTF-8 text and source formats |
| Chunking | Bounded, overlapping line windows |
| Lexical | In-memory BM25 calculation |
| Vector | Pluggable embedding provider; exhaustive cosine scan |
| Fusion | Reciprocal-rank fusion (RRF) |
| Storage | One replaceable JSON index; content-hash reuse from a compatible prior index |
| LLM boundary | `search_knowledge` evidence envelope |
| Security | Root/path scope plus persisted all-required access labels |

Advantages: inspectable, dependency-free in its base mode, easy to change, with optional PPMI/neural semantics and incremental reuse. Limits: every update still publishes a complete snapshot, term data is duplicated, vector scans are linear, and there is no watcher or concurrent-query guarantee in the reference process.

The first synthetic scale run reached 5,000 small one-chunk files in 0.59 seconds without vectors and produced a 3.31 MB JSON artifact. An unchanged build still reads and hashes every file; reuse saves extraction and embedding work but is not a constant-time change detector. Treat these numbers as a local baseline, not a capacity guarantee.

The current Python code implements this option as a behavioral reference.

## Option B: durable single-node Zig engine

Use this when the corpus, write rate, or latency target outgrows the reference implementation.

The current Zig exact-query path now uses deterministic in-place `O(n log n)` channel and fused ordering. In the recorded 32-dimensional worst-candidate synthetic run it served 32,000 candidates in 1.69 ms median. The next capacity decision requires 384-dimensional, persisted-startup, memory, concurrency, and representative-filter measurements; candidate depth currently limits fusion ranks but not exhaustive scoring or full sorting.

### Ingestion

1. A scanner emits `upsert(document)` and `delete(document_id)` operations.
2. Format-specific extractors produce normalized UTF-8 plus metadata. Keep PDF, Office, OCR, and web parsing out of the core engine process.
3. A deterministic chunker emits stable chunk ids. Content hashes make unchanged chunks cheap to skip.
4. An embedding worker batches chunks through a chosen model and returns versioned vectors. It can be a local process or network service.
5. The Zig writer appends operations to a write-ahead log, builds immutable lexical and vector segments, then atomically publishes a new manifest.

### Lexical segment

- sorted term dictionary;
- compressed postings with document-id gaps and term frequencies;
- per-chunk length plus corpus statistics for BM25;
- skip blocks for faster conjunction and top-k traversal;
- stored fields for citations and result snippets.

Start with varint-coded postings and simple block maxima. Consider an FST term dictionary and SIMD codecs only after profiling.

### Vector segment

- versioned dense vectors associated with the same chunk ids;
- exhaustive scan first, with contiguous aligned storage;
- HNSW when measurements show scan latency or memory bandwidth is the limiting factor;
- optional scalar/product quantization only after recall and memory budgets are explicit.

Embedding inference is intentionally outside the first Zig engine. Zig owns vector storage, distance calculation, filtering, and approximate-nearest-neighbor traversal. A model runtime can later be linked through C ABI or called as a service without coupling index formats to one model.

### Query path

```text
query
  +-> tokenizer -> lexical top N ----+
  +-> embedder  -> semantic top N ---+-> RRF -> optional reranker -> top K evidence
  +-> filters -----------------------+
```

Retrieve each channel independently, fuse by rank, and preserve component ranks in the response. RRF is the first production default because BM25 and cosine scores are not calibrated to each other. A cross-encoder or LLM reranker can later reorder a small candidate set, but must not erase provenance.

### Reliability

- immutable segments and checksummed manifests;
- crash recovery by replaying the write-ahead log after the last committed sequence;
- background compaction with snapshot-safe readers;
- bounded queues and admission control rather than unbounded memory growth;
- metrics for ingest lag, p50/p95/p99 latency, candidate counts, fusion overlap, cache hit rate, and index size;
- structured query traces that can explain why a result ranked.

## Option C: distributed search platform

Only take this step when corpus size, throughput, or availability requires it.

| Layer | Responsibility |
|---|---|
| Control plane | collections, schemas, placement, index/embedding versions |
| Ingest log | ordered durable mutations and replay |
| Shards | own lexical and vector segments for a document-id range |
| Replicas | availability and read scaling |
| Coordinator | fan-out, per-shard top N, global fusion/top K, timeouts |
| Object storage | segment snapshots and recovery |
| Evaluation service | judged queries, regression gates, online telemetry |

Prefer document-id hashing for balanced general search; use tenant-first partitioning when isolation is more important than global balance. Filters must be applied consistently in both lexical and vector retrieval, not after top-k selection.

## Shared data contracts

The logical entities should remain stable across all options:

- **Document**: id, source URI/path, content hash, metadata, authorization labels.
- **Chunk**: stable id, document id, text, byte/line span, chunker version.
- **Embedding**: chunk id, model id, dimensions, normalization, vector.
- **Search request**: query text, top k, filters/path scope, index snapshot, optional debug detail.
- **Search result**: chunk id, citation, content, fused score, component scores/ranks.

Never store a vector without its model/version metadata. Re-embedding is an index migration, not an in-place reinterpretation.

## LLM, skill, tool, and agent interface

Expose narrow operations instead of raw filesystem access:

1. `search_knowledge(query, top_k, path_prefix, filters)` returns cited passages.
2. `read_chunk(chunk_id)` returns the authoritative stored passage and metadata.
3. `list_sources(path_prefix)` helps navigation without dumping content.
4. `index_status()` exposes freshness, versions, and failures.

An agent loop can search, inspect a result, narrow its question, and then answer. The answer policy in the tool response tells the model to cite evidence and acknowledge gaps. Authorization belongs in retrieval so forbidden chunks never enter the prompt.

## Relevance evaluation

Do not select architecture by anecdote. Build a small judged query set containing:

- exact identifier/name lookups;
- paraphrases and vocabulary mismatch;
- mixed lexical/semantic questions;
- negative or unanswerable questions;
- authorization and path-scope cases;
- fresh updates and deletions.

Track recall@k, nDCG@k, mean reciprocal rank, answer citation correctness, unanswerable precision, p95 latency, index size, and ingest freshness. Compare lexical-only, semantic-only, fusion, and reranked fusion on the same judgments.

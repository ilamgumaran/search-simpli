# Theory: from text lookup to grounded answers

## 1. What problem are we actually solving?

The product is not merely a database that returns documents. It is an evidence system for humans and reasoning models:

> Given a question, find the smallest set of authorized passages that maximizes the chance of a correct, cited answer.

This separates four different kinds of quality:

1. **Coverage** — was the relevant content extracted and indexed?
2. **Retrieval** — did the relevant chunk enter the candidate set?
3. **Ranking** — did it appear near the top?
4. **Answering** — did the model use the evidence faithfully and acknowledge gaps?

An answer can fail at any layer. Treating all failures as “the LLM was wrong” prevents useful diagnosis.

## 2. Documents, chunks, and identity

A file is a source artifact, not necessarily the right retrieval unit. Search operates on chunks because whole documents can be too broad for ranking and too expensive for an LLM prompt.

Chunking is a bias:

- Smaller chunks improve topical precision but lose surrounding explanation.
- Larger chunks preserve context but dilute term and vector signals.
- Overlap prevents important statements at boundaries from being split, at the cost of duplicate results.
- Syntax-aware boundaries are useful for code, headings, tables, and structured documents.

Every chunk needs stable identity and a reversible citation to its source. A content hash alone is insufficient because identical text may appear in different authorized locations. A practical identity combines source id, logical span, chunker version, and content hash.

## 3. Lexical retrieval

Lexical search matches query terms to indexed terms. Its durable structure is the inverted index:

```text
term -> [(chunk_id, term_frequency, positions...), ...]
```

BM25 is a strong first scoring model. For a query term `t` and chunk `d`, it rewards:

- term presence and repeated occurrence, with saturation;
- rarity across the corpus (inverse document frequency);
- concise chunks, through length normalization.

A common form is:

```text
IDF(t) * tf(t,d) * (k1 + 1)
-----------------------------------------
tf(t,d) + k1 * (1 - b + b * |d| / avgdl)
```

Lexical retrieval is especially strong for exact names, error strings, identifiers, versions, commands, and rare phrases. Its main weakness is vocabulary mismatch: “automobile” does not naturally match “car” without expansion or learned representations.

Tokenization and normalization are part of the relevance model, not clerical preprocessing. Case folding, Unicode normalization, stemming, code symbol splitting, and stop-word choices all change what can match.

## 4. Semantic retrieval

An embedding model maps text to a dense numeric vector. Similar meanings are intended to occupy nearby regions, so a query vector can retrieve chunks using cosine similarity, dot product, or Euclidean distance depending on model training and normalization.

Semantic retrieval helps with paraphrases, conceptual questions, and vocabulary mismatch. It can underperform on exact identifiers, numbers, negation, newly coined terms, and domain language not represented well by the model.

The vector is not self-describing. Correct interpretation requires:

- embedding model and revision;
- dimensions;
- input normalization and task prefix conventions;
- distance function;
- whether vectors are normalized;
- chunker version and source content version.

Changing the embedding model creates a new index generation. Mixing vectors from incompatible models produces meaningless distances.

The prototype’s hash projection is deliberately not called a semantic model. It creates deterministic dense vectors so storage, cosine calculation, result explanation, and fusion can be exercised without network access. It cannot test meaning-based recall.

The `cooccurrence-ppmi-v1` option is a genuine ground-up distributional model: it learns word meaning from shared context inside the indexed corpus. It can bridge vocabulary mismatch when the corpus contains enough parallel usage, but it lacks the broad prior knowledge and language sensitivity of a modern neural embedding model.

## 5. Hybrid retrieval

Lexical and semantic systems have complementary error patterns. Hybrid retrieval runs both and combines their candidate lists.

Raw score interpolation is tempting:

```text
hybrid = alpha * BM25 + (1 - alpha) * cosine
```

It is unsafe without calibration because the distributions and ranges change with corpus, query, and model. Reciprocal-rank fusion uses positions instead:

```text
RRF(d) = sum over rankers r of 1 / (k + rank_r(d))
```

RRF is simple, explainable, and robust enough for the first system. Its tradeoff is that it discards score magnitude. Later options include normalized score fusion, query-dependent weighting, learned-to-rank models, or a cross-encoder reranker over a small candidate pool.

Candidate depth matters: if each channel returns too few candidates, fusion cannot recover a document that was prematurely cut off. Retrieve `N` from each channel, fuse, optionally rerank, then return `K`, where `N` is normally larger than `K`.

## 6. Approximate vector search

Exact vector scan compares the query to every vector. It is the correctness baseline and is often sufficient for small corpora or highly optimized contiguous arrays.

Approximate-nearest-neighbor indexes trade recall, memory, and build/update cost for latency. HNSW is a graph-based choice with strong recall/latency behavior, but it consumes memory and complicates deletion and persistence. Inverted-file and product-quantization families can reduce memory and scanning but add training and tuning.

The engineering rule is: preserve exact scan as an evaluation oracle, measure the corpus, and add ANN only after a latency or capacity target is violated.

Candidate generation and candidate fusion are separate scale problems. An ANN index can make vector candidate generation cheap while a ranker still wastes time sorting every document. Conversely, efficient fusion cannot remove the `O(documents * dimensions)` cost of exhaustive cosine scoring. The first Zig scale benchmark exposed quadratic rank assignment before exhaustive vector scan became the bottleneck; replacing it with deterministic in-place `O(n log n)` sorts reduced 8,000-candidate hybrid median latency from 174.6 ms to 0.417 ms at 32 dimensions. This is a synthetic engine result, not a production latency promise; the method and limits are recorded in [the scale benchmark](scale-benchmark.md).

## 7. Retrieval-augmented generation

The LLM-facing layer should act like a narrow tool:

```text
question -> search tool -> evidence with citations -> model answer
```

The tool response must carry provenance, authorization-safe content, index freshness, and enough ranking detail for debugging. The answer prompt should require citations and permit “insufficient evidence.”

An agent adds iteration:

```text
search broadly -> inspect evidence -> refine/narrow -> read authoritative chunk -> answer
```

This resembles skills and tools because the model receives a description of an operation and structured results rather than owning the storage engine. It resembles agents because the model may decide which retrieval operation to call next.

Search content is untrusted input. A file may contain instructions aimed at the model. The application should label retrieved text as evidence, limit tool authority, apply authorization before retrieval, and avoid letting document text redefine system or tool policy.

## 8. Relevance is empirical

There is no universally best lexical weight, embedding model, chunk size, fusion constant, or candidate depth. A representative judged set is the foundation of rational tuning.

Useful offline measures:

- **Recall@k** — did any relevant chunk appear in the first `k`?
- **MRR** — how early did the first relevant chunk appear?
- **nDCG@k** — did the ranking reflect graded relevance?
- **Citation correctness** — does the cited passage support the generated claim?
- **Unanswerable precision** — does the system decline when the corpus lacks evidence?

Operational measures such as p95/p99 latency, ingest freshness, index bytes per chunk, memory, and failure recovery must be evaluated alongside relevance. A slower method may be worthwhile only if its relevance improvement matters to the use case.

## 9. Why immutable segments scale

Mutable global index structures are difficult to query concurrently and recover after crashes. A log-structured approach writes small immutable segments and atomically publishes a manifest. Readers hold a snapshot of that manifest while background work merges segments.

This pattern gives:

- lock-light readers;
- atomic visibility of updates;
- checksum and version boundaries;
- crash recovery from a write-ahead log;
- incremental compaction instead of full rebuilds.

Its costs are temporary space amplification, merge I/O, tombstone handling, and the need for careful snapshot lifecycle management.

## 10. Working hypotheses to test

1. BM25 will dominate exact source/code queries.
2. A real embedding model will improve paraphrase recall on narrative documents.
3. RRF will improve mixed-query robustness over either channel alone.
4. Structure-aware chunks will improve citation quality over fixed windows.
5. Exhaustive vector scan will remain sufficient longer than intuition suggests for a personal corpus.
6. The Zig engine will matter first for persistent segments, predictable memory, and concurrency—not for the first relevance experiment.

These are hypotheses, not conclusions. The roadmap converts them into judged experiments.

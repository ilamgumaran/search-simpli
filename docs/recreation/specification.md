# Search Simpli executable specification

Status: reconstruction contract for the implemented reference and durable-engine path.

> This document is authoritative for the **detailed behavior** of functional
> requirements (FR) and non-functional requirements (NFR). For the consolidated
> view of every requirement — capabilities, use cases, invariants, and the
> conflict register — see the [requirements register](../requirements/README.md).
> New requirements enter via the [capability process](../capability-process.md).

## 1. Scope

### In scope

- selected UTF-8 text and source files under a configured root;
- deterministic line-based chunks with stable ids and citations;
- BM25 lexical retrieval;
- optional semantic retrieval through a versioned provider;
- independent lexical/vector candidates fused by reciprocal-rank fusion;
- path and required-label authorization before ranking;
- LLM/agent-facing read-only tools;
- judged-query evaluation and reproducible performance benchmarks;
- Python reference indexes and immutable Zig snapshots;
- content-hash reuse for unchanged files and vectors.

### Out of scope for the base recreation

- direct LLM generation calls;
- arbitrary filesystem access from the model tool;
- PDF/Office/OCR parsers inside the core engine;
- authenticated identity issuance;
- HNSW, WAND, quantization, sharding, and replication without benchmark evidence;
- claims of production relevance from authored diagnostic fixtures.

## 2. Functional requirements

### FR-01 — Source discovery

The indexer recursively discovers configured text/source extensions, skips ignored or hidden build directories, reads UTF-8 safely, records skipped files, and stores a root-relative POSIX path plus SHA-256 for every admitted source.

### FR-02 — Chunking and identity

Chunks retain source path, one-based start/end lines, content, token counts, and required labels. Chunk identity deterministically incorporates source location/span and content. The index records the chunker id and parameters.

### FR-03 — Lexical retrieval

The reference implements case-insensitive tokenization and corpus-level BM25. The Zig engine persists document lengths, dictionary entries, document frequency, and postings so reopening does not require tokenizing stored text.

### FR-04 — Semantic retrieval

Supported progression:

- `none`: safe dependency-free default;
- `hash`: deterministic mechanical test channel, never described as semantic;
- `cooccurrence`: dependency-free corpus-trained PPMI baseline;
- `neural`: provider-neutral, batched document/query embeddings with an exact model/runtime conformance id.

Every vector index records model id, dimensions, normalization, and semantic status. Query vectors must match the stored identity and dimensions.

### FR-05 — Hybrid ranking

Lexical and vector ranks are calculated independently. Candidate ranks beyond `candidate_k` are removed, RRF combines the remaining ranks, and results are ordered deterministically with document identity as the final tie-breaker. `candidate_k` must be at least `top_k`.

### FR-06 — Evidence response

Every result includes chunk id, path, start/end lines, stored content, fused score, and available component ranks/scores. A context envelope instructs an answer model to cite evidence and acknowledge insufficient support.

### FR-07 — Tool surface

Expose these read-only operations through newline-delimited JSON-RPC or an equivalent adapter:

1. `search_knowledge`
2. `read_chunk`
3. `list_sources`
4. `index_status`

Unknown methods/parameters and invalid bounds return structured errors. A malformed input line must not terminate the process.

### FR-08 — Authorization

Path rules assign canonical all-required labels. The caller principal is trusted configuration or authenticated context, never an LLM-controlled search parameter. Unauthorized documents receive neither lexical nor semantic ranks and are absent from search, listing, and read operations. Denied and unknown chunk reads are indistinguishable.

### FR-09 — Incremental preparation

A compatible prior index may reuse unchanged chunks and stored vectors. Compatibility fails closed on root, chunker, vector mode, embedding identity, or absent source hashes. Changed/new chunks are embedded in batches; deleted files disappear. Transiently unreadable previously indexed files are explicitly reported as stale if retained.

### FR-10 — Python/Zig interchange

A versioned neutral JSON contract carries generation, analyzer id, embedding id/dimensions, chunks, citations, vectors, and required labels. Zig validates bounds and consistency before publishing a snapshot.

### FR-11 — Durable snapshot

The Zig path stores versioned checksummed document/vector and lexical sections. A manifest binds their generation, names, sizes, counts, checksums, analyzer, and embedding identity. Publication writes generation-unique files, syncs them, and atomically replaces the manifest. A writer lock serializes publication.

### FR-12 — Evaluation and benchmarks

Judged queries compare lexical, vector, and hybrid modes using at least success/recall at k and MRR. Raw benchmark results are machine-readable and documentation states hardware/runtime, synthetic assumptions, and what is not proven.

## 3. Non-functional requirements

| ID | Requirement |
|---|---|
| NFR-01 | Base Python indexing/search runs on Python 3.11+ without third-party dependencies. |
| NFR-02 | Persistent formats are versioned, bounded, checksummed, and backward compatibility is explicit. |
| NFR-03 | Query result ordering is deterministic for equal scores. |
| NFR-04 | The Zig query core uses caller-owned bounded workspaces rather than per-query unbounded allocation. |
| NFR-05 | Forbidden content is filtered before ranks, not removed only from final output. |
| NFR-06 | Optional neural imports are lazy and fail with concise provider errors. |
| NFR-07 | Every material design change is backed by tests or a recorded experiment. |
| NFR-08 | Documentation distinguishes implementation, observation, hypothesis, and future option. |

## 4. Logical contracts

### Document

`id`, source path/URI, content hash, metadata, required authorization labels.

### Chunk

Stable id, document/source identity, content, line or byte span, tokens/length, chunker identity, required labels.

### Embedding

Chunk id, exact model id, dimensions, normalization, vector.

### Search request

Query text, retrieval mode, `top_k`, `candidate_k`, optional path prefix, trusted principal context, and internal query vector only below the gateway boundary.

### Search result

Chunk id, citation, content, fused score, component scores/ranks, and index/model metadata.

The JSON schemas under `contracts/` are authoritative for cross-process payloads.

## 5. Required commands

An equivalent recreation should support these workflows, even if wrappers are renamed:

```sh
python3 search.py index <folder> --out <index.json>
python3 search.py query <index.json> "<question>"
python3 search.py context <index.json> "<question>"
python3 knowledge_tools.py <index.json>
python3 evaluate.py <index.json> <judgments.json> --top-k 3
python3 export_zig.py <index.json> --generation 1 --out <snapshot.json>
python3 zig_gateway.py <index.json> <zig-snapshot-dir>
```

```sh
cd zig
zig build test
zig build run -- import-json <snapshot-dir> <snapshot.json>
zig build run -- serve <snapshot-dir>
zig build -Doptimize=ReleaseFast
./zig-out/bin/searchd benchmark 8000 32 51 hybrid
```

## 6. Phase acceptance gates

| Phase | Required evidence |
|---|---|
| A — local lexical slice | Folder index, exact query, cited context envelope, tests for chunking/search/path scope |
| B — semantic/evaluation | Controlled lexical miss recovered semantically; hash regression labeled; judged metrics saved |
| C — Zig retrieval core | BM25/cosine/RRF tests, deterministic ties, Python/Zig golden ordering |
| D — persistence | Corruption rejection, section round trip, atomic publish/open/query, real test-runner count |
| E — agent boundary | Search/read/list/status schemas, structured errors, text-only embedding gateway handshake |
| F — authorization/update | Pre-rank isolation in both channels, denied-read behavior, change/add/delete/reuse tests |
| G — measurement | Raw indexing/query benchmarks, stage isolation, before/failed/after record for optimizations |

## 7. Documentation obligations

After each phase:

1. append an experiment entry with hypothesis, setup, observation, what worked, what failed, limits, and conclusion;
2. update the continuation state with exact current behavior, test evidence, commands, unresolved choices, and best next step;
3. update architecture/theory only when evidence changes a durable conclusion;
4. store raw judgments and benchmark results in machine-readable files;
5. never replace a failed attempt with a success-only narrative.

## Proposed requirements (pending promotion)

These requirements have been drafted through the
[capability process](../capability-process.md) but are **not yet built**. Their
canonical text lives in their capability spec until step 8 promotes it into §2/§3
above. They are listed here so the authoritative specification acknowledges every
requirement the [register](../requirements/README.md) tracks — no requirement
exists only in the register.

| ID | Short text | Capability spec | Status |
|---|---|---|---|
| FR-13 | MCP adapter binds the FR-07 operations with injected trusted principal, no caller vectors, and semantic (not byte) parity with the direct surface. | [CAP-13](../requirements/cap-13-mcp-adapter.md) | Proposed |
| FR-14 | First-class, retrieval-derived (non-generative) support/confidence signal in the evidence response; low-support flagging; changes FR-06. | [CAP-14](../requirements/cap-14-trust-calibration.md) | Proposed |
| FR-15 | Structure-aware chunking on syntactic units for supported languages with deterministic line-window fallback; changes FR-02. | [CAP-15](../requirements/cap-15-structure-aware-chunking.md) | Proposed |
| NFR-09 | Optional interface adapters (MCP/HTTP) are isolated so the base local mode stays dependency-free. | [CAP-13](../requirements/cap-13-mcp-adapter.md) | Proposed |

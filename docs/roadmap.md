# Experiment-driven roadmap

Each phase ends with evidence that justifies the next complexity increase.

The [2026-10 search quality review](search-quality-plan-2026-10.md) and its
[bounded tasks](tasks/search-quality-follow-ups.md) detail the next proposed
evaluation, regression-gate, fusion and analyzer work. They preserve existing
approval/owner gates and record no new implementation or benchmark results.

## Phase 0 — contract and corpus (present)

- Index UTF-8 files and source code from a directory.
- Preserve stable chunk ids and line citations.
- Implement BM25, a vector scoring channel, RRF, path scoping, and an LLM evidence envelope.
- Add a small fixture corpus and behavioral tests.

Exit check: the same query can be inspected by a person and consumed as structured model context. Completed by the current vertical slice.

## Phase 1 — real semantic retrieval

- Define an embedding provider protocol: batch text in, versioned normalized vectors out.
- Choose one local or hosted embedding model for the first benchmark.
- Store embedding model id, dimensions, and chunker version in the index.
- Assemble 50–100 judged queries from a real folder corpus.
- Compare lexical-only, vector-only, and RRF using recall@10 and nDCG@10.

Exit check: fusion materially improves judged relevance, especially paraphrase cases, without unacceptable exact-match regressions.

Progress: the text-only query gateway, exact trained-model fingerprinting, fail-closed Zig snapshot handshake, dependency-free PPMI provider, and optional pinned FastEmbed/BGE neural provider are implemented. The 20-query diagnostic favored neural vector search but exposed an equal-RRF regression. A representative 50–100-query user-derived judgment set with held-out evaluation remains.

## Phase 2 — Zig single-node minimum viable engine

- Pin a Zig toolchain and turn the scoring seed into tested modules.
- Define binary segment and checksummed manifest formats.
- Implement tokenizer, term dictionary, postings writer/reader, BM25 top-k, stored fields, and exhaustive vector scan.
- Import the Python reference index or replay the same document/chunk contract.
- Golden-test Zig results against the Python reference on the judged corpus.

Progress: the Zig engine has immutable document/vector, lexical, position, source and recovery-state sections, atomic publication, writer locking, reader-safe generation retention, Unicode analysis and cited evidence. JSON-RPC and MCP expose scoped search, find, outline, exact source reads, listing and status. S3/S4 add roots, visible-scope statistics, optional filename retrieval, lazy loads and verified 10k memory/update diagnostics. PPMI and neural snapshots work through the text-only gateway. See [S4-T2](tasks/S4-T2.md) for current formats, compatibility and measured Mac budgets. Physical-phone acceptance, persisted 384-dimensional and concurrent-query baselines, authenticated identity and representative relevance remain before broader scale claims. Compression/pruning, HTTP and distributed machinery still need measurements that justify them.

Exit check: crash-safe build/open/query cycle, correct deletions, reproducible results, and an explicit latency/size baseline.

## Phase 3 — incremental and agent-ready

- Filesystem watcher with debounce, content hashes, and tombstones.
- Write-ahead log, immutable segments, background merges, and snapshot readers.
- Local HTTP or MCP-compatible adapter exposing search/read/status operations.
- Authorization metadata and pre-retrieval filtering.
- Prompt-injection-aware content labeling and evidence size limits.

Exit check: an agent can answer over a changing corpus with citations, and deleted or forbidden content never appears.

Progress: trusted roots and all-required labels filter candidates and BM25 statistics before ranking and gate every read/list/status surface. The gateway rejects model-supplied principals; scoped writers cannot mint roots or filesystem grants. Content-hash reuse and host-fed changes preserve pending files and recovery provenance, remove deleted files, and atomically publish complete generations. MCP and reader-safe generation retention are implemented. Authenticated identity derivation, tenant isolation beyond these trusted scopes, filesystem watching, WAL/delta segments, tombstones and compaction remain separate work. Agent correctness over a human-confirmed judged corpus is still an acceptance gate; authored fixtures do not satisfy it.

## Phase 4 — scale only measured bottlenecks

- Add HNSW if exhaustive scan violates the vector latency budget.
- Add block-max/WAND-style lexical pruning if postings traversal dominates.
- Quantize only if memory is the binding constraint and recall loss is acceptable.
- Shard and replicate only when one node cannot satisfy capacity or availability.

Progress: the first measured bottleneck was neither ANN nor postings traversal; it was O(n²) channel rank assignment. Deterministic in-place pdq sorting fixed it and is documented with before/failed-intermediate/after data. The current benchmark also shows that postings scoring is a small fraction of the synthetic query. No additional scale mechanism is yet justified.

Exit check: every mechanism is tied to a before/after benchmark and a rollback path.

## Recommended next experiment

Use a representative user folder (documents, code, or both), author 50–100 real questions with expected source passages, and split them into tuning and held-out evaluation. Compare the implemented BM25, PPMI, and BGE paths plus fusion weights or routing. This answers whether the diagnostic neural gain survives real use without overfitting.

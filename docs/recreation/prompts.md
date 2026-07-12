# Prompts for recreating Search Simpli

These prompts are designed for a capable coding agent working in an empty repository. Use the master prompt once, then the phase prompts sequentially. At every phase, the agent must inspect existing work, preserve compatible behavior, run tests, and update the experiment and continuation documents.

## Master prompt

```text
Build a project named Search Simpli: an experiment-driven search system that starts with local files/folders and an LLM-friendly evidence tool, then evolves into a durable Zig hybrid lexical/semantic engine.

Primary objective:
Given a question, return the smallest useful set of authorized source passages that supports a correct answer with path and line citations.

Non-negotiable constraints:
- Keep retrieval separate from LLM generation.
- Begin with a dependency-free Python 3.11 behavioral reference.
- Preserve stable chunk ids, source paths, line spans, and content hashes.
- Implement BM25 first. No-vector mode is the safe default.
- Mechanical hash vectors may test plumbing but must never be called semantic.
- Add a real dependency-free semantic baseline and a provider-neutral neural path.
- Store exact embedding identity, dimensions, normalization, and chunker identity.
- Retrieve lexical and semantic candidates independently and fuse with deterministic RRF.
- Filter authorization labels before either channel receives ranks.
- Expose only search_knowledge, read_chunk, list_sources, and index_status to an LLM/agent.
- Use Python for behavioral/evaluation truth and Zig for persistent segments and predictable query execution.
- Keep exact vector scan as the correctness oracle.
- Add ANN, WAND, quantization, delta segments, or sharding only after a measured target fails.
- Tests must actually execute; compilation is not passing-test evidence.
- Relevance claims require a pinned judged profile, graded nDCG@10 plus diagnostic metrics, a lexical baseline, per-query failures, and explicit sampling limits.
- Preserve documentation of theory, prompts, experiments, failures, raw metrics, and continuation state.

Required documents:
- README.md
- PROJECT-STATE.md
- EXPERIMENTS.md
- docs/README.md
- docs/theory.md
- docs/architecture.md
- docs/roadmap.md
- docs/recreation/{README.md,specification.md,prompts.md}
- docs/use-cases/{README.md,TEMPLATE.md}

Work in small verified phases. Before changing a decision, write its hypothesis and acceptance evidence. After each phase, record what worked, what failed, what remains unproven, exact test results, and the best next step. Do not claim production relevance from synthetic fixtures.
```

## Phase 1 — contracts and local lexical slice

```text
Read docs/recreation/README.md and specification.md. Implement the smallest end-to-end Python slice.

Requirements:
- recursively discover selected UTF-8 text/source files under one root;
- ignore hidden/build/cache directories;
- create deterministic bounded line chunks with overlap, stable ids, path and line citations;
- persist one inspectable JSON index with chunker/source metadata;
- implement Unicode-aware case-folded tokenization and corpus BM25;
- expose index, human query, and JSON context-envelope CLI operations;
- default to no vector channel;
- add fixtures and behavioral tests for exact retrieval, citations, path scope, tokenization, and no-result behavior;
- expose a local JSON-lines process with search_knowledge, read_chunk, list_sources, and index_status;
- reject unknown methods and parameters and continue after malformed input.

Keep the base dependency-free. Update EXPERIMENTS.md and PROJECT-STATE.md with actual commands and executed test counts.
```

## Phase 2 — semantic baselines and evaluation

```text
Extend the verified Python reference with explicit retrieval modes: lexical, vector, and hybrid.

Implement:
- a deterministic hash projection labeled mechanical_test, opt-in only;
- cosine similarity and independent candidate lists;
- reciprocal-rank fusion with component ranks/scores and candidate_k >= top_k validation;
- a judged-query evaluator reporting success/recall at k, MRR, returned paths, and failures;
- backward-compatible graded judgments (1–3), nDCG@k, duplicate-judgment rejection, and one gain per judged path/chunk;
- a one-command smoke runner with machine-readable output, explicit metric floors, and same-profile baseline regression tolerances;
- a small experiment proving whether hash fusion helps or harms;
- a dependency-free corpus-trained co-occurrence PPMI model with deterministic exact model fingerprint;
- controlled vocabulary-mismatch judgments where lexical fails and PPMI can succeed;
- a provider protocol for batched document and query embeddings;
- an optional pinned neural adapter, loaded lazily, with conformance probes and exact runtime/model identity.

Never describe authored diagnostic data as representative. Save raw judgments and evaluation output. Record regressions even when they contradict the intended architecture.
```

## Phase 3 — Zig core and persistent generation

```text
Pin one Zig version and implement the durable engine path while preserving Python-observable ranking semantics.

Implement in stages:
1. ASCII analyzer contract, BM25 contribution, exact cosine, RRF, deterministic channel ties, top_k/candidate_k.
2. Inverted dictionary/postings whose scores match the Python/scan oracle.
3. Versioned checksummed document/vector records with stable ids and citations.
4. A separate versioned lexical section containing document lengths, dictionary metadata, document frequency, and postings.
5. A manifest binding generation, filenames, sizes, counts, checksums, analyzer id, and embedding identity.
6. Atomic publication of generation-unique sections followed by manifest replacement.
7. Exclusive writer lock and conservative recovery scan.
8. Engine open/query/evidence APIs using caller-owned bounded workspaces.

Add corruption, capacity, backward-compatibility, and end-to-end round-trip tests. Ensure the root test harness explicitly references every module so its test blocks really execute. Record any first failing full-suite test and its correction.
```

## Phase 4 — language bridge and agent-ready service

```text
Connect the Python files/embedding side to the persisted Zig query engine.

Implement:
- a versioned neutral JSON interchange schema;
- Python export of analyzer/model metadata, citations, vectors, and chunks;
- Zig bounded validation, import, lexical construction, and atomic publication;
- a Zig newline-delimited JSON-RPC service for search/read/list/status;
- explicit query-vector dimension validation below the service boundary;
- a text-only Python gateway that loads the exact index provider, verifies the Zig snapshot identity at startup, embeds vector/hybrid queries, and forbids caller-supplied vectors;
- live process tests showing exact lexical and semantic vocabulary-mismatch results with citations;
- fail-closed startup for a mismatched model instance.

Keep embedding inference outside the Zig engine. Preserve structured error behavior and document the trust boundary.
```

## Phase 5 — authorization and incremental updates

```text
Add one canonical all-required-label authorization policy and content-hash incremental preparation.

Authorization requirements:
- safe path-prefix rules union canonical required labels;
- persist labels in Python, interchange, and a backward-readable Zig record version;
- filter forbidden documents before lexical/vector ranks and RRF;
- apply the same principal to list_sources and read_chunk;
- denied and unknown ids return the same not-found response;
- the LLM-facing gateway rejects caller principal fields and injects trusted labels;
- bound raw service label count and memory.

Incremental requirements:
- store root, chunker contract, source SHA-256 values, vector mode, and exact model identity;
- fail closed when a previous index is incompatible;
- reuse unchanged chunks/vectors, batch only changed/new neural chunks, remove deleted files;
- skip empty embedding batches;
- explicitly report stale retention for transient read failures;
- keep complete immutable Zig publication until measured write/freshness evidence justifies delta segments.

Test cross-channel isolation, principal forgery, change/add/delete, ACL-only relabeling, no-change provider calls, model mismatch, PPMI retraining, and stale files.
```

## Phase 6 — scale measurement and justified optimization

```text
Build reproducible benchmarks before selecting scale features.

Relevance harness:
- commit a tiny dependency-free graded fixture that runs in CI and proves evaluator/gate mechanics only;
- add a deterministic adapter for a separately downloaded public judged dataset such as WANDS;
- bind dataset version/license, seed, selection rule, product rendering, grade mapping, corpus hashes, model identity, modes, and cutoff into one profile;
- use nDCG@10 as the primary graded metric and retain MRR@10, success@10, macro recall@10, and per-query failures;
- preserve every positive for a selected query; if a requested cap makes that impossible, reduce the actual query count and report requested versus actual counts;
- compare lexical, semantic, and hybrid modes on the identical profile; never call hash vectors semantic or compare sampled scores to full-dataset published scores;
- persist and reuse expensive neural indexes so repeated evidence runs do not re-embed an unchanged corpus;
- record the first failed representation and its correction rather than keeping only the best run.

Python harness:
- generate 100, 1,000, and 5,000 one-chunk files outside measured time;
- measure full and unchanged builds without vectors;
- measure full and unchanged synthetic 384-dimensional vector handling;
- report artifact bytes, reused chunks, and embedding-call counts;
- state clearly that synthetic vectors exclude model inference.

Zig harness:
- exercise the real postings + exact vector + ranks + RRF query path;
- force all documents to be candidates;
- report min, p50, p95, max, lexical-stage p50, and ranking-stage p50;
- use a release build and save raw JSON.

Inspect source complexity and identify the measured hot stage. Implement one bounded optimization, rerun the identical benchmark, verify deterministic rank/cutoff behavior, and document baseline, failed intermediate attempts, final result, limitations, and rollback rationale. Do not introduce ANN, WAND, quantization, deltas, or sharding unless the corresponding measured budget fails.
```

## Phase 7 — final reconstruction audit

```text
Audit the completed recreation against docs/recreation/specification.md.

Produce:
- a requirement-by-requirement pass/partial/fail matrix with file and test evidence;
- exact Python and Zig executed test counts;
- fresh lexical, semantic, authorization, incremental, import/restart, and scale smoke results;
- confirmation that caches, model files, local indexes, and build outputs are ignored;
- a documentation link check;
- a clean PROJECT-STATE.md with resume commands, known limits, choices still needed, and one best next experiment;
- a concise README measured-status section that labels diagnostic and synthetic evidence.

Do not fill gaps with claims. Mark missing functionality explicitly and preserve it in the roadmap.
```

# Project state and continuation handoff

Last updated: 2026-07-12

Project: **Search Simpli** (`search-simpli`)

## Goal

Build toward a search solution that begins with files/folders and an LLM-friendly tool boundary, then evolves into a ground-up Zig hybrid lexical/semantic indexing platform.

## Current state

- The workspace began empty and is now a Git repository on `main`, published at `github.com/ilamgumaran/search-simpli`.
- A dependency-free Python behavioral reference is runnable.
- The reference scans selected UTF-8 text/source formats, makes cited chunks, calculates BM25, supports an offline vector channel, fuses by RRF, filters by path prefix, and emits an LLM evidence envelope.
- A Zig 0.16.0 in-memory retrieval core implements ASCII analysis, corpus-level BM25, exact cosine scoring for supplied vectors, independent candidate ranks, candidate cutoffs, RRF, deterministic top-k, and component explanations.
- Zig also has a versioned, checksummed immutable document/vector segment with caller-owned encoding/decoding and a golden ranking round trip.
- An in-memory inverted term dictionary and postings index calculates BM25 without scanning non-matching documents, then feeds the shared hybrid fusion path. Integrated golden tests cover segment decode through final ranking.
- A separate `HYBLEX01` immutable lexical section persists document lengths, dictionary terms/ranges, document frequency, and postings. Decoding it reproduces BM25 and final hybrid ordering without re-tokenizing stored text.
- `HYBMAN01` binds document/vector and lexical sections by generation, filenames, byte lengths, internal checksums, counts, analyzer id, and embedding model id.
- Filesystem publication syncs and atomically links generation-unique sections, then atomically replaces `MANIFEST`. Loading a published generation through both decoders and querying it is covered by integration tests.
- `WRITER.LOCK` provides advisory exclusive publication serialization. A recovery scanner reports current, unreferenced document/lexical, and unknown files without unsafe deletion.
- Current document segments are v3 and persist source path/start/end lines plus canonical required labels; the reader remains compatible with v1/v2 records.
- `Engine.open/query/evidence` turns a loaded published snapshot into cited lexical+semantic+RRF results using only caller-owned workspaces.
- Zig `Service` and JSON-RPC layers expose `search_knowledge`, scoped `read_chunk`, `list_sources`, and `index_status`. `searchd init-demo` publishes a snapshot and `searchd serve` runs the live stdin/stdout process.
- Query vectors are explicit for vector/hybrid RPC calls and validated against manifest dimensions; `candidate_k` is explicit and bounded.
- A versioned neutral interchange exports Python chunks, citations, vectors, analyzer id, and model id. `searchd import-json` validates it, builds both Zig sections, and atomically publishes a queryable generation.
- `embed_query.py` reproduces query vectors from the exact model stored in a Python index. In the live cross-language test, Zig imported 5 PPMI documents with 34 dimensions and returned `target/automobile.md:1-2` at vector rank 1 for `car`.
- Corpus-trained models now use a deterministic SHA-256 instance fingerprint, not only the `cooccurrence-ppmi-v1` family label. Legacy reference indexes derive it on load.
- `zig_gateway.py` exposes text-only agent/tool requests, verifies model fingerprint and dimensions against Zig status at startup, injects vectors for semantic modes, passes lexical/read/list/status through, and forbids callers from overriding vectors.
- Live gateway requests returned `automobile` for `car`, `physician` for `doctor`, and exact lexical evidence for `automobile`. A different folder model was rejected before serving with exit code 2.
- An optional provider-neutral neural path now batches document and query embeddings separately. The first adapter pins FastEmbed 0.8.0 with `BAAI/bge-small-en-v1.5`, validates a 384-dimensional conformance fingerprint, and keeps the base mode dependency-free.
- The 20-query mixed-domain diagnostic measured success@1 of 0.60 for BM25, 0.70 for PPMI vector, 0.90 for neural vector, and 0.85 for equal-weight neural RRF. At k=3 neural vector and hybrid both reached 1.0 success; vector MRR was higher.
- A neural snapshot completed the full Python → interchange → Zig generation 3 → gateway path. Live `car` and `doctor` queries returned the cited `automobile` and `physician` passages from 384-dimensional vectors.
- Path rules now assign canonical all-required access labels. Python and Zig filter both retrieval channels before ranks, then enforce the same principal on source listing and chunk reads. The gateway injects trusted labels and rejects caller forgery.
- `HYBSEG01` v3 persists required labels while reading v1/v2 as unlabeled/public. A live generation-4 run proved anonymous, tenant, and engineering views across search/list/read.
- Reference indexes now record chunker identity and per-file SHA-256 hashes. Compatible incremental builds reuse unchanged extraction/vectors, relabel ACL-only changes, remove deleted files, preserve transiently unreadable prior files as reported stale data, and embed only changed/new neural chunks.
- A real BGE update reused 11/13 files, embedded only two changed/new chunks, removed one deleted path, and published the complete result as Zig generation 5. The new rollback passage ranked first in Python and Zig.
- A reproducible files/folders scale harness now measures full and unchanged Python builds, vector movement, embedding-call avoidance, and JSON artifact size. At 5,000 one-chunk Markdown files, no-vector preparation took 591.6 ms/3.31 MB; synthetic 384-dimensional preparation took 4.54 s/10.98 MB, while unchanged preparation took 2.02 s and embedded zero chunks.
- A real Zig engine benchmark now reports total, lexical, and ranking p50/p95 timings. It exposed quadratic rank assignment as the first query bottleneck: hybrid p50 at 8,000 exhaustive 32-dimensional candidates was 174.6 ms.
- An allocation-free heap-sort rewrite improved complexity but still spent 43.0 ms median in ranking at 8,000 candidates. Deterministic in-place pdq ordering reduced the equivalent final p50 to 0.417 ms and continued to 1.69 ms at 32,000 candidates. Raw before/intermediate/after evidence and limits are preserved.
- A recreation kit now preserves the objective, executable functional/non-functional specification, acceptance gates, and staged coding-agent prompts. A use-case library provides a durable catalog, contribution template, and initial personal-files, codebase-agent, and authorized-team scenarios.
- Python and Zig now share the `candidate_k >= top_k` fusion-depth rule. A live Zig request with `candidate_k=2` returned `hybrid-guide` with both component ranks equal to 2.
- The root test harness explicitly loads every engine module; 57/57 Zig tests actually execute and pass using the temporary official toolchain. Live process tests cover Python export, Zig import/publication, semantic query, and principal-isolated authorization.
- A local JSON-lines tool process exposes `search_knowledge`, `read_chunk`, `list_sources`, and `index_status` for an LLM/skill/agent wrapper.
- Retrieval can run as lexical-only, vector-only, or hybrid. Evaluation suite v2 adds graded 1–3 judgments and nDCG@k while retaining recall@k, success@k, MRR, returned paths, matched grades, and per-query failures. Version 1 binary suites remain supported.
- `relevance_smoke.py` binds corpus hashes, suite, model identity, modes, and cutoff into a profile id; it enforces explicit floors or same-profile baseline tolerances. The 10-product/4-query dependency-free fixture scores 1.0 on nDCG@10, MRR@10, success@10, and macro recall@10 and runs in CI.
- Expensive smoke profiles can save a newly built index and reuse it later; prebuilt reuse validates the corpus root and reconstructs the exact neural provider identity before semantic evaluation.
- A deterministic WANDS adapter downloads no external data into the repository. A requested 10,000-product/1,000-query cap honestly produced 10,000 products and 47 queries because WANDS has only 480 queries and the sample preserves every Exact/Partial product for each retained query.
- The corrected one-product/one-chunk WANDS lexical run scored nDCG@10 0.6866, MRR@10 0.8574, success@10 0.9149, and macro recall@10 0.0528. The failed first representation produced 41,377 chunks and nDCG@10 0.5562 because duplicate chunks consumed result slots; both raw runs are preserved.
- A 500-product/11-query WANDS neural profile completed with nDCG@10 lexical/vector/hybrid of 0.4176/0.4550/0.4287. BGE vector improved every aggregate over lexical; equal-RRF improved nDCG, success, and recall but regressed MRR and underperformed vector-only. Neural construction took 313.4 seconds while three-mode evaluation took 0.934 seconds. Larger 10k and 2k neural attempts were stopped after exceeding an interactive smoke duration.
- The dependency-free Python suite now executes 61/61 tests; the pinned Zig suite executes 57/57 tests.
- The first judged run showed hash-vector hybrid retrieval regressing from 1.0 to 0.5 at `k=1`, so new indexes default to no vectors; hash mode is explicit test-only behavior.
- A dependency-free `cooccurrence-ppmi-v1` distributional model provides real corpus-trained semantic vectors. On two controlled vocabulary-mismatch queries, lexical scored 0.0 and vector/hybrid scored 1.0 at `k=1`; this is synthetic evidence, not a modern embedding benchmark.
- There is no representative user-derived judged corpus, authenticated identity/token adapter, label-aware BM25 statistics, directory-sync backend, reader-safe generation GC, WAL/delta-segment writer, filesystem watcher, MCP/network adapter, or direct LLM generation call yet. WANDS is real-label product-domain evidence but the 10k capped profile is biased and not score-comparable to full WANDS. Incremental preparation still publishes a complete Zig snapshot. Scale evidence is synthetic and does not yet cover 384-dimensional Zig queries, persisted startup/memory, or concurrency.

## Important decisions

1. Retrieval and generation remain separate.
2. Python is the behavioral/evaluation reference; Zig is the durable engine path.
3. Embedding inference starts outside the Zig engine.
4. BM25 and vector candidates are retrieved independently and fused with RRF.
5. Citations, authorization scope, and embedding/index versions are first-class data.
6. Complexity such as HNSW, WAND, quantization, or sharding requires benchmark evidence.

## Resume commands

```sh
cd /Users/ilam/workspace/search-platform-exploration
python3 -m unittest discover -s tests -v
python3 search.py index fixtures/knowledge --out .search/index.json
python3 search.py context .search/index.json "How should hybrid search combine results?"
python3 knowledge_tools.py .search/index.json
python3 evaluate.py .search/index.json fixtures/judgments.json --top-k 1
python3 relevance_smoke.py fixtures/relevance-smoke/corpus \
  fixtures/relevance-smoke/judgments.json --mode lexical --top-k 10 \
  --min-ndcg 1 --min-mrr 1 --min-recall 1 --min-success 1
python3 scripts/prepare_wands_smoke.py /tmp/WANDS/dataset \
  /tmp/search-simpli-wands-10k --max-products 10000 --max-queries 1000
python3 benchmark_scale.py --sizes 100 1000 5000 --dimensions 384
python3 search.py index fixtures/semantic-knowledge --vector-mode cooccurrence --out /tmp/python-index.json
python3 search.py index fixtures/semantic-knowledge --vector-mode cooccurrence \
  --incremental-from /tmp/python-index.json --out /tmp/python-index-next.json
python3 export_zig.py /tmp/python-index.json --generation 1 --out /tmp/zig-snapshot.json
python3 embed_query.py /tmp/python-index.json car
python3 zig_gateway.py /tmp/python-index.json /tmp/search-snapshot

# Optional neural environment after installing fastembed==0.8.0:
.search/fastembed-env/bin/python search.py index fixtures/mixed-knowledge \
  --vector-mode neural --model-cache .search/models --out /tmp/mixed-neural-index.json
.search/fastembed-env/bin/python evaluate.py /tmp/mixed-neural-index.json \
  fixtures/mixed-judgments.json --top-k 3 --model-cache .search/models
```

If `/tmp/zig-aarch64-macos-0.16.0` still exists:

```sh
cd /Users/ilam/workspace/search-platform-exploration/zig
/tmp/zig-aarch64-macos-0.16.0/zig build \
  --global-cache-dir /tmp/zig-global-cache \
  --cache-dir /tmp/search-zig-test-cache test

/tmp/zig-aarch64-macos-0.16.0/zig build run -- \
  import-json /tmp/search-snapshot /tmp/zig-snapshot.json

/tmp/zig-aarch64-macos-0.16.0/zig build -Doptimize=ReleaseFast
./zig-out/bin/searchd benchmark 8000 32 51 hybrid
```

Otherwise repeat the official download commands in `EXPERIMENTS.md`, or install Zig 0.16.0 and run `zig build test`.

## Best next step

Complete the real-label relevance sequence before making production claims:

1. Use persisted neural-index reuse to run a larger identical WANDS lexical/BGE/equal-RRF profile and preserve per-query wins/losses.
2. Run full 42,994-product/480-query WANDS or document why a capped profile is sufficient for a specific decision.
3. Add a second domain or a representative user folder with independently authored held-out queries.
4. Set regression tolerances from repeated profiles/seeds, then evaluate weighted fusion or reranking against the frozen baseline.

This experiment determines whether semantic retrieval produces enough value on the real corpus to justify the vector infrastructure.

In parallel, the next self-contained scale milestone is a persisted 384-dimensional benchmark covering snapshot bytes, open/startup time, resident memory, and concurrent long-lived queries. That evidence decides whether the next engine feature should be candidate-union fusion, ANN, lexical pruning, or only better process/service management.

## Choices still needed

- corpus type: personal documents, source repositories, mixed, or another domain;
- embedding preference: local/private versus hosted;
- LLM preference and whether generation may send retrieved content to a hosted service;
- target scale and freshness: approximate files/chunks, update rate, and latency goal;
- initial interface: CLI, local HTTP API, or MCP-compatible tool adapter.

These choices do not block the current reference. They materially affect E005B and the service boundary.

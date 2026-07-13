# Search Simpli

**Search from first principles—from local files and LLM tools to scalable hybrid retrieval in Zig.**

Search Simpli (`search-simpli`) explores one search product with two deliberately different operating modes:

1. **Local knowledge mode** — index files and folders, retrieve cited passages, and hand a compact evidence pack to an LLM acting through a tool or agent.
2. **Search platform mode** — evolve the same contracts into a Zig service with persistent lexical and vector indexes, hybrid ranking, filters, observability, and horizontal scaling.

The important boundary is retrieval versus generation. Search finds and cites evidence. An LLM may synthesize an answer from that evidence, but it must not silently become the source of truth.

## Run the local vertical slice

The prototype has no third-party dependencies and works with Python 3.11+.

```sh
python3 search.py index fixtures/knowledge --out .search/index.json
python3 search.py query .search/index.json "How should hybrid search combine results?"
python3 search.py context .search/index.json "How should hybrid search combine results?"
python3 -m unittest discover -s tests -v
```

Run the same index as a local agent/LLM tool process:

```sh
python3 knowledge_tools.py .search/index.json
```

Compare retrieval modes against relevance judgments:

```sh
python3 evaluate.py .search/index.json fixtures/judgments.json --top-k 1

python3 relevance_smoke.py \
  fixtures/relevance-smoke/corpus \
  fixtures/relevance-smoke/judgments.json \
  --mode lexical --top-k 10 \
  --min-ndcg 1 --min-mrr 1 --min-recall 1 --min-success 1
```

Carry a real files-and-folders snapshot across the language boundary:

```sh
python3 search.py index fixtures/semantic-knowledge --vector-mode cooccurrence --out /tmp/python-index.json
python3 export_zig.py /tmp/python-index.json --generation 1 --out /tmp/zig-snapshot.json
cd zig
zig build run -- import-json /tmp/search-snapshot /tmp/zig-snapshot.json
zig build run -- serve /tmp/search-snapshot
```

Run the LLM/agent-facing gateway so callers send text rather than vectors:

```sh
cd ..
python3 zig_gateway.py /tmp/python-index.json /tmp/search-snapshot
```

The gateway fingerprints the exact trained model, verifies it against Zig `index_status`, embeds vector/hybrid queries, and rejects caller-supplied or mismatched vectors. `embed_query.py` remains a useful diagnostic for inspecting that model boundary directly.

Run the persisted Zig engine as the same style of tool process:

```sh
cd zig
zig build run -- init-demo /tmp/searchd-demo
zig build run -- serve /tmp/searchd-demo
```

`query` is human-readable. `context` emits the JSON evidence envelope intended for a model tool call. Every result includes a stable chunk id, file path, line range, content, and component ranking details.

The safe default is `vector_mode=none`, so hybrid queries behave lexically until a real embedding channel exists. The opt-in `--vector-mode hash` projection exercises vector storage, cosine scoring, and fusion offline; it is **not a semantic embedding model** and has already been observed to reduce relevance. Replace it through the embedding boundary described in [the architecture](docs/architecture.md) before evaluating semantic relevance.

For a dependency-free ground-up semantic experiment, use `--vector-mode cooccurrence`. It trains a PPMI distributional model from the indexed corpus and records its model metadata. It is useful theory made executable, but remains a small-corpus baseline rather than a pretrained neural model.

For the optional local neural path, install `fastembed==0.8.0` in a separate environment and run:

```sh
python3 search.py index ./knowledge --vector-mode neural \
  --model BAAI/bge-small-en-v1.5 \
  --model-cache .search/models \
  --out .search/neural-index.json
```

The base project remains dependency-free. Neural mode uses separate passage/query embeddings, records a runtime/model conformance fingerprint, and fails closed if the query provider does not match the index.

For shared folders, assign required labels by path and configure the tool/gateway principal outside LLM-controlled requests:

```sh
python3 search.py index ./knowledge --access-rules access-rules.json --out .search/index.json
python3 knowledge_tools.py .search/index.json --principal-label tenant:acme
```

The same principal filters lexical candidates, vector candidates, source lists, and chunk reads. Unlabeled documents remain the zero-configuration personal/local option.

Reuse unchanged extraction and vectors while still publishing a complete immutable snapshot:

```sh
python3 search.py index ./knowledge \
  --incremental-from .search/index.previous.json \
  --out .search/index.next.json
```

The build report distinguishes reused, changed, added, deleted, stale, relabeled, and newly embedded work.

Measure the current simple and durable paths before adding scale machinery:

```sh
python3 benchmark_scale.py --sizes 100 1000 5000 --dimensions 384
cd zig
zig build -Doptimize=ReleaseFast
./zig-out/bin/searchd benchmark 8000 32 51 hybrid
```

## Measured status

Recorded locally on 2026-07-12. These are diagnostic baselines, not production capacity promises.

| Area | Result |
|---|---|
| Automated validation | 61/61 Python tests, dependency-free graded relevance smoke, and 57/57 Zig tests pass |
| WANDS sampled lexical relevance (10,000 products, 47 queries) | nDCG@10 0.6866; MRR@10 0.8574; success@10 0.9149; macro recall@10 0.0528 |
| WANDS sampled neural comparison (500 products, 11 queries) | nDCG@10: lexical 0.4176, BGE vector 0.4550, equal-RRF hybrid 0.4287; neural build 313.4 s |
| Mixed-domain success@1 (20 authored queries) | BM25 0.60; PPMI vector 0.70; BGE vector 0.90; equal-RRF BGE hybrid 0.85 |
| Python build, 5,000 small one-chunk files | No vectors: 591.6 ms and 3.31 MB JSON |
| Python synthetic 384-d build, 5,000 chunks | Full: 4.54 s and 10.98 MB JSON; unchanged: 2.02 s and zero embedding calls |
| Zig hybrid query, 8,000 exhaustive 32-d candidates | p50 0.417 ms; p95 0.456 ms after the ranking fix |
| Zig ranking improvement at 8,000 candidates | p50 174.6 ms to 0.417 ms, about 418x |
| Zig hybrid query, 32,000 exhaustive 32-d candidates | p50 1.69 ms; p95 2.13 ms |

The Python vector benchmark uses a synthetic provider, so it measures indexing, vector movement, reuse, and serialization—not neural inference. The Zig query benchmark uses equal-score synthetic documents and 32 dimensions. See [the scale benchmark](docs/scale-benchmark.md) and raw [Python](benchmarks/python-scale-2026-07-12.json) / [Zig](benchmarks/zig-ranking-scale-2026-07-12.json) results for methodology and limitations.

## Direction

- [Documentation index](docs/README.md)
- [Requirements register (all requirements in one place)](docs/requirements/README.md)
- [Capability process (how to add a new capability)](docs/capability-process.md)
- [Improvement board (shared human + agent backlog)](IMPROVEMENT-BOARD.md)
- [The learning loop: search that improves from use](docs/learning-loop.md)
- [Objective, specification, and prompts for recreating Search Simpli](docs/recreation/README.md)
- [Use-case library and contribution template](docs/use-cases/README.md)
- [Architecture and option comparison](docs/architecture.md)
- [Search and answer theory](docs/theory.md)
- [Experiment-driven roadmap](docs/roadmap.md)
- [Experiment ledger](EXPERIMENTS.md)
- [Continuation state](PROJECT-STATE.md)
- [Shared search tool schema](contracts/search-tool.schema.json)
- [Why Zig and where it belongs](docs/decisions/0001-zig-engine-boundary.md)
- [Zig in-memory hybrid engine](zig/README.md)
- [Immutable Zig segment format v1](docs/segment-format-v1.md)
- [Citation-bearing Zig segment format v2](docs/segment-format-v2.md)
- [Authorization-bearing Zig segment format v3](docs/segment-format-v3.md)
- [Immutable Zig lexical segment format v1](docs/lexical-segment-format-v1.md)
- [Generation manifest format v1](docs/manifest-format-v1.md)
- [Atomic publication and recovery protocol](docs/publication-recovery.md)
- [Writer locking and conservative generation lifecycle](docs/generation-lifecycle.md)
- [Loaded Zig engine query/evidence API](docs/zig-engine-api.md)
- [Live Zig JSON-RPC tool service](docs/zig-rpc-service.md)
- [Inverted postings design and verified invariants](docs/postings-design.md)
- [Local LLM/agent tool protocol](docs/tool-protocol.md)
- [Judged-query evaluation and first observed regression](docs/evaluation.md)
- [Product-search relevance benchmark, WANDS adapter, and smoke gate](docs/relevance-benchmark.md)
- [Recorded WANDS 10k lexical relevance run](benchmarks/wands-10k-lexical-2026-07-12.json)
- [Recorded WANDS 500-product neural/hybrid run](benchmarks/wands-500-neural-hybrid-2026-07-12.json)
- [Ground-up PPMI distributional semantic baseline](docs/cooccurrence-semantics.md)
- [Python-to-Zig indexing and query-model bridge](docs/python-zig-bridge.md)
- [Automatic query-embedding gateway and scale options](docs/query-embedding-gateway.md)
- [Local neural embedding provider and measured comparison](docs/neural-embedding-provider.md)
- [Recorded mixed-domain diagnostic benchmark](benchmarks/mixed-diagnostic-2026-07-11.json)
- [Pre-retrieval authorization theory, implementation, and limits](docs/authorization.md)
- [Incremental reuse and full/delta publication options](docs/incremental-indexing.md)
- [Measured Python indexing and Zig query scaling](docs/scale-benchmark.md)
- [Recorded Python files/folders scale run](benchmarks/python-scale-2026-07-12.json)
- [Recorded Zig ranking before/after run](benchmarks/zig-ranking-scale-2026-07-12.json)

The Python prototype is a behavioral reference, not intended to become the production server. Its JSON contract and ranking tests are the pieces worth preserving.

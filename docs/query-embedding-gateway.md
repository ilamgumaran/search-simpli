# Query-embedding gateway

Status: implemented for both the corpus-trained PPMI provider and an optional local FastEmbed/BGE neural provider over the persisted Zig JSON-RPC engine.

## Purpose

An LLM, skill, or agent should call search with human text. It should not know vector dimensions, serialize floating-point arrays, or choose an embedding model independently from the index. Those responsibilities belong at a trusted boundary between the tool protocol and the retrieval engine.

`zig_gateway.py` preserves the public operations—`search_knowledge`, `read_chunk`, `list_sources`, and `index_status`—while owning query-vector construction for vector and hybrid search.

```text
LLM / skill / agent
  search_knowledge(query, mode, scope, top_k)
                 |
                 v
embedding gateway
  1. read Zig index_status at startup
  2. compare exact model fingerprint and dimensions
  3. embed vector/hybrid query text
  4. reject caller-supplied vectors
  5. forward to the persisted Zig engine
                 |
                 v
Zig lexical + vector retrieval -> cited evidence
```

Lexical requests and non-search operations pass through without embedding. This keeps exact search available even when a vector provider is intentionally absent in a zero-dimensional snapshot.

## Exact model identity

Dimensions are necessary but not sufficient for vector compatibility. Two independently trained PPMI models can have equal dimensions while assigning different terms to vector axes and learning different weights.

Each trained model now has two identities:

- `model_family`: `cooccurrence-ppmi-v1`, the algorithm and parameter contract;
- `model_id`: the family plus a SHA-256 fingerprint of the canonical vocabulary, dimensions, window, and learned word vectors.

The interchange writes the exact `model_id` into the Zig manifest. At gateway startup, Python asks Zig for `index_status` and requires both model id and dimensions to match. A mismatch stops startup with exit code 2. Legacy Python PPMI indexes that only contain the family label derive the fingerprint when loaded; their Zig snapshots must be rebuilt if they used the old weak identifier.

## Run it

Build and publish a snapshot as described in [the bridge](python-zig-bridge.md), then from the repository root run:

```sh
python3 zig_gateway.py /tmp/python-index.json /tmp/search-snapshot
```

If Zig is not installed globally:

```sh
python3 zig_gateway.py /tmp/python-index.json /tmp/search-snapshot \
  --zig /tmp/zig-aarch64-macos-0.16.0/zig \
  --zig-cache-dir /tmp/search-zig-gateway-cache \
  --zig-global-cache-dir /tmp/zig-global-cache
```

The caller sends ordinary newline-delimited JSON-RPC without a vector:

```json
{"jsonrpc":"2.0","id":1,"method":"search_knowledge","params":{"query":"car","retrieval_mode":"vector","path_prefix":"target/","top_k":1,"candidate_k":1}}
```

The result remains the shared cited evidence envelope. A caller-provided `query_vector` is rejected because allowing it would bypass model routing and make the trust boundary ambiguous.

## Observed behavior

Against the five-document semantic fixture:

- text-only vector query `car` returned `target/automobile.md:1-2` at vector rank 1;
- text-only hybrid query `doctor` returned `target/physician.md:1-2` at vector rank 1;
- lexical query `automobile` returned the exact passage at lexical rank 1 without embedding;
- a different folder's PPMI model was rejected before tool traffic because its fingerprint and dimensions did not match;
- a missing snapshot manifest caused startup failure rather than an empty or unverified service.

## Provider options

The gateway establishes a provider seam without forcing model inference into Zig:

1. **Smallest/local:** load the dependency-free PPMI model from the Python index, as implemented now. Good for learning and offline controlled tests.
2. **Local neural sidecar:** implemented initially with FastEmbed 0.8.0 and `BAAI/bge-small-en-v1.5`. This keeps document/query text local but introduces model files, batching, and runtime operations.
3. **Hosted embeddings:** call a versioned API. This reduces local runtime work but requires credentials, data-egress policy, retries, rate limits, and cost controls.
4. **Embedded runtime later:** link a proven inference runtime behind a stable ABI only if measurements show process boundaries dominate latency. Zig should continue to own index compatibility and retrieval, not model-specific tokenization by accident.

Every provider must return a stable model identity, dimensions, finite vectors, and an explicit failure. Model rotation should build a new immutable index generation and switch query routing atomically; document vectors from one model must never be searched with query vectors from another.

## Scale path

The current gateway is synchronous and single-process. Scale it only after measuring:

- pool long-lived Zig readers instead of starting a build/run child per gateway;
- batch concurrent embedding calls where the provider benefits;
- bound request size, response evidence, queue depth, and deadlines;
- expose latency and failure metrics separately for embedding, lexical retrieval, vector retrieval, and fusion;
- authenticate a scope and translate it into pre-retrieval authorization filters;
- route by immutable generation plus model fingerprint during model migration;
- avoid caching sensitive raw queries unless policy explicitly permits it.

The pinned local provider and a 20-query diagnostic are now complete. The next relevance gate remains a representative user-derived judged corpus with a held-out evaluation split. The gateway proves orchestration and compatibility, not production semantic quality.

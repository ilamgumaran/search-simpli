# Optional local neural embedding provider

Status: implemented, benchmarked on a 20-query diagnostic corpus, and exercised through persisted Zig search.

## Selected first provider

The first modern semantic option is:

- runtime: `fastembed==0.8.0`;
- model family: `BAAI/bge-small-en-v1.5`;
- execution: local ONNX Runtime on CPU;
- vector dimensions: 384;
- model license: MIT;
- provider cache: explicit local directory, `.search/models` by default.

FastEmbed was selected because its maintained implementation is designed around lightweight ONNX inference rather than requiring a full PyTorch installation, exposes separate query and passage embedding calls, and supports this BGE model directly. See the [FastEmbed documentation](https://qdrant.github.io/fastembed/), [FastEmbed 0.8.0 release](https://pypi.org/project/fastembed/0.8.0/), and [BGE model card](https://huggingface.co/BAAI/bge-small-en-v1.5).

This is an initial benchmark choice, not a claim that BGE-small is universally best. Multilingual data, long documents, code, domain terminology, hardware, licensing policy, or a hosted-service preference may justify a different provider.

## Dependency boundary

The base search project remains Python-standard-library-only. Neural mode is optional:

```sh
python3 -m venv .search/fastembed-env
.search/fastembed-env/bin/python -m pip install fastembed==0.8.0

.search/fastembed-env/bin/python search.py index ./knowledge \
  --vector-mode neural \
  --model BAAI/bge-small-en-v1.5 \
  --model-cache .search/models \
  --out .search/neural-index.json
```

The model is downloaded on first use. Indexing calls `passage_embed`; search calls `query_embed`. Every vector is checked for count, dimensions, finite values, and L2-normalized before storage or scoring.

The Python `EmbeddingProvider` protocol is batch-oriented:

```text
metadata -> exact model identity, family, dimensions, normalization, provider config
embed_documents([text...]) -> [vector...]
embed_queries([text...])   -> [vector...]
```

The language-neutral shape is recorded in `contracts/embedding-provider.schema.json`. A future hosted or separate local provider can implement that process contract without changing Zig segments or ranking.

## Reproducible model identity

A model name and dimension count do not prove that two runtimes produce compatible vectors. On initialization, the adapter embeds fixed query and passage probes and hashes:

- conformance protocol version;
- FastEmbed runtime version;
- model family;
- probe text and resulting float32 vectors.

The resulting identifier in this run was:

```text
fastembed-0.8.0-BAAI/bge-small-en-v1.5-sha256-5a374383942f282a09d4eb4674b187c5f5ee3a046f5457659e183bb2cb1dfcd5
```

That id is stored in the Python index, neutral interchange, and Zig manifest. The gateway re-runs the probes and rejects a mismatch before serving. This is intentionally strict: a tokenizer, weights, pooling, or numerically significant runtime change requires a new immutable index generation.

The model cache path is part of reproducible operation even though it is not part of the portable index metadata. An evaluation run pointed at an empty default cache attempted network model discovery and failed offline; using the same populated cache succeeded. Production deployments should pre-stage verified model artifacts rather than downloading during service startup.

## Diagnostic benchmark

The checked-in corpus has 13 small documents across search, storage, agent safety, operations, programming languages, medicine, transport, cooking, and astronomy. Twenty judgments use paraphrases and exact concepts. It is broader than the two-query mechanics fixture but is still curated diagnostic data—not representative user evidence.

| System and mode | Success@1 | MRR@1 | Success@3 | MRR@3 |
|---|---:|---:|---:|---:|
| BM25 lexical | 0.60 | 0.60 | 1.00 | 0.775 |
| PPMI vector | 0.70 | 0.70 | 0.95 | 0.800 |
| PPMI equal RRF | 0.60 | 0.60 | 0.95 | 0.750 |
| BGE neural vector | **0.90** | **0.90** | **1.00** | **0.950** |
| BGE neural equal RRF | 0.85 | 0.85 | 1.00 | 0.925 |

The raw recorded result is `benchmarks/mixed-diagnostic-2026-07-11.json`.

### Interpretation

The neural model materially improved top-1 paraphrase retrieval in this diagnostic. Corpus-only PPMI helped but lacked the pretrained model's broader language prior.

Equal-weight reciprocal-rank fusion did not beat neural vector search. Two losses were symmetric rank swaps: one document was lexical rank 1/vector rank 2 and another was lexical rank 2/vector rank 1. Equal RRF assigns the same score, so deterministic id ordering—not relevance—selected the winner. This is evidence to test explicit channel weights, query routing, or reranking. It is not enough evidence to tune a default, because doing so on the same twenty authored queries would overfit the diagnostic.

## Zig proof

The neural index was exported through interchange v1 and imported by Zig as generation 3 with 5 documents, 34 lexical terms, 68 postings, and 384 vector dimensions. Through `zig_gateway.py`:

- `car` returned `target/automobile.md:1-2`, vector rank 1, cosine 0.7797;
- `doctor` returned `target/physician.md:1-2`, vector rank 1, cosine 0.7293.

This proves model inference can remain outside Zig while Zig owns persisted vectors, lexical postings, filtering, candidate ranking, fusion, and cited evidence.

## What remains unproven

- The diagnostic is not sampled from a real user's folders or questions.
- There are no graded judgments or independent assessors.
- Model download provenance is conformance-checked by output, but deployment still needs artifact pinning and supply-chain verification.
- Indexing throughput, query latency, memory, cold start, and model cache size have not been benchmarked.
- English BGE-small is not a multilingual or long-context decision.
- Equal RRF needs a held-out tuning/evaluation split before weights change.
- Changed/new neural chunks are now embedded incrementally from content hashes, while deadlines, concurrent batching, and a long-lived provider process remain.

The next credible relevance step is to sample 50–100 real questions from an explicitly selected folder corpus, split tuning from evaluation, and compare BM25, neural vector, weighted fusion, and optionally a reranker.

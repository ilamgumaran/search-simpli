# Relevance evaluation

Status: implemented in `src/search_platform/evaluation.py` with a small example suite at `fixtures/judgments.json`.

## Why this exists

Hybrid search adds machinery but does not guarantee better answers. Lexical, vector, fusion, chunking, and reranking changes must run against the same explicit relevance judgments. Otherwise a compelling individual query can hide broad regressions.

## Judgment format

```json
{
  "version": 1,
  "queries": [
    {
      "id": "stable-query-id",
      "query": "How should result lists be combined?",
      "path_prefix": "optional/scope/",
      "relevant": [
        { "path": "expected-source.md" },
        { "chunk_id": "optional-more-precise-id" }
      ]
    }
  ]
}
```

A judgment may identify a path, a stable chunk id, or both. Path judgments tolerate chunker changes; chunk-id judgments are more precise but must be migrated when content or chunk boundaries change.

## Run

```sh
python3 search.py index fixtures/knowledge --out .search/index.json
python3 evaluate.py .search/index.json fixtures/judgments.json --top-k 1
```

To exercise mechanics only:

```sh
python3 search.py index fixtures/knowledge \
  --out /tmp/search-hash-index.json \
  --vector-mode hash
python3 evaluate.py /tmp/search-hash-index.json fixtures/judgments.json --top-k 1
```

The evaluator runs lexical, vector, and hybrid by default. Repeated `--mode` selects a subset.

## Metrics

- `macro_recall_at_k`: for each query, the fraction of its judged items found in the first `k`, averaged across queries;
- `success_at_k`: fraction of queries with at least one relevant result in the first `k`;
- `mean_reciprocal_rank`: average inverse position of the first relevant result;
- per-query first relevant rank, recall, and returned chunk ids for diagnosis.

This first harness uses binary relevance. Add graded judgments and nDCG only when assessors can consistently distinguish relevance levels.

## First observed result

On the two-query fixture at `k=1`:

| Index/mode | Recall | Success | MRR |
|---|---:|---:|---:|
| no vectors, lexical | 1.0 | 1.0 | 1.0 |
| no vectors, hybrid | 1.0 | 1.0 | 1.0 |
| hash vectors, vector | 0.5 | 0.5 | 0.5 |
| hash vectors, hybrid | 0.5 | 0.5 | 0.5 |

The hash channel displaced a correct lexical top result. This is direct evidence that vector-shaped data is not semantic relevance and that fusion can make a good lexical system worse. Consequently, index creation now defaults to `vector_mode=none`; hash vectors are opt-in and every evaluation containing them emits a warning.

The corpus is far too small for general conclusions. Its purpose is to prove the harness catches a regression. The next credible run needs a representative corpus, 50–100 judgments, and real versioned embeddings.

A second controlled suite exercises the dependency-free ground-up PPMI semantic baseline; see `docs/cooccurrence-semantics.md`. It proves vocabulary-mismatch retrieval mechanics but is also explicitly synthetic.

## Twenty-query mixed-domain diagnostic

`fixtures/mixed-knowledge` and `fixtures/mixed-judgments.json` add 13 documents and 20 paraphrased queries spanning search, storage, agents, operations, systems programming, and several general domains. The exact output is saved in `benchmarks/mixed-diagnostic-2026-07-11.json`; see [the neural provider report](neural-embedding-provider.md) for the full interpretation.

At k=1, BM25 scored 0.60 success, PPMI vector 0.70, local BGE neural vector 0.90, and equal-weight neural RRF 0.85. At k=3 both neural vector and hybrid found relevant evidence for all queries, but vector-only had higher MRR. This demonstrates both pretrained semantic value and a fusion regression. It remains diagnostic rather than representative because its documents and questions were authored together for this project.

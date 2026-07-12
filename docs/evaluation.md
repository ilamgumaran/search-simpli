# Relevance evaluation

Status: binary v1 and graded v2 evaluation are implemented in
`src/search_platform/evaluation.py`. The dependency-free regression gate and
product fixture live at `relevance_smoke.py` and `fixtures/relevance-smoke/`.

## Why this exists

Hybrid search adds machinery but does not guarantee better answers. Lexical, vector, fusion, chunking, and reranking changes must run against the same explicit relevance judgments. Otherwise a compelling individual query can hide broad regressions.

## Judgment format

```json
{
  "version": 2,
  "queries": [
    {
      "id": "stable-query-id",
      "query": "How should result lists be combined?",
      "path_prefix": "optional/scope/",
      "relevant": [
        { "path": "exact-source.md", "grade": 3 },
        { "chunk_id": "optional-more-precise-id", "grade": 1 }
      ]
    }
  ]
}
```

A judgment may identify a path, a stable chunk id, or both. Path judgments
tolerate chunker changes; chunk-id judgments are more precise but must be
migrated when content or chunk boundaries change. Version 2 requires integer
grades 1–3. Version 1 remains supported as binary relevance with implicit grade
1. Duplicate judgments are rejected, and repeated chunks from one judged path
earn relevance gain only once.

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
- `mean_ndcg_at_k`: graded gain discounted by rank and normalized to the ideal
  top-k ordering;
- per-query first relevant rank, recall, nDCG, returned paths/chunks, and matched
  grades for diagnosis.

Use graded judgments only when assessors or the source dataset define consistent
levels. Never compare scores across different corpora, sampling rules, grade
mappings, or cutoffs as though they were one scale.

## Built-in relevance smoke gate

The one-command smoke runner builds an index, evaluates selected modes, writes a
machine-readable report, and exits non-zero when a floor or same-profile baseline
tolerance fails:

```sh
python3 relevance_smoke.py \
  fixtures/relevance-smoke/corpus \
  fixtures/relevance-smoke/judgments.json \
  --mode lexical --top-k 10 \
  --min-ndcg 1 --min-mrr 1 --min-recall 1 --min-success 1
```

The profile id hashes corpus source metadata, the suite, vector/model identity,
modes, and cutoff. This prevents accidentally comparing a new sample to an old
baseline. See [the product relevance benchmark](relevance-benchmark.md) for the
WANDS adapter, research basis, actual 10k result, failure examples, and limits.

## First observed result

On the two-query fixture at `k=1`:

| Index/mode | Recall | Success | MRR |
|---|---:|---:|---:|
| no vectors, lexical | 1.0 | 1.0 | 1.0 |
| no vectors, hybrid | 1.0 | 1.0 | 1.0 |
| hash vectors, vector | 0.5 | 0.5 | 0.5 |
| hash vectors, hybrid | 0.5 | 0.5 | 0.5 |

The hash channel displaced a correct lexical top result. This is direct evidence that vector-shaped data is not semantic relevance and that fusion can make a good lexical system worse. Consequently, index creation now defaults to `vector_mode=none`; hash vectors are opt-in and every evaluation containing them emits a warning.

The corpus is far too small for general conclusions. Its purpose is to prove the
harness catches a regression. A first real-label WANDS diagnostic now exists;
its capped sample is still not representative enough for a production claim.

A second controlled suite exercises the dependency-free ground-up PPMI semantic baseline; see `docs/cooccurrence-semantics.md`. It proves vocabulary-mismatch retrieval mechanics but is also explicitly synthetic.

## Twenty-query mixed-domain diagnostic

`fixtures/mixed-knowledge` and `fixtures/mixed-judgments.json` add 13 documents and 20 paraphrased queries spanning search, storage, agents, operations, systems programming, and several general domains. The exact output is saved in `benchmarks/mixed-diagnostic-2026-07-11.json`; see [the neural provider report](neural-embedding-provider.md) for the full interpretation.

At k=1, BM25 scored 0.60 success, PPMI vector 0.70, local BGE neural vector 0.90, and equal-weight neural RRF 0.85. At k=3 both neural vector and hybrid found relevant evidence for all queries, but vector-only had higher MRR. This demonstrates both pretrained semantic value and a fusion regression. It remains diagnostic rather than representative because its documents and questions were authored together for this project.

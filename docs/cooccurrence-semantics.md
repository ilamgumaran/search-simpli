# Ground-up distributional semantic baseline

Status: implemented as `vector_mode=cooccurrence` in the Python reference. Model family: `cooccurrence-ppmi-v1`; each trained corpus model receives a SHA-256 instance fingerprint.

## Theory

The distributional hypothesis says words used in similar contexts tend to have related meanings. This baseline learns from the indexed corpus itself rather than downloading a pretrained model.

For each token, the trainer counts neighboring context tokens within a four-token window. Raw counts are converted to positive pointwise mutual information:

```text
PPMI(word, context) = max(0, log(
    count(word, context) * total_context_events
    ------------------------------------------------
    count(word, *) * count(*, context)
))
```

Each vocabulary word becomes a normalized vector whose dimensions are context terms. A chunk vector is the normalized mean of its known word vectors. A query is embedded through the same model, and exact cosine similarity ranks chunks.

The vocabulary is frequency-selected and capped at 512 terms so the dependency-free dense JSON model remains bounded. Index metadata records model id, dimensions, context window, and vocabulary cap.

## What it can learn

If “car” and “automobile” repeatedly occur around “vehicle,” “wheels,” “engine,” and “road,” their context vectors become similar even though the words do not match lexically. This is genuine corpus-derived distributional similarity.

The checked-in controlled experiment trains on paired contexts and then scopes retrieval to target files where exact query words are absent:

```sh
python3 search.py index fixtures/semantic-knowledge \
  --out /tmp/search-cooccurrence-index.json \
  --vector-mode cooccurrence
python3 evaluate.py /tmp/search-cooccurrence-index.json \
  fixtures/semantic-judgments.json --top-k 1
```

Observed on two queries:

| Mode | Recall@1 | Success@1 | MRR |
|---|---:|---:|---:|
| lexical | 0.0 | 0.0 | 0.0 |
| vector | 1.0 | 1.0 | 1.0 |
| hybrid | 1.0 | 1.0 | 1.0 |

Queries “car” and “doctor” retrieved target passages containing “automobile” and “physician” respectively.

## What it cannot establish

- The corpus is synthetic and deliberately repeats matching contexts.
- Small or heterogeneous corpora produce sparse, unstable associations.
- Unknown query terms have no vector.
- Dense storage grows quadratically with selected vocabulary size.
- Word order, negation, long-range context, and polysemy are represented poorly.
- It does not carry the broad prior knowledge or language understanding of a modern neural embedding model.
- Any corpus update requires retraining chunk and query representations together.

Therefore this baseline is valuable for learning and for validating a ground-up semantic path. It is not a substitute for E005B’s representative-corpus comparison with a versioned neural embedding provider.

## Zig boundary

The model trainer may remain outside the Zig engine. Zig needs the model metadata, query vector, stored chunk vectors, exact/approximate distance, filters, candidate ranks, and fusion. This keeps the durable index independent of a specific inference runtime while still allowing a ground-up semantic algorithm to be ported later if measurements justify it.

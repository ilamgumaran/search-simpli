# Python-to-Zig indexing bridge

Status: implemented and integration-tested.

This bridge turns the exploratory files-and-folders indexer into an input for the durable Zig engine without making either runtime understand the other's private persistence format.

```text
files/folders
    -> Python extraction, chunking, and optional model training
    -> versioned interchange JSON
    -> Zig validation, tokenization, postings, and vector segments
    -> atomic generation publication
    -> Zig JSON-RPC evidence service

query
    -> the exact model recorded by the Python index
    -> dimension-checked query vector
    -> Zig lexical/vector/hybrid retrieval
    -> cited evidence for an LLM
```

## Why there are two formats

The Python index is an experiment artifact. The Zig `HYBSEG`, `HYBLEX`, and `HYBMAN` files are engine storage. Coupling Zig directly to Python's internal index JSON would make every experiment a storage migration.

The neutral interchange contract at `contracts/snapshot-interchange.schema.json` contains only the durable facts needed to construct a snapshot:

- format and generation;
- analyzer and embedding-model identities;
- stable chunk id, source path, line range, and text;
- one stored vector per chunk when a vector model is present.

Zig rebuilds lexical postings with the declared `ascii-alnum-v1` analyzer. It does not import Python term tables. This makes analyzer ownership explicit and prevents silent lexical incompatibility.

JSON is appropriate for a small, inspectable bootstrap and golden tests. A production bulk loader should eventually use a bounded streaming or binary transport while preserving the same logical contract.

## Reproduce the complete path

From the repository root:

```sh
python3 search.py index fixtures/semantic-knowledge \
  --vector-mode cooccurrence \
  --out /tmp/python-index.json

python3 export_zig.py /tmp/python-index.json \
  --generation 1 \
  --out /tmp/zig-snapshot.json

cd zig
zig build run -- import-json /tmp/search-snapshot /tmp/zig-snapshot.json
zig build run -- serve /tmp/search-snapshot
```

`embed_query.py` is the model-side boundary for queries:

```sh
python3 embed_query.py /tmp/python-index.json car
```

It loads the model parameters embedded in the index and returns `model_id`, dimensions, and the vector. The implemented [query-embedding gateway](query-embedding-gateway.md) places that vector in the Zig `search_knowledge` request. Machine generation is required: Zig rejects absent, non-finite, or dimension-mismatched vectors.

For lexical mode, no query vector is required. For vector or hybrid mode, the request vector must come from the same model identity recorded in the published snapshot. Zig validates dimensions; the gateway verifies the full trained-model fingerprint and dimensions before it accepts traffic.

## Integration result

The controlled corpus deliberately separates query vocabulary from the relevant document. Python trained the `cooccurrence-ppmi-v1` family and exported a corpus-specific fingerprint; Zig imported 5 documents, built 34 lexical terms, and published 34-dimensional vectors. An automated `car` query vector sent to Zig with scope `target/` returned:

```text
target/automobile.md:1-2
An automobile is a vehicle with wheels and an engine used for travel on a road.
vector rank: 1
```

This proves the current cross-language model/index compatibility and vocabulary-mismatch path. It does not prove relevance on a representative corpus or the quality of a modern neural embedding model.

## What failed and what it taught us

A hand-copied query-vector request was rejected as `Invalid params`; the copied array did not preserve the required shape. The same request succeeded when produced directly by `embed_query.py`. Query embeddings should therefore be transported programmatically with model id and dimension checks, not copied by people or reconstructed from display text.

That gateway is now implemented and fails closed when the model is unavailable or mismatched. The next provider increment is a pinned modern local or hosted neural model; the same boundary remains the correct place for batching, credentials, timeouts, and privacy policy.

## Remaining boundaries

- `cooccurrence-ppmi-v1` is a ground-up controlled baseline, not a modern pretrained semantic model.
- Python's Unicode-aware token behavior and Zig's ASCII analyzer are not yet equivalent; the interchange declares Zig's current analyzer rather than hiding that limitation.
- Path-prefix scope is a retrieval constraint, not authenticated authorization.
- Full JSON materialization is not suitable for very large imports.
- Content-hash preparation can now reuse unchanged extraction/vectors before exporting another complete snapshot. There is still no filesystem watcher, incremental interchange stream, tombstone segment, or reader-safe generation garbage collection.
- The LLM layer must use returned citations, treat retrieved text as untrusted data, and state when evidence is insufficient.

# Recreating Search Simpli

This kit defines how to rebuild Search Simpli from an empty repository while preserving its reasoning, safety boundaries, and experiment history—not merely its current source layout.

## Objective

Build a search system that starts with local files and folders, exposes cited evidence to an LLM through narrow tools, and can evolve into a durable Zig lexical-and-semantic indexing platform without changing its logical contracts.

The system should answer this question:

> Given a user question, what is the smallest set of authorized source passages that best supports a correct, cited answer?

Search retrieves evidence. An LLM may synthesize that evidence, but retrieval and generation remain separate so provenance, authorization, relevance, and failures stay inspectable.

## Product shape

Search Simpli has three deliberately progressive forms:

1. **Simple local reference:** dependency-free Python indexing and search over UTF-8 files, one replaceable JSON index, citations, BM25, optional vectors, RRF, and a JSON-lines tool process.
2. **Durable single node:** Zig-owned immutable lexical/vector segments, checksummed manifests, atomic generation publication, exact vector scan, deterministic hybrid ranking, and a long-lived query service.
3. **Measured scale platform:** pruning, ANN, delta segments, compaction, replication, or sharding only after a named latency, capacity, freshness, or availability target fails.

## Non-negotiable principles

- Retrieval and generation are separate.
- Every returned passage carries stable identity and a source citation.
- Authorization filters both lexical and semantic channels before ranks and fusion.
- Embedding model identity, dimensions, normalization, and chunker identity are index data.
- Exact vector scan remains the correctness oracle if approximate search is introduced.
- The base local mode remains runnable without third-party packages.
- Python is the behavioral/evaluation reference; Zig is the durable engine boundary.
- Complexity is earned by measurement, not added in anticipation.
- Tests must actually execute; compilation alone is not test evidence.
- Experiments preserve what failed and what remains unproven.

## Recreation sources

Use these in order:

1. [Executable specification](specification.md) — required behavior and acceptance gates.
2. [Recreation prompts](prompts.md) — master and phase prompts for a coding agent.
3. [Architecture](../architecture.md) and [theory](../theory.md) — design reasoning.
4. [Schemas](../../contracts/) — language-neutral boundaries.
5. [Experiment ledger](../../EXPERIMENTS.md) — observed corrections and rejected assumptions.
6. [Project state](../../PROJECT-STATE.md) — the current implementation handoff.

## Definition of a faithful recreation

A recreation is faithful when it can:

- index a folder and return an exact lexical result with path and line citation;
- retrieve a controlled vocabulary mismatch through a real semantic baseline;
- expose search, authoritative read, source listing, and status as narrow tools;
- publish and reopen a checksummed Zig snapshot without re-tokenizing stored lexical state;
- reject mismatched query/index embedding identities;
- prevent unauthorized chunks from entering either channel or authoritative reads;
- reuse unchanged chunks/vectors and remove deleted sources;
- compare relevance modes with judged queries;
- run reproducible scale measurements and preserve the raw results;
- pass the acceptance gates in the specification.

Exact filenames and internal implementation details may evolve. The contracts, invariants, evidence discipline, and observable behavior are the durable product.

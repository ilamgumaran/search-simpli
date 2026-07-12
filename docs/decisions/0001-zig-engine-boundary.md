# ADR 0001: Use Zig for the search engine boundary

Status: proposed

## Context

The system needs predictable memory use, compact persistent indexes, concurrent reads, background segment work, and fast lexical/vector kernels. It also needs rapidly changing extractors, model integrations, and evaluation workflows.

## Decision

Use Zig for the durable indexing and retrieval engine: segment I/O, compression, postings traversal, vector distance, candidate collection, fusion, filtering, compaction, and the query service.

Keep document extraction, embedding inference, LLM generation, and offline evaluation behind language-neutral process or file contracts initially. Python can remain the behavioral reference and experimentation layer.

## Why

- Explicit allocation and data layout are useful for posting lists and vector arrays.
- Straightforward C interoperation leaves room for mature compression, model-runtime, and platform libraries.
- A small runtime and native binaries fit local and server deployments.
- The engine can be built from first principles without requiring the model ecosystem to move into Zig.

## Costs

- The search ecosystem and library selection are smaller than in Java, Rust, Go, or C++.
- Toolchain changes require a pinned Zig version and deliberate upgrades.
- Implementing formats, concurrency, corruption handling, and approximate vector search from scratch is substantial work.
- Performance work needs benchmarks; low-level control alone is not a speed guarantee.

## Guardrails

- Pin the Zig toolchain before production code expands.
- Golden-test ranking against the reference implementation.
- Fuzz parsers and segment readers before accepting untrusted index data.
- Version every on-disk format and embedding model.
- Start with simple algorithms and profile before adding specialized structures.

# Search Simpli documentation

This directory is the durable knowledge base for Search Simpli. It separates why the system exists, what it must do, how it is implemented, what has been measured, and which product situations it should serve.

## Start here

| Need | Read |
|---|---|
| Re-create the project from an empty repository | [Recreation kit](recreation/README.md) |
| Understand the required behavior | [Executable specification](recreation/specification.md) |
| Give the build to a coding agent | [Recreation prompts](recreation/prompts.md) |
| Add or review a product scenario | [Use-case library](use-cases/README.md) |
| Understand retrieval and grounding | [Search and answer theory](theory.md) |
| Compare simple, single-node, and distributed options | [Architecture](architecture.md) |
| See completed and failed experiments | [Experiment ledger](../EXPERIMENTS.md) |
| Continue current implementation work | [Project state](../PROJECT-STATE.md) |

## Theory and decisions

- [Search and answer theory](theory.md)
- [Architecture and option comparison](architecture.md)
- [Experiment-driven roadmap](roadmap.md)
- [Why Zig and where it belongs](decisions/0001-zig-engine-boundary.md)
- [Ground-up PPMI semantics](cooccurrence-semantics.md)
- [Measured scale behavior](scale-benchmark.md)

## Interfaces and safety

- [Local LLM/agent tool protocol](tool-protocol.md)
- [Zig JSON-RPC service](zig-rpc-service.md)
- [Python-to-Zig bridge](python-zig-bridge.md)
- [Query embedding gateway](query-embedding-gateway.md)
- [Pre-retrieval authorization](authorization.md)
- [Incremental indexing](incremental-indexing.md)

## Persistence

- [Document/vector segment v1](segment-format-v1.md), [v2](segment-format-v2.md), and [v3](segment-format-v3.md)
- [Lexical segment v1](lexical-segment-format-v1.md)
- [Generation manifest](manifest-format-v1.md)
- [Atomic publication and recovery](publication-recovery.md)
- [Generation lifecycle](generation-lifecycle.md)
- [Postings design](postings-design.md)
- [Zig engine API](zig-engine-api.md)

## Evidence rule

Documentation must distinguish:

- **implemented and verified** behavior;
- **observed** benchmark or evaluation results;
- **working hypotheses** that still require evidence;
- **future options** that are not yet justified.

When an experiment changes a decision, record its setup, what worked, what failed, limits, and conclusion in `EXPERIMENTS.md`, then update `PROJECT-STATE.md` so another session can continue without reconstructing history.

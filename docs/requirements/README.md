# Requirements register

The **single consolidated view of every requirement in Search Simpli.** Its job is
to let a person or an agent see all requirements in one place, trace each one to
the capability and use case that motivates it, and — most importantly — **surface
conflicts between requirements before anything is built.**

This register does not replace the detailed documents; it *indexes and reconciles*
them:

| Document | Role | Authority |
|---|---|---|
| [`docs/recreation/specification.md`](../recreation/specification.md) | Detailed functional/non-functional behavior | Authoritative for **behavior detail** |
| [`contracts/`](../../contracts/) | Cross-process JSON payloads | Authoritative for **wire contracts** |
| [`docs/use-cases/`](../use-cases/README.md) | Scenarios (actor, corpus, acceptance) | Authoritative for **why a requirement exists** |
| **This register** | Consolidated index + conflict ledger | Authoritative for **which requirements exist and how they relate** |
| [`docs/capability-process.md`](../capability-process.md) | How a new capability enters all of the above | Authoritative for **process** |

When the register and a detail document disagree, that disagreement is itself a
**conflict** (log it below) — the register is where such disagreements are made
visible and resolved, not silently tolerated.

## How to use it

- **Adding a capability?** Follow [the capability process](../capability-process.md).
  It ends by updating this register.
- **Checking for conflicts?** Read the [invariants](#invariants-inv) and the
  [functional](#functional-requirements-fr) / [non-functional](#non-functional-requirements-nfr)
  indexes, then record anything that clashes in the [conflict register](#conflict-register-cft).
- **Tracing a requirement?** Every FR/NFR row links to its capability and use
  case; every capability links to its requirements.

## ID scheme

| Prefix | Entity | Source of truth |
|---|---|---|
| `CAP-NN` | Capability — a coherent unit of functionality | This register |
| `UC-NNN` | Use case — a scenario that motivates capabilities | `docs/use-cases/` |
| `FR-NN` | Functional requirement | `docs/recreation/specification.md` §2 |
| `NFR-NN` | Non-functional requirement | `docs/recreation/specification.md` §3 |
| `INV-NN` | Invariant — a non-negotiable principle | This register |
| `CON-NN` | Contract — a versioned cross-process schema | `contracts/` |
| `CFT-NN` | Conflict — a recorded tension between requirements | This register |

IDs are **stable and never recycled.** A removed requirement is marked
*withdrawn*, not deleted, so traceability survives.

## Status vocabulary

Requirement/capability lifecycle (aligned with the use-case library):

- **Proposed** — shaped, has acceptance criteria, not started.
- **Diagnostic** — exercised only with authored/synthetic fixtures.
- **Validated** — evaluated against representative user-derived judgments.
- **Operational** — reliability, security, freshness, performance targets also met.
- **Blocked** — a named decision or capability prevents progress.
- **Withdrawn** — retired; ID retained for traceability.

Evidence tag (orthogonal, per the project's evidence rule): each claim is
*implemented*, *observed*, *hypothesis*, or *future option*.

## Invariants (INV)

Non-negotiable. Every capability must comply; a capability that appears to
require breaking one of these must be resolved as a conflict, not merged.

| ID | Invariant | Source |
|---|---|---|
| INV-01 | Retrieval and generation stay separate; search finds/cites evidence, it does not become the source of truth. | recreation principles |
| INV-02 | Every returned passage carries stable identity and a source citation. | recreation principles |
| INV-03 | Authorization filters both lexical and semantic channels **before** ranks/fusion, and gates read/list. | FR-08, NFR-05 |
| INV-04 | Embedding model identity, dimensions, normalization, and chunker identity are index data; re-embedding is a migration. | architecture |
| INV-05 | Exact vector scan stays the correctness oracle if approximate search is added. | recreation principles |
| INV-06 | Base local mode runs without third-party packages. | NFR-01 |
| INV-07 | Persistent formats are versioned, bounded, checksummed, with explicit backward compatibility. | NFR-02 |
| INV-08 | Result ordering is deterministic for equal scores. | NFR-03 |
| INV-09 | Complexity is earned by measurement (before/after benchmark + rollback), not added in anticipation. | roadmap, recreation principles |
| INV-10 | Tests must actually execute; documentation distinguishes implemented/observed/hypothesis/future. | NFR-07, NFR-08 |
| INV-11 | Learning/adaptation tunes ranking, never truth; no learned change ships that regresses the versioned holdout gate beyond thresholds. | `docs/learning-loop.md` |

## Capability catalog (CAP)

| ID | Capability | Use cases | Key requirements | Status / evidence |
|---|---|---|---|---|
| CAP-01 | Local file indexing & chunking | UC-001, UC-002 | FR-01, FR-02 | Operational-ish / implemented |
| CAP-02 | Lexical retrieval (BM25) | UC-001, UC-002 | FR-03 | Validated-lite / implemented |
| CAP-03 | Semantic retrieval (none/hash/PPMI/neural) | UC-001, UC-002 | FR-04 | Diagnostic / implemented |
| CAP-04 | Hybrid fusion (RRF) | UC-001, UC-002 | FR-05 | Diagnostic / implemented |
| CAP-05 | Cited evidence envelope | UC-001, UC-002, UC-003 | FR-06 | Implemented |
| CAP-06 | Agent/LLM tool surface (search/read/list/status) | UC-002, UC-003 | FR-07 | Implemented |
| CAP-07 | Pre-retrieval authorization | UC-003 | FR-08 | Diagnostic / implemented (static labels) |
| CAP-08 | Incremental preparation | UC-001, UC-002 | FR-09 | Implemented |
| CAP-09 | Python→Zig interchange | UC-002 | FR-10 | Implemented |
| CAP-10 | Durable Zig snapshot engine | UC-002, UC-003 | FR-11 | Implemented |
| CAP-11 | Evaluation & benchmarks | all | FR-12 | Diagnostic / implemented |
| CAP-12 | Adaptive learning loop | UC-001, UC-003 | (new FRs on intake) | Proposed / future — board L-01…L-05 |
| CAP-13 | [MCP tool adapter](cap-13-mcp-adapter.md) | UC-004, UC-002, UC-003 | FR-13, NFR-09 | Proposed / future — board I-01 |
| CAP-14 | [Trust-calibration signal](cap-14-trust-calibration.md) | UC-001, UC-002, UC-003 | FR-14 | Proposed / future — board S-01, E-02 |
| CAP-15 | [Structure-aware code chunking](cap-15-structure-aware-chunking.md) | UC-002 | FR-15 | Proposed / future |

New capabilities append here as `CAP-16`, `CAP-17`, … via the process, each with
a filled spec (see the three above as worked examples).

## Functional requirements (FR)

Canonical text lives in [specification.md §2](../recreation/specification.md).
This index adds status and traceability.

| ID | Requirement (short) | Capability | Status / evidence |
|---|---|---|---|
| FR-01 | Source discovery (extensions, skips, UTF-8, SHA-256, root-relative path) | CAP-01 | Implemented |
| FR-02 | Chunking & deterministic identity (path, lines, tokens, labels, chunker id) | CAP-01 | Implemented |
| FR-03 | Lexical retrieval (case-insensitive tokenization, corpus BM25) | CAP-02 | Implemented |
| FR-04 | Semantic retrieval (none/hash/cooccurrence/neural; model metadata) | CAP-03 | Implemented (diagnostic) |
| FR-05 | Hybrid ranking (independent ranks, candidate_k, RRF, deterministic ties) | CAP-04 | Implemented |
| FR-06 | Evidence response (chunk id, citation, content, fused + component scores) | CAP-05 | Implemented |
| FR-07 | Tool surface (search_knowledge, read_chunk, list_sources, index_status) | CAP-06 | Implemented |
| FR-08 | Authorization (canonical labels, trusted principal, pre-rank isolation) | CAP-07 | Implemented (static) |
| FR-09 | Incremental preparation (reuse/relabel/delete/embed-changed, fail-closed) | CAP-08 | Implemented |
| FR-10 | Python/Zig interchange (versioned neutral JSON, validated bounds) | CAP-09 | Implemented |
| FR-11 | Durable snapshot (checksummed sections, manifest, atomic publish, writer lock) | CAP-10 | Implemented |
| FR-12 | Evaluation & benchmarks (judged modes, machine-readable, stated limits) | CAP-11 | Implemented (diagnostic) |
| FR-13 | MCP adapter binds FR-07 operations, injects trusted principal, forbids caller vectors, parity with direct surface | CAP-13 | Proposed |
| FR-14 | First-class retrieval-derived support/confidence signal in the evidence response; low-support flagging; never generative | CAP-14 (changes FR-06) | Proposed |
| FR-15 | Structure-aware chunking on syntactic units for supported languages, deterministic identity, deterministic line-window fallback | CAP-15 (changes FR-02) | Proposed |

## Non-functional requirements (NFR)

Canonical text lives in [specification.md §3](../recreation/specification.md).

| ID | Requirement (short) | Applies to | Status |
|---|---|---|---|
| NFR-01 | Base Python indexing/search runs on 3.11+ without third-party deps | CAP-01..CAP-09, CAP-11 | Implemented |
| NFR-02 | Persistent formats versioned, bounded, checksummed; explicit backcompat | CAP-09, CAP-10 | Implemented |
| NFR-03 | Deterministic ordering for equal scores | CAP-02..CAP-05, CAP-10 | Implemented |
| NFR-04 | Zig query core uses caller-owned bounded workspaces | CAP-10 | Implemented |
| NFR-05 | Forbidden content filtered before ranks, not only from output | CAP-07 | Implemented |
| NFR-06 | Optional neural imports are lazy and fail with concise errors | CAP-03 | Implemented |
| NFR-07 | Every material change backed by tests or a recorded experiment | all | Process |
| NFR-08 | Docs distinguish implementation, observation, hypothesis, future option | all | Process |
| NFR-09 | Optional interface adapters (MCP/HTTP) are isolated so the base local mode stays dependency-free | CAP-13 | Proposed |

## Contracts (CON)

| ID | Schema | Purpose |
|---|---|---|
| CON-01 | `contracts/search-tool.schema.json` | Shared search tool contract |
| CON-02 | `contracts/tool-request.schema.json` | Tool request envelope |
| CON-03 | `contracts/snapshot-interchange.schema.json` | Python→Zig interchange |
| CON-04 | `contracts/embedding-provider.schema.json` | Embedding provider protocol |
| CON-05 | `contracts/access-rules.schema.json` | Path→label access rules |

Pending additive, versioned changes (backward compatible, INV-07):

- CON-01 gains an optional `support`/`confidence` field for CAP-14 (FR-14).
- CON-03 gains an optional structural-kind field for CAP-15 (FR-15).

## Conflict register (CFT)

Every recorded tension between requirements. A capability may not move past the
process's **conflict-check gate** until each conflict it touches is either
*resolved* or explicitly *accepted with rationale*. This section is the point of
the whole register.

| ID | Between | Tension | Resolution | Status |
|---|---|---|---|---|
| CFT-01 | CAP-12 (per-user adaptive ranking) ↔ INV-08 / NFR-03 (deterministic ordering) & recreation "reproducible results" | Per-principal, history-dependent ranking makes output depend on who asks and when, which reads as non-deterministic/non-reproducible. | Determinism is scoped to the tuple *(index generation, principal, policy id)*. Given a fixed policy id and principal, ordering stays deterministic for equal scores; the frozen holdout gate always evaluates under a pinned policy id. Adaptation is versioned and replayable, not free-running. | Resolved (design) |
| CFT-02 | CAP-13 (MCP/network adapter) ↔ INV-06 / NFR-01 (dependency-free base) | A network adapter pulls in dependencies and a transport the base mode does not have. | The adapter is an **optional layer**; the base local mode stays dependency-free and runnable without it. Authorization (INV-03) and the text-only/no-caller-vectors boundary still apply through the adapter. | Resolved (design) |
| CFT-03 | CAP-12 (interaction ledger) ↔ INV-09 (complexity earned by measurement) | Building learning infrastructure before a measured relevance bottleneck could be "complexity in anticipation." | Staged per `docs/learning-loop.md`: the ledger only *captures* (Stage 1) and each later stage has an evidence gate; no ranking change ships without beating the held-out gate. Capture is cheap and reversible; adaptation is earned. | Accepted with rationale |
| CFT-04 | CAP-14 (trust-calibration) ↔ INV-01 (retrieval≠generation) | A "confidence" score could drift into a generative judgment of whether the answer is true, blurring the retrieval/generation line. | The signal is defined strictly as a deterministic function of retrieval features (scores, rank agreement, gaps, supporting count) — no model call. It calibrates evidence strength, not answer truth. | Resolved (design) |
| CFT-05 | CAP-14 (support field) ↔ CON-01 / INV-07 (contract backcompat) | Adding a field to the evidence response could break existing consumers. | Optional, versioned field; unaware consumers ignore it. | Resolved (design) |
| CFT-06 | CAP-15 (structure-aware chunking) ↔ FR-02 / INV-04 (chunk identity) & FR-09 (incremental reuse) | New chunk boundaries change chunk ids, silently invalidating reused chunks/vectors from a line-window index. | Chunker id/version is bumped; FR-09 already fails closed on chunker change, forcing a clean re-embed (a migration), never a silent mismatch. Identity stays deterministic. | Resolved (existing behavior) |
| CFT-07 | CAP-15 (structure-aware chunking) ↔ INV-06 / NFR-01 (dependency-free base) | Syntactic parsing may need a language-parser dependency. | Opt-in per language; base mode stays dependency-free line-window; parse failure falls back deterministically. | Resolved (design) |
| CFT-08 | CAP-13 (MCP adapter) ↔ INV-03 (pre-rank authorization) | An external agent could try to supply its own principal or query vectors to widen access. | Adapter injects the trusted principal from config/host context and rejects caller-supplied principal/vectors — the boundary already proven for the JSON-RPC gateway. | Resolved (design) |

New conflicts append as `CFT-09`, … Record the conflict even if you resolve it
immediately — the record is the value.

## Traceability

The intended chain for any capability:

```text
UC-NNN (why)  ->  CAP-NN (what)  ->  FR/NFR (requirements)  ->  CON (contracts)
                                          |
                                   INV (must comply)
                                          |
                              tests + EXPERIMENTS.md (evidence)
```

If any link is missing for a capability, it is not ready to build.

## Change control

This register changes **only through** [the capability process](../capability-process.md).
Every change:

1. assigns stable IDs and updates the relevant tables;
2. records any new conflict in the conflict register;
3. is landed with the same evidence discipline as code (tests / `EXPERIMENTS.md`);
4. is reflected in [`PROJECT-STATE.md`](../../PROJECT-STATE.md) when it changes current behavior.

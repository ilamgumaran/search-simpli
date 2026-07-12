# CAP-13 — MCP tool adapter

Status: Proposed · Evidence: future option

> Run through the [capability process](../capability-process.md), steps 1–6.
> Requirements defined and conflicts checked; implementation is a later step.

## 1. Proposal

- **Problem / what should be possible:** Real agents live in MCP hosts, but Search Simpli's four tool operations are only reachable over a bespoke JSON-RPC process. Expose them over MCP so any MCP-capable agent can search and read cited evidence.
- **Who it serves:** agent users (and the operators who deploy for them)
- **HIO tie:** use-side, inorganic — lets external agents actually consume the retrieval partnership.
- **One-line success notion:** an MCP client gets the same cited, authorized results as the direct tool surface, with no new powers.

## 2. Motivating use case(s)

- Primary: [`UC-004`](../use-cases/uc-004-mcp-external-agent.md)
- Also serves: UC-002 (codebase agent), UC-003 (authorized team)

## 3. Functional requirements (new or changed)

| ID | Requirement (testable) | New / changes | Traces to |
|---|---|---|---|
| FR-13 | An MCP adapter binds the existing FR-07 operations (`search_knowledge`, `read_chunk`, `list_sources`, `index_status`) to the Model Context Protocol with identical semantics and structured errors. It exposes **no** operation beyond FR-07, injects the trusted principal from configuration/host context (never from the caller), forbids caller-supplied query vectors, and returns results byte-identical to the direct tool surface for identical requests. | new | UC-004, FR-07 |

## 4. Non-functional impact

| ID | Requirement / impact | Target or constraint |
|---|---|---|
| NFR-09 | Optional interface adapters (MCP/HTTP) are isolated so the base local mode stays dependency-free and runnable without them. | New NFR |
| NFR-03 / INV-08 | Determinism preserved: the adapter must not reorder or re-rank. | Unchanged |

## 5. Contracts touched (CON)

- Reuses `CON-01` (`search-tool.schema.json`) unchanged for request/response payloads; MCP tool descriptors map onto it.
- No new schema. Backward-compatibility: none affected (additive transport).

## 6. Invariant compliance (INV)

- INV-01 retrieval≠generation: complies — adapter is transport only, no synthesis.
- INV-03 pre-rank authorization: complies — principal injected server-side; unauthorized chunks never enter any channel/read; caller cannot forge principal or vectors.
- INV-06 dependency-free base: complies — adapter is an optional, isolated layer (see NFR-09 and CFT-02).
- INV-08 deterministic ordering: complies — no re-ranking.
- Others: no impact.

## 7. Register updates (done in step 4)

- Capability catalog: CAP-13 status → Proposed, key requirements → FR-13, NFR-09; use cases → UC-004, UC-002, UC-003.
- FR index: add FR-13. NFR index: add NFR-09.

## 8. Conflict check (required)

| CFT | Between | Tension | Resolution | Status |
|---|---|---|---|---|
| CFT-02 | CAP-13 ↔ INV-06 / NFR-01 (dependency-free base) | Network/protocol adapter pulls in dependencies the base lacks. | Optional isolated layer; base mode stays dependency-free (NFR-09). | Resolved |
| CFT-08 | CAP-13 ↔ INV-03 (pre-rank authorization) | An external agent could try to supply its own principal or query vectors to widen access. | Adapter injects the trusted principal from config/host context and rejects caller-supplied principal/vectors; identical to the gateway boundary already proven for the JSON-RPC path. | Resolved |

No other conflicts found against the register as of this commit.

## 9. Acceptance gate

- Retrieval metric + target: **result parity** with the direct tool surface on the same snapshot (identical in → identical out).
- Citation-support: every passage carries id + path + line span.
- Unanswerable/negative: absent-topic query returns insufficient support (unchanged).
- Freshness: `index_status` reflects the bound generation.
- Performance: recorded, bounded adapter round-trip overhead.
- Security/isolation: caller-supplied principal/vector rejected; unauthorized labels never surface; malformed input does not crash the server.
- Fixture/benchmark: reuse snapshot judged queries + an adapter-overhead micro-benchmark.

## 10. Evidence plan

- Tests: MCP conformance + authorization-forgery rejection + parity vs JSON-RPC.
- `EXPERIMENTS.md`: hypothesis (MCP parity + no new powers), setup, observed parity/overhead, limits.
- `PROJECT-STATE.md`: note MCP adapter status.
- Status advances Proposed → Diagnostic (parity tests) → Validated (real agent over a judged snapshot) → Operational.

## 11. Open decisions

- Decision: stdio-only first vs. also a network transport (and its auth).
- Owner: operator.
- Evidence needed: whether networked deployment is required before building transport auth.

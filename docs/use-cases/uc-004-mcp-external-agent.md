# UC-004 — External agent via MCP

Status: Proposed

## Outcome

An external AI agent (running in an MCP-capable host the operator does not
control line-by-line) can search an authorized Search Simpli snapshot and read
cited passages through the Model Context Protocol, without gaining raw filesystem
access or the ability to forge its own identity or query vectors.

## Actors

- Primary actor: an MCP client / agent host
- LLM/agent role: the agent issues tool calls and synthesizes a cited answer
- Data owner: the operator who published the snapshot and configured access
- Operator: runs the MCP server process bound to a specific snapshot + principal

## Corpus

- Source types: whatever the bound snapshot indexed (docs, code, mixed)
- Approximate files/chunks/bytes: inherited from the snapshot
- Languages or domains: inherited
- Update pattern: snapshot generation cadence (out of scope for the adapter)
- Extraction limitations: inherited; the adapter adds none

## Representative questions

1. Exact lookup: "find the function `publish_manifest`"
2. Paraphrase or vocabulary mismatch: "how do we make an index change crash-safe?"
3. Multi-passage question: "what happens across writer lock and manifest replace?"
4. Scoped/filtered question: "search only under `zig/src` for postings"
5. Unanswerable or negative question: "what is our Kubernetes rollout policy?" (absent → must return insufficient support, not invent)

## Expected tool flow

The agent calls `index_status` to learn freshness/versions, `search_knowledge`
for cited candidates, `read_chunk` for the authoritative passage, and
`list_sources` to navigate — the exact four operations of FR-07, now reachable
over MCP. It stops when it has cited support or a clear "not supported."

## Retrieval expectations

- Lexical strengths needed: exact identifier lookups
- Semantic strengths needed: paraphrase over the bound snapshot's model
- Fusion or routing expectation: same as the underlying engine; the adapter does not re-rank
- Citation granularity: chunk id + path + line span (unchanged)
- Freshness target: reflects the bound snapshot generation
- Latency target: adapter overhead is small relative to retrieval; see acceptance

## Authorization and privacy

- Principal source: **trusted configuration / authenticated host context**, injected by the operator — never a value the agent supplies
- Required labels or tenant boundary: the bound principal's labels; unauthorized chunks never enter any channel, listing, or read
- Hosted-model/egress policy: the adapter transmits only what the tool contract already returns; no new egress path for raw files
- Logging and retention expectations: operator policy; the adapter adds no covert store
- Required denial behavior: denied and unknown chunk reads are indistinguishable

## Acceptance criteria

- Retrieval metric and target: parity with the direct JSON-RPC tool surface on the same snapshot (identical results for identical requests)
- Citation-support target: every returned passage carries id + path + line span
- Unanswerable behavior: **parity** with the current engine's behavior on absent-topic queries (CAP-13 adds no new insufficient-support guarantee; that is CAP-14/E-02)
- Freshness target: `index_status` reflects the bound generation
- Performance target: adapter round-trip overhead recorded and bounded (state the number when measured)
- Security/isolation tests: agent-supplied principal or query vector is rejected; unauthorized labels never appear; malformed input does not crash the server

## Evaluation assets

- Judgment fixture: reuse the snapshot's existing judged queries
- Benchmark artifact: adapter-overhead micro-benchmark (to be recorded)
- Relevant experiment entry: to be added on build
- Test files: MCP adapter conformance + authorization tests (to be added)

## Risks and failure modes

- Retrieval: none new — the adapter must not silently re-rank or filter
- Authorization/privacy: caller forging principal/vectors; mitigated by injection + rejection
- Staleness/deletion: agent trusting a stale snapshot; mitigated by `index_status`
- Prompt injection: retrieved content influencing the agent; mitigated by evidence framing + read-only tools
- Operational: transport/protocol errors must return structured errors, not crash

## Open decisions

- Decision: local stdio MCP first, or also a network transport?
- Owner: (operator)
- Evidence needed: whether a networked deployment is actually required before building transport auth

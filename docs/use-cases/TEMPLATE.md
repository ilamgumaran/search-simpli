# UC-NNN — Short use-case name

Status: Proposed

## Outcome

What should the actor be able to accomplish, and why is search needed?

## Actors

- Primary actor:
- LLM/agent role, if any:
- Data owner:
- Operator:

## Corpus

- Source types:
- Approximate files/chunks/bytes:
- Languages or domains:
- Update pattern:
- Extraction limitations:

## Representative questions

1. Exact lookup:
2. Paraphrase or vocabulary mismatch:
3. Multi-passage question:
4. Scoped/filtered question:
5. Unanswerable or negative question:

## Expected tool flow

Describe when the caller uses `index_status`, `search_knowledge`, `read_chunk`, and `list_sources`, and when it should stop or refine the query.

## Retrieval expectations

- Lexical strengths needed:
- Semantic strengths needed:
- Fusion or routing expectation:
- Citation granularity:
- Freshness target:
- Latency target:

## Authorization and privacy

- Principal source:
- Required labels or tenant boundary:
- Hosted-model/egress policy:
- Logging and retention expectations:
- Required denial behavior:

## Acceptance criteria

- Retrieval metric and target:
- Citation-support target:
- Unanswerable behavior:
- Freshness target:
- Performance target:
- Security/isolation tests:

## Evaluation assets

- Judgment fixture:
- Benchmark artifact:
- Relevant experiment entry:
- Test files:

## Risks and failure modes

- Retrieval:
- Authorization/privacy:
- Staleness/deletion:
- Prompt injection:
- Operational:

## Open decisions

- Decision:
- Owner:
- Evidence needed:

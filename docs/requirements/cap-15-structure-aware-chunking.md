# CAP-15 — Structure-aware code chunking

Status: Proposed · Evidence: future option

> Run through the [capability process](../capability-process.md), steps 1–6.

## 1. Proposal

- **Problem / what should be possible:** Code is chunked by fixed overlapping line windows, which cut across function/class boundaries and split a definition from its signature. For codebase search (UC-002) this hurts both exact lookups and citations. Chunk on syntactic units instead, when structure is available.
- **Who it serves:** agent users and developers searching code.
- **HIO tie:** use-side, inorganic — better units make retrieval and citations land on meaningful spans.
- **One-line success notion:** a search for a function returns that function as a coherent, correctly-cited chunk rather than a fragment.

## 2. Motivating use case(s)

- Primary: [`UC-002`](../use-cases/uc-002-codebase-agent.md)
- Not applicable to prose-only corpora (UC-001), which keep line-window chunking.

## 3. Functional requirements (new or changed)

| ID | Requirement (testable) | New / changes | Traces to |
|---|---|---|---|
| FR-15 | For supported source languages, a structure-aware chunker emits chunks aligned to syntactic units (function / class / top-level block) within bounded size, preserving stable deterministic chunk identity and line-span citations, and records a chunker id/version. When structure is unavailable (unsupported language, parse failure, oversize unit) it deterministically falls back to bounded line-window chunking. | changes FR-02 | UC-002 |

## 4. Non-functional impact

| ID | Requirement / impact | Target or constraint |
|---|---|---|
| INV-06 / NFR-01 | Any parser dependency must not enter the base mode; structure-aware chunking is opt-in. | Constraint (see CFT-07) |
| INV-04 | Chunker id/version is index data; changing it is a migration. | Constraint |
| FR-09 | Incremental reuse must fail closed when the chunker changes. | Reuses existing behavior (see CFT-06) |

## 5. Contracts touched (CON)

- `CON-03` (`snapshot-interchange.schema.json`): optionally record the chunk's structural kind (function/class/block/line-window) and the chunker id/version already carried. Additive, versioned (INV-07).

## 6. Invariant compliance (INV)

- INV-02 citations: complies — spans still map to path + line range, now more meaningful.
- INV-04 model/chunker identity is index data: complies — records chunker id/version; re-chunking is a migration.
- INV-06 dependency-free base: complies — opt-in; base stays line-window and dependency-free (CFT-07).
- INV-08 determinism: complies — identity and fallback are deterministic.
- Others: no impact.

## 7. Register updates (done in step 4)

- Capability catalog: add CAP-15.
- FR index: add FR-15 (changes FR-02). Contracts: note CON-03 optional structural-kind field.

## 8. Conflict check (required)

| CFT | Between | Tension | Resolution | Status |
|---|---|---|---|---|
| CFT-06 | CAP-15 ↔ FR-02 / INV-04 (chunk identity) & FR-09 (incremental reuse) | New chunk boundaries change chunk ids, which would silently invalidate reused chunks/vectors from a line-window index. | Chunker id/version is bumped; FR-09 already **fails closed** on chunker change, so a mode switch forces a clean re-embed (a migration), never a silent mismatch. Identity stays deterministic. | Resolved (by existing behavior) |
| CFT-07 | CAP-15 ↔ INV-06 / NFR-01 (dependency-free base) | Syntactic parsing may require a language-parser dependency. | Structure-aware chunking is opt-in per language; the base mode stays dependency-free with line-window chunking; parse failure falls back deterministically. | Resolved |

No other conflicts found against the register as of this commit.

## 9. Acceptance gate

- Retrieval metric + target: on a judged **code** set, structure-aware chunking improves exact-symbol success@k and citation coherence vs. line-window, with no regression on prose.
- Citation-support: a returned function chunk cites its full span.
- Unanswerable/negative: unchanged.
- Determinism: identical inputs → identical chunk ids and fallback (test).
- Migration: switching chunker forces re-embed via FR-09 fail-closed (test).
- Fixture: a small multi-language code corpus with symbol-lookup judgments.

## 10. Evidence plan

- Tests: deterministic identity; fallback on parse failure; FR-09 fail-closed on chunker change; base mode has no new dependency.
- `EXPERIMENTS.md`: hypothesis (syntactic chunks beat line windows for code), setup, observed deltas, limits (language coverage).
- `PROJECT-STATE.md`: note structure-aware chunking status.
- Status advances Proposed → Diagnostic → Validated on a real code corpus.

## 11. Open decisions

- Decision: which languages first, and which parsing approach (lightweight heuristics vs. a real parser) stays inside the dependency-free base.
- Owner: (maintainer).
- Evidence needed: whether heuristic boundary detection is good enough to avoid a parser dependency for the first languages.

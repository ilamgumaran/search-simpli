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
- INV-04 model/chunker identity is index data: complies **in the Python path** (records chunker id/version). The **durable Zig path does not carry chunker identity yet** — see CFT-09; CAP-15 is scoped to Python until that contract exists.
- INV-06 dependency-free base: complies — opt-in; base stays line-window and dependency-free (CFT-07).
- INV-08 determinism: complies — identity and fallback are deterministic.
- Others: no impact.

## 7. Register updates (done in step 4)

- Capability catalog: add CAP-15.
- FR index: add FR-15 (changes FR-02). Contracts: note CON-03 optional structural-kind field, **and** a required new chunker-identity field on CON-03 + Zig manifest/`index_status` to unblock CFT-09.

## 8. Conflict check (required)

| CFT | Between | Tension | Resolution | Status |
|---|---|---|---|---|
| CFT-06 | CAP-15 ↔ FR-09 (incremental reuse), **Python path** | New chunk boundaries change chunk ids, which could silently invalidate reused chunks/vectors. | Python records chunker id (FR-02); FR-09 reuse already **fails closed** on chunker change, forcing a clean re-embed (a migration). Identity stays deterministic. | Resolved |
| CFT-07 | CAP-15 ↔ INV-06 / NFR-01 (dependency-free base) | Syntactic parsing may require a language-parser dependency. | Opt-in per language; base mode stays dependency-free line-window; parse failure falls back deterministically. | Resolved |
| CFT-09 | CAP-15 ↔ INV-04 (chunker identity), **durable Zig path** | CON-03 and the Zig manifest/`index_status` do **not** carry a chunker id/version, so the durable path cannot validate chunker identity or fail closed on mismatch. | **Blocked** until a versioned chunker-identity field is added through CON-03 → Zig manifest/status with a migration/backcompat plan (INV-07). Until then CAP-15 ships **Python-only**. | Blocked |

## 8b. Dependencies

- To ship the **durable path**: the chunker-identity contract change (CFT-09).
  CAP-15's Python-path scope has no blocking dependency.

## 9. Acceptance gate

Decidable now (Python path):

- **Determinism:** identical inputs → identical chunk ids and identical fallback · exact-match test · any deviation blocks.
- **Fallback:** on parse failure / unsupported language / oversize unit, deterministically produce line-window chunks · unit test · any nondeterminism blocks.
- **Citation-support:** a returned function chunk cites its full line span · 100%.
- **Migration:** switching chunker forces re-embed via FR-09 fail-closed · test · any silent reuse blocks.
- **No new base dependency:** base mode imports no parser · import test · any new base dep blocks.

`pending` (blocked on a code judged corpus — do not fabricate a threshold):

- **Primary quality metric:** *metric* = exact-symbol success@3 and a citation-coherence
  score (fraction of returned code chunks whose span is a complete syntactic unit);
  *baseline* = line-window chunking; *fixture/split* = a multi-language code judged
  set, tuning vs. held-out; *threshold* = **to be set on tuning data**; *rule* = ship
  only if success@3 and coherence improve on held-out with **no regression on prose**.

## 10. Evidence plan

- Tests: deterministic identity; fallback on parse failure; FR-09 fail-closed on chunker change; base mode has no new dependency.
- `EXPERIMENTS.md`: hypothesis (syntactic chunks beat line windows for code), setup, observed deltas, limits (language coverage).
- `PROJECT-STATE.md`: note structure-aware chunking status.
- Status advances Proposed → Diagnostic → Validated on a real code corpus.

## 11. Open decisions

- Decision: which languages first, and which parsing approach (lightweight heuristics vs. a real parser) stays inside the dependency-free base.
- Owner: (maintainer).
- Evidence needed: whether heuristic boundary detection is good enough to avoid a parser dependency for the first languages.

## 12. Maintainer approval (process step 6b)

Required before build. Note the durable-path conflict CFT-09 is `Blocked`;
approval covers the **Python-only** scope, with the durable path deferred.

- Approver:
- Date:
- Commit:
- Status: **Pending approval** · durable path blocked (CFT-09) · quality metric `pending`

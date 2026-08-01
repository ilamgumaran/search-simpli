# CAP-11 / E-01A — Real-folder judgment packs

Status: Proposed · Evidence: future option · Issue: [#4](https://github.com/ilamgumaran/search-simpli/issues/4)

> Proposed extension to CAP-11 / FR-12. This record deliberately stops at
> capability-process step 6b. No implementation may begin until the maintainer
> approval block in §12 names the reviewed commit and explicitly approves §6,
> §8, and §9.

## 1. Proposal

- **Problem / what should be possible:** A maintainer needs a safe,
  reproducible way to turn a real, single-owner file folder and independently
  reviewed questions into separate tuning and frozen-holdout relevance suites.
  Today the evaluator can consume a finished suite, but the project has no
  governed bridge from private folder to confirmed judgment artifact.
- **Who it serves:** the human data owner who supplies relevance judgments,
  contributors who compare rankers, and agents that may prepare scaffolding and
  run evidence without inventing or approving labels.
- **HIO tie:** the seam — inorganic tooling inventories, validates, and measures;
  organic judgment owns what is relevant and whether the holdout is legitimate.
- **One-line success notion:** a human can prepare and seal a 50–100-query
  tuning/holdout pack for a representative folder, after which the same corpus,
  model, modes, and cutoff produce separate machine-readable reports without
  copying source text into the pack.

## 2. Motivating use case(s)

- Primary: [UC-005 — Relevance regression gate](../use-cases/uc-005-relevance-regression-gate.md).
- Validates the intended corpus in [UC-001 — Personal files knowledge assistant](../use-cases/uc-001-personal-files.md).
- Multi-principal/team corpora from UC-003 are explicitly outside E-01A v1; see
  CFT-11.

## 3. Functional requirements (new or changed)

| ID | Requirement (testable) | New / changes | Traces to |
|---|---|---|---|
| FR-12 | Add a versioned real-folder judgment-pack workflow that creates content-free corpus/chunk identity metadata and empty tuning/holdout suite templates; validates corpus freshness, path/chunk membership, query/split isolation, and confirmation hashes; refuses evaluation of unconfirmed or changed packs; and runs confirmed splits separately over one compatible index while preserving machine-readable claim limits. | changes FR-12 | UC-005, UC-001 |

The pack workflow does not create relevance judgments. An agent may initialize
the pack and diagnose validation errors, but only a human data owner/reviewer may
author or confirm the labels and seal the holdout.

## 4. Non-functional impact

| ID | Requirement / impact | Target or constraint |
|---|---|---|
| NFR-01 | Pack initialization, validation, sealing, and lexical execution remain dependency-free. | Python 3.11 standard library only; neural dependencies remain optional. |
| NFR-07 | The implementation and every material workflow change carry executed tests or a recorded experiment. | Determinism, leakage, freshness, isolation, and confirmation failure modes execute in CI. |
| NFR-08 | Diagnostic scaffolds, human-confirmed packs, and representative validation remain distinct claims. | A small/agent-authored fixture may prove mechanics only; it cannot complete E-01. |

Privacy is a design constraint even though it is not yet a numbered NFR: pack
artifacts contain relative paths, hashes, query text, and judgments, all of which
may be sensitive. The workflow must not persist source content or an absolute
corpus root in the pack or default reports.

## 5. Contracts touched (CON)

- No existing search, embedding, or Python/Zig contract changes.
- Introduce local artifact formats `judgment-pack-manifest-v1`,
  `judgment-pack-catalog-v1`, and `judgment-pack-confirmation-v1`.
- These are evaluation artifacts under FR-12, not LLM-facing wire contracts.
  They carry explicit versions; an incompatible meaning requires a new version.
- Evaluation suites remain the existing backward-compatible v2 format.

## 6. Invariant compliance (INV)

- **INV-01 retrieval ≠ generation:** the workflow measures retrieval only and
  never calls an answer model or labels generated truth.
- **INV-02 citations:** judgments use root-relative paths and optional stable
  chunk ids/line spans drawn from a content-free chunk catalog.
- **INV-03 pre-rank authorization:** v1 is restricted to a local, single-owner
  corpus with one trusted visibility boundary. Mixed-label/team evaluation is
  rejected as unsupported rather than silently flattening access; see CFT-11.
- **INV-04 model/chunker identity:** the pack binds the chunker contract and
  corpus/chunk identities; evaluation profiles continue to bind exact embedding
  identity and dimensions.
- **INV-06 dependency-free base:** all pack mechanics use the standard library.
- **INV-07 versioned formats:** manifest, catalog, and confirmation formats are
  versioned; hashes fail closed after corpus or suite changes.
- **INV-08 determinism:** identical admitted source bytes and chunker contract
  produce identical manifest/catalog/template bytes and identities.
- **INV-09 complexity earned by measurement:** E-01 is the named blocker to
  representative relevance evidence; the workflow adds only the missing intake,
  validation, and split boundary around the existing evaluator. See CFT-13.
- **INV-10 honest evidence:** generated scaffolds say `draft`; sealed diagnostics
  remain diagnostic; only an independently confirmed representative E-01 pack
  can support validation.
- **INV-11 learning tunes ranking, not truth:** tuning and holdout suites are
  separated and hash-sealed. The runner reports them independently and never
  mutates either. See CFT-12.

## 7. Register updates

- CAP-11 and FR-12 note the proposed E-01A extension without changing the
  current Diagnostic lifecycle.
- UC-005 defines the human confirmation and real-folder flow.
- CFT-11 through CFT-13 record authorization, holdout, and earned-complexity
  tensions.
- No new capability or FR is created because evaluation workflow remains owned
  by CAP-11 / FR-12.

## 8. Conflict check

| CFT | Between | Tension | Resolution | Status |
|---|---|---|---|---|
| CFT-11 | CAP-11 E-01A ↔ INV-03 / FR-08 | A generic “user folder” may mix authorization domains; catalog paths and reports could flatten or expose them. | Scope v1 to one local data owner and one visibility boundary. Do not accept access rules or a caller principal in this workflow; mixed-label/team evaluation remains blocked on an authorization-aware profile design. Pack/default-report artifacts omit content and absolute roots and remain local unless the owner explicitly authorizes publication. | Resolved (scope) |
| CFT-12 | CAP-11 E-01A ↔ INV-11 | A tool that handles both tuning and holdout could let tuning consume holdout labels or silently change the frozen gate. | Separate suites; reject duplicate ids and normalized query text across splits; hash both suites in an explicit human confirmation; reject any post-confirmation edit; report splits separately; never auto-tune or select a model from holdout results. Human process can still leak information, so documentation forbids iterative holdout inspection. | Resolved (design) |
| CFT-13 | CAP-11 E-01A ↔ INV-09 | A pack schema, validator, and runner add process/tooling complexity before representative evidence exists. | The absence of representative user-derived judgments is already the recorded Phase-1/E-01 blocker, and the evaluator currently requires error-prone hand assembly. Limit v1 to three small versioned artifacts and orchestration over existing indexing/evaluation; no new ranker, storage engine, model, or service. Remove the workflow if it does not produce a confirmed pack. | Resolved (bounded experiment) |

No other conflicts were found against the register at base commit `43519f4` on
2026-07-19.

## 8b. Dependencies

- Implemented CAP-01/FR-01–02 for deterministic file discovery and chunk identity.
- Implemented CAP-03/04 for optional semantic and hybrid comparison.
- Implemented CAP-11/FR-12 evaluator, graded suites, profiles, and persisted-index reuse.
- Human dependency: a data owner must select the representative folder, author
  50–100 real questions, identify expected passages, and independently confirm
  both splits. Tool implementation does not satisfy this dependency.
- No implementation acceptance criterion depends on an unbuilt capability.
  E-01 validation remains pending human data; E-02 unanswerable calibration is
  separate and not a prerequisite for this positive-relevance workflow.

## 9. Acceptance gate

- **Deterministic initialization:** metric = byte equality of generated
  manifest/catalog/templates; baseline = first run; fixture = identical small
  folder initialized twice; threshold = exact equality; any difference blocks.
- **Content/host privacy:** metric = forbidden-data occurrences; baseline = zero;
  fixture = corpus containing a sentinel body plus a host-specific absolute root;
  threshold = zero sentinel content and zero absolute-root occurrences in pack
  and default reports; any occurrence blocks.
- **Freshness:** metric = stale changes detected; baseline = sealed identity;
  fixture = change/add/delete one admitted source; threshold = 100% of cases
  rejected before evaluation; any missed change blocks.
- **Judgment integrity:** metric = invalid cases rejected; fixture = duplicate id,
  duplicate normalized query across splits, unknown path, mismatched chunk id,
  empty split, and unsupported format version; threshold = 100%; any acceptance
  blocks.
- **Confirmation/freeze:** metric = mutation cases rejected; fixture = missing
  confirmation plus edits to manifest, catalog, tuning suite, and holdout suite
  after confirmation; threshold = 100%; any evaluation that proceeds blocks.
- **E-01 claim boundary:** an `e01` confirmation requires 50–100 total questions,
  both splits non-empty, a named human reviewer, explicit review statement, and
  exact artifact hashes. Smaller packs may be sealed only as `diagnostic` and
  must remain labeled non-representative.
- **Execution:** metric = split reports and index builds; baseline = direct
  `relevance_smoke.py`; fixture = confirmed diagnostic pack; threshold = tuning
  and holdout reports match direct metrics, one index is built and reused, and
  corpus/model/modes/k agree; mismatch or a second build blocks.
- **Performance:** the dependency-free fixture must complete in normal CI. A
  large-corpus latency target is `pending` until the first real pack records
  initialization, validation, build, and evaluation timings; it does not block
  the bounded diagnostic implementation.
- **Unanswerable behavior:** `pending` CAP-14/E-02 and explicitly outside E-01A;
  no refusal or answer-confidence claim may be made from this pack.

## 10. Evidence plan

- Add unit tests for deterministic initialization, no-content/no-root output,
  corpus drift, split leakage, catalog membership, confirmation invalidation,
  E-01 query-count boundaries, and build-once split execution.
- Run the full dependency-free Python suite, requirements validator, mechanical
  relevance invariant, and `git diff --check`.
- Record an `EXPERIMENTS.md` entry with the workflow hypothesis, synthetic test
  setup, failures encountered, observed timings, limits, and decision.
- Update `PROJECT-STATE.md`, README statistics/commands, docs index, recreation
  prompts, and the E-01 board item.
- Status advances only to **Diagnostic · implemented** when mechanics pass. E-01
  becomes **Validated** only after the human-owned 50–100-query held-out result
  is recorded; implementation alone cannot promote it.

## 11. Open decisions

- **Decision:** which real single-owner folder and questions become the first E-01 pack.
- **Owner:** human maintainer/data owner.
- **Evidence needed:** explicit publication boundary, corpus size/domain summary,
  50–100 independently reviewed questions, tuning/holdout split, and confirmed
  expected passages.
- **Decision:** whether a future team-corpus pack carries authorization labels or
  uses physically separate per-tenant profiles.
- **Owner:** maintainer/security reviewer.
- **Evidence needed:** CFT-11 threat-model decision and CAP-07/O-02 direction.

## 12. Maintainer approval (process step 6b — required before build)

The approver must be a human maintainer/reviewer other than the implementing
agent and must explicitly approve invariant compliance (§6), CFT-11–13 (§8), and
the acceptance gate (§9), including its named pending criteria.

- **Approver:** Pending.
- **Date:** Pending.
- **Reviewed commit:** Pending; use the final specification commit.
- **Evidence:** Pending; link an explicit GitHub approval/comment.
- **Status:** **Pending approval — not build-ready.**

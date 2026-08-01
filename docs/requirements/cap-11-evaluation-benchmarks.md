# CAP-11 — Evaluation and benchmarks: graded relevance extension

Status: Diagnostic · Evidence: implemented smoke gate and WANDS experiments

> Change record for the graded-relevance extension to the existing CAP-11. It
> follows the [capability process](../capability-process.md) for PR #3 rather
> than treating the new UC-005/FR-12 behavior as a small-process exception.

Proposed follow-on: [E-01A real-folder judgment packs](cap-11-e01a-judgment-packs.md),
currently pending its independent step-6b approval before implementation.

## 1. Proposal

- **Problem / what should be possible:** A ranking, chunking, tokenizer,
  embedding, fusion, or reranking change must be tested against explicit graded
  relevance evidence and fail a reproducible regression gate when it makes a
  fixed profile worse beyond its approved tolerance.
- **Who it serves:** maintainers, contributors, coding agents, and ultimately
  users who depend on relevant evidence.
- **HIO tie:** the seam — inorganic ranking changes remain accountable to
  human-defined judgments and explicitly bounded claims.
- **One-line success notion:** a contributor can supply a corpus and judgments,
  reproduce the same profile, compare lexical/vector/hybrid behavior, and get a
  decisive pass/fail result plus per-query failures.

## 2. Motivating use case(s)

- Primary: [UC-005 — Relevance regression gate](../use-cases/uc-005-relevance-regression-gate.md).
- Affected: every search use case whose ranking behavior changes.

## 3. Functional requirements (new or changed)

| ID | Requirement (testable) | New / changes | Traces to |
|---|---|---|---|
| FR-12 | Preserve binary suite v1; add validated graded suite v2 (grades 1–3), nDCG@k, one gain per judged path/chunk, deterministic profile identity, explicit floors, same-profile baseline tolerances, machine-readable per-query evidence, and save/reuse of expensive indexes. | changes FR-12 | UC-005 |

## 4. Non-functional impact

| ID | Requirement / impact | Target or constraint |
|---|---|---|
| NFR-01 | The committed smoke gate and WANDS preparation stay standard-library only. | Base CI requires no third-party package or external dataset. |
| NFR-07 | Material ranking changes carry test or experiment evidence. | Raw successful and failed runs remain machine-readable. |
| NFR-08 | Diagnostic, sampled, synthetic, and production claims remain distinct. | Reports and docs state profile limits and disallow cross-profile score claims. |

## 5. Contracts touched (CON)

- No shared LLM/Zig wire contract changes.
- Evaluation suite JSON advances from binary v1 to backward-compatible v2.
- Smoke report/profile format starts at `profile_version: 1`; incompatible
  profile semantics require a new version rather than reinterpretation.

## 6. Invariant compliance (INV)

- **INV-01 retrieval ≠ generation:** metrics judge retrieved products/passages;
  they do not judge generated truth.
- **INV-02 citations:** path/chunk judgments preserve the evidence identity being
  evaluated and prevent repeated chunks from earning repeated gain.
- **INV-04 model identity is index data:** vector mode and exact embedding
  identity are part of `profile_id`; changing them creates a new baseline.
- **INV-06 dependency-free base:** the CI fixture, evaluator, gate, and WANDS
  adapter use only Python's standard library. FastEmbed stays optional.
- **INV-07 versioned formats:** suite and profile versions are explicit; v1
  binary suites remain readable.
- **INV-08 determinism:** source hashes, suite bytes, mode list, cutoff, vector
  identity, seed, and adapter rules make repeated profiles deterministic.
- **INV-09 complexity earned by measurement:** the initial multiline WANDS
  representation failed measurably; the corrected representation and neural
  experiments supply before/after evidence. See CFT-10.
- **INV-11 learning tunes ranking, not truth:** the gate compares ranking only;
  it does not train or redefine relevance judgments.

## 7. Register updates

- CAP-11 now links this change record and traces to UC-005.
- FR-12 now includes graded judgments, nDCG, profiles, and regression gates.
- CFT-10 records and resolves the INV-09 measurement tension.
- No new CAP was created because CAP-11 already owns evaluation and benchmarks.

## 8. Conflict check

| CFT | Between | Tension | Resolution | Status |
|---|---|---|---|---|
| CFT-10 | CAP-11 / FR-12 graded gate ↔ INV-09 | A new evaluator, adapter, CI gate, and benchmark artifacts could become complexity in anticipation. | Resolved by measured need and evidence: the existing hash/hybrid regression, failed 41,377-chunk WANDS representation, corrected 10k lexical run, and completed BGE comparison all exercise the mechanism; the CI path remains tiny and dependency-free. | Resolved |

No other conflicts were found against the register at reviewed commit `a5bb976`.

## 8b. Dependencies

- CI mechanics: no external capability or dataset.
- WANDS diagnostics: separately downloaded MIT-licensed WANDS data.
- Neural diagnostics: optional pinned FastEmbed/BGE provider already supported by
  CAP-03; lexical evaluation remains available without it.
- No acceptance criterion depends on an unbuilt capability. Calibrated explicit
  no-answer behavior remains outside FR-12 and belongs to CAP-14/E-02.

## 9. Acceptance gate

- **Primary metric:** mean nDCG@10 · baseline = same `profile_id` · fixture =
  committed CI suite or a pinned external profile · tolerance = explicitly
  supplied absolute regression · rule = a larger regression blocks.
- **Diagnostics:** MRR@10, success@10, macro recall@10, and per-query returned
  grades/paths are always recorded; selected floors are independently blocking.
- **Mechanical CI invariant:** the authored 10-product/4-query lexical fixture
  must remain 1.0 on all four metrics. A drop means the harness or its frozen
  ranking contract changed and requires deliberate fixture/baseline review; it
  is not a production relevance threshold.
- **Profile isolation:** corpus/suite/modes/cutoff/vector/model mismatch rejects a
  baseline comparison rather than silently comparing unlike runs.
- **Duplicate control:** one judged path/chunk earns gain at most once; duplicate
  judgments fail validation.
- **Dataset evidence:** WANDS preparation records license, seed, selection and
  rendering versions, grade mapping, requested/actual counts, and limitations.
- **Security/egress:** no external catalog or private corpus is committed; the CI
  fixture is public authored data and neural inference is optional/local.
- **Pending production claim:** full WANDS, another domain/user-derived holdout,
  repeated profiles, and online outcomes remain prerequisites for any production
  relevance claim.

## 10. Evidence plan and completed record

- Tests cover graded validation/formulas, duplicate gain, gates, baseline mismatch,
  persisted-index reuse, and deterministic WANDS preparation.
- CI runs the dependency-free mechanical invariant.
- `EXPERIMENTS.md` E005N records hypothesis, first failure, correction, neural
  results, limits, and decision.
- `PROJECT-STATE.md` records exact status, commands, results, and next step.
- Status remains **Diagnostic** until representative/full and cross-domain
  evidence justifies promotion.

## 11. Open decisions

- **Decision:** which larger persisted neural profile and fusion strategy to
  freeze next.
- **Owner:** maintainer.
- **Evidence needed:** larger same-profile BGE/lexical/hybrid run, repeated
  samples, and a second or user-derived domain.

## 12. Maintainer approval

- **Historical result:** PR #3 merged as `2a512cb` on 2026-07-12 without the
  explicit independent approval evidence required by step 6b.
- **Evidence:** the automated review requested governance corrections and did
  not constitute approval; the final capability record correctly remained
  `Pending approval` when the PR merged.
- **Status:** **Historical process exception; not retroactively approved.** The
  technical evidence remains Diagnostic. This record preserves the gap rather
  than converting the merge action into an approval that was never stated.
- **Future rule:** every subsequent CAP-11 extension, beginning with E-01A, must
  obtain its own explicit human approval before implementation.

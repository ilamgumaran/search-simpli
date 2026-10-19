# Search quality follow-ups: bounded task contracts

Date: 2026-10-19 · Status: all tasks proposed / unclaimed · Base: `7c40937`

Design: [reviewed search improvement plan](../search-quality-plan-2026-10.md).
These IDs are local to this plan, not claimed S1/S2 queue entries. Claim centrally
before building; approval/dependency gates below are not satisfied by this plan.
S/M are relative scopes, not delivery promises. Default roles: Sol 6.1 owns the
design/rulings; a lower-cost model (for example Luna) builds bounded approved
slices; a separate Sol 6 verifies; the parent reviews the verdict. Use a stronger
builder if a task cannot be safely bounded, particularly analyzer migration.

| Task | Board / size | Dependency and output | Proposed builder |
|---|---|---|---|
| SQ-01 | E-02 / S | Review evaluator v3 labels, decision semantics, metrics and compatibility; produce a scoped CAP-11 change design. | Sol 6.1 design |
| SQ-02 | E-02 / M | SQ-01 accepted; implement negative-query evaluation and small synthetic fixtures. | Luna |
| SQ-03 | L-04 offline / S | SQ-01 format frozen, SQ-02 merged before shared-file changes; implement segment/query comparator. | Luna |
| SQ-04 | E-01A / M | SQ-01 reconciliation, then step-6b approval over the final amended specification commit; implement pack validation, then runner as separate reviewable commits. | Luna in slices |
| SQ-05 | E-01 / M | SQ-02–04 and human corpus/labels; establish sealed representative baselines. | Human + Sol 6 |
| SQ-06 | F-01 / S | SQ-03 and SQ-05; offline fusion/router experiment and ship/defer decision. | Sol 6 experiment |
| SQ-07 | F-03 / S | Owner sequencing respected; Unicode parity evidence and analyzer migration ruling. | Sol 6 audit, parent design |
| SQ-08 | F-03 / M | SQ-07 ruling and capability approval; implement selected analyzer and all affected publication paths. | Sol, bounded patches |
| SQ-09 | F-02 / S | Current owner sequencing and methodology review; persisted 384-d baseline and bottleneck decision. | Sol 6 measurement |
| SQ-10 | CAP-14 / M | SQ-02, SQ-05, formula/floor fixed on tuning and recorded step-6b approval; implement optional support metadata. | Luna after design |

## SQ-01 — Make negative evaluation decidable

- **Touch:** proposed design amendment to [CAP-11](../requirements/cap-11-evaluation-benchmarks.md) and [evaluation docs](../evaluation.md); no retrieval or production-schema change.
- **Deliver:** exact schema and valid/invalid examples for answerable, unanswerable and unjudged rows; migration for v1/v2; metric formulas/zero denominators; explicit no-policy behavior; five case families from the design. Define trusted runner/API visibility configuration, its profile/report identity and privacy boundary; the suite cannot supply its own principal.
- **Acceptance:** design review can hand-compute one mixed fixture and distinguish false support, false refusal, nonempty hits and unknown judgments. Resolve pack-format compatibility and capability-process classification before SQ-02. Any required named approval must be recorded rather than inferred.
- **Verify / rollback:** independent review checks denominators, privacy, unchanged legacy behavior and no fabricated support threshold. Revert the proposal if unresolved; no runtime effect.

## SQ-02 — Add E-02 mechanics without changing ranking

- **Touch:** `src/search_platform/evaluation.py`, its runner/API entry points, `tests/test_evaluation.py`, relevant access tests, small public fixtures and evaluator docs; smoke plumbing where required by the accepted format/context identity.
- **Deliver:** explicit labels; backward-compatible scoring for positives; negative hit diagnostics; optional policy-based confusion matrix and low-support metrics; sample counts and `null` reasons where no policy/denominator exists.
- **Acceptance:** hand-calculated mixed fixtures match exactly; v1/v2 outputs retain their existing semantics; malformed/ambiguous labels fail closed; unjudged cases cannot improve scores. A returned irrelevant passage is not marked supported merely because it exists. Query labels cannot inject a principal.
- **Verify:** old evaluator rejects the valid negative fixture; approved implementation passes it and existing evaluation/smoke tests. Include no-hit, irrelevant-hit, true-positive, false-refusal and zero-denominator cases. Exercise restricted-view cases through the evaluator's trusted context parameter into the real prefilter; labels from suite JSON cannot override it, and different contexts cannot share a baseline. Reports clearly label authored evidence.
- **Rollback:** retain v1/v2 support and revert the new evaluator version; runtime ranker and public evidence contract stay unchanged.

## SQ-03 — Catch segment damage even when the average rises

- **Touch:** `relevance_smoke.py`, `tests/test_relevance_smoke.py`, gate-policy fixtures and docs; coordinate evaluator metadata after SQ-02.
- **Deliver:** policy-version/hash, exact query-ID alignment, segment counts/deltas, declared tolerances and missing-evidence rejection. Preserve old aggregate invocation unless an explicitly reviewed version change is required.
- **Acceptance:** a planted candidate that improves overall nDCG but harms the protected exact-lookup segment fails; an identical candidate passes; bad profiles, missing queries/modes/required segments, non-finite numbers and changed policies cannot pass silently.
- **Verify:** use deterministic report fixtures for comparator logic, then the tiny end-to-end smoke. Do not claim synthetic checks establish real-world tolerances or full L-04 completion.
- **Rollback:** new policy mode is opt-in until validated; preserve prior reports and comparator entry point. Wire stricter CI only after the fixture gate is deterministic.

## SQ-04 — Implement the already specified safe judgment pack

- **Gate:** [E-01A §12](../requirements/cap-11-e01a-judgment-packs.md#12-maintainer-approval-process-step-6b--required-before-build), including its named pending criteria; reconcile SQ-01 format changes in a reviewed amendment first. Approval must cite the final amended specification commit; approval over an earlier version does not cover changed scope or formats.
- **Touch:** only the paths agreed in E-01A's implementation review; reuse current evaluator/provider validation. Split inventory/schema validation and orchestration into sequential commits.
- **Acceptance:** the E-01A acceptance gate is authoritative: content-free inventory, explicit exact-hash human confirmation, disjoint tuning/holdout, drift rejection, bounded local artifacts and publication authority. No alternative pack or implicit consent.
- **Verify:** change one byte after confirmation, duplicate an ID or normalized query across splits, or supply an unsafe path: each required guard fails. An unapproved pack never runs as an approved representative baseline. Sources may legitimately support different queries in both splits under the existing specification.
- **Rollback:** remove optional tooling; retain original corpus and frozen evidence untouched. Do not delete private source files or silently re-seal a changed pack.

## SQ-05 — Freeze a representative positive/negative baseline

- **Gate:** human supplies and reviews a single-owner folder plus 50–100 independently meaningful queries; tuning/holdout separation and export permission confirmed. Preserve the approved pack's exact scope and rules.
- **Deliver:** local sealed pack, authorized mode reports, privacy-cleared summary and explicit exclusions/missing-provider results. Candidate pool suggestions may come from an AI, but labels require human confirmation; do not make a model's result its own judgment.
- **Acceptance:** lexical/PPMI/BGE/equal-RRF evaluated on the same reviewed corpus/suite split/cutoff where available, with an explicit controlled cross-provider comparison protocol. PPMI and BGE have distinct provider-specific profiles; same-profile regression checks keep the provider fixed. Record positive/negative metrics and language/exact/paraphrase counts. Thresholds/tolerances are fixed on tuning before held-out candidate runs. No 50-query synthetic substitute for user evidence.
- **Verify:** a separate verifier checks identities, split leakage/drift and publication scope. Preserve per-query evidence locally and publish only authorized artifacts. A missing mode remains not evaluated.
- **Rollback:** archive immutable reports; withdraw unsupported conclusions. Never relabel holdout to rescue a failing candidate.

## SQ-06 — Test fusion before shipping a router

- **Touch:** optional experiment harness/config and privacy-cleared experiment report first; no production ranking edit in the initial slice.
- **Deliver:** lexical/vector/equal-RRF controls, small fixed-weight comparison, optional simple deterministic routing, selected policy/version and an explicit ship/defer decision.
- **Acceptance:** select on tuning; holdout and segment guards from SQ-03 determine pass/fail under a predeclared gain rule. Candidate must preserve citations, stable ties and authorization. Hidden dictionary/corpus features cannot steer routing. If no candidate passes, ship none.
- **Verify:** rerun the frozen selected configuration independently; report query deltas and availability fallback. No repeated holdout tuning. Production implementation requires a separate scoped task, observable-contract review and previous-ranker rollback.

## SQ-07 — Define the casefold contract before changing it

- **Touch:** Unicode parity fixture/probe design, analyzer/normalization docs and a migration decision record; do not quietly rewrite v2 tables.
- **Deliver:** pinned Unicode version, whole-token Python/Zig comparisons for the design's case families, before/after token identities, language relevance checks and cost/scope assessment. Separate full casefold from locale casing/accent normalization.
- **Acceptance:** reproduce at least one old-mapping difference and specify whether a new analyzer ID is required, old-snapshot query behavior, unsupported-ID errors, import compatibility and incremental republish. Complete capability/requirement/conflict review under board rule 3 and obtain any required named approval; a maintainer records the identity/migration ruling before SQ-08. This plan supplies neither approval.
- **Verify / rollback:** Sol 6 reviews parity coverage and real interface paths; compare whole token sequences and existing goldens. If benefit is unproved or migration unresolved, record deferral and keep v2.

## SQ-08 — Implement and verify the selected analyzer migration

- **Touch:** paths fixed by SQ-07, expected to include `zig/src/analyzer_v2.zig` or a new analyzer module, generated Unicode data, import/index/query dispatch and compatibility tests; Python and contract changes only as ruled.
- **Acceptance:** pinned parity corpus agrees exactly, identity/reuse checks prevent mixed analysis, old snapshots behave as ruled, ASCII/Tamil/Hangul regression gates pass. New language claims require judged cases, not merely changed token bytes.
- **Verify:** independent predecessor failure, import/direct-index/query parity, malformed-input and authorization tests; affected Python/Zig/ABI/Dart suites and native source-stamp checks. Native changes require matching packaged macOS/Android/iOS artifacts; use an equipped Mac for iOS rebuild/runtime verification and state untested device behavior.
- **Rollback:** old versioned analyzer remains available as ruled; preserve old snapshots until a new publish is verified. Do not downgrade or relabel a new index as v2. App repins are coordinated separately.

## SQ-09 — Measure the current persisted engine

- **Gate:** record workload/device budgets and review methodology; respect existing S1-T9 owner sequencing for engine execution. This is not a replacement for S1-T9.
- **Touch:** benchmark harness/report and [scale doc](../scale-benchmark.md); no optimization in the measurement task.
- **Deliver:** 10k/100k feasible cells, non-identical 384-d vectors, open vs query time, snapshot bytes, RSS, concurrency/queue behavior, authorization selectivity, repetitions and errors. Optional 1M or real-provider runs are explicitly labeled.
- **Acceptance:** reproducible machine-readable results with hardware/toolchain/identity and a decision tied to a named violated budget, or a conclusion that no new mechanism is justified. Cold-cache claims require an actual documented cache procedure.
- **Verify / rollback:** verify output/citation stability independently and rerun a representative cell. Archive reports; remove optional harness if unhelpful. ANN, caching, pruning and sharding require separate tasks and exact-oracle quality gates.

## SQ-10 — Support metadata only after calibration is justified

- **Gate:** [CAP-14](../requirements/cap-14-trust-calibration.md) remains authoritative: E-01/E-02, fixed formula/floor, decided primary gate and named maintainer approval. This task is blocked today.
- **Deliver:** deterministic, advisory, retrieval-derived optional versioned metadata after authorization; no evidence editing/reordering or generation call. Existing consumers retain compatibility.
- **Acceptance:** CAP-14's positive/negative held-out quality gate passes under the tuning-fixed policy; false support and false refusal are reported. Never label the value answer truth or convert raw retrieval score directly to confidence.
- **Verify / rollback:** hidden-vs-absent non-disclosure, determinism, old consumer compatibility and formula tests; disable optional metadata and preserve baseline ranker if calibration fails. This task does not constitute full L-03 adaptive learning.

## Completion record required for every task

Record claim URL, reviewed base/commit, changed files, design deviations and parent
rulings, exact checks and results, missing evidence, an independent verdict, and
rollback. Append actual experiments to `EXPERIMENTS.md` and update current state
only when corresponding work lands. Proposed designs are never recorded as
passed experiments. Check latest main and open claims before assigning a task.
